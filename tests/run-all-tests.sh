#!/usr/bin/env bash
# run-all-tests.sh — orchestrate every test in the repo.
#
# Usage:
#   tests/run-all-tests.sh                 # run all applicable suites
#   tests/run-all-tests.sh --verbose       # stream each suite's output live
#   tests/run-all-tests.sh --only tests/*  # run a glob-matched subset
#   tests/run-all-tests.sh --skip-macos    # force-skip macOS-specific (for CI)
#   tests/run-all-tests.sh --list          # print discovered suites + exit
#
# Exit code: number of failed suites (0 = all pass).

set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 99

PLATFORM="$(uname -s)"   # Darwin | Linux
IS_DARWIN=0; [[ "$PLATFORM" == "Darwin" ]] && IS_DARWIN=1

SKIP_MACOS=0
VERBOSE=0
ONLY=""
LIST_ONLY=0

# Tests that are structurally macOS-only. Add entries as new tests land.
MACOS_ONLY_TESTS=(
  "tests/test-compaction-sandbox.sh"   # stub claude binary uses macOS path conventions
  # "tests/test-install-flow.sh"       # W19 will add this
  # "tests/test-apfs-snapshot.sh"      # if ever added
)

# Specialty paths outside tests/ — explicit hand-maintained list.
SPECIALTY_TESTS=(
  "sqlite-backend/test-concurrent-writes.sh"
  "mcp-servers/obsidian-brain/test-server.sh"
)

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose)    VERBOSE=1 ;;
    --skip-macos) SKIP_MACOS=1 ;;
    --list)       LIST_ONLY=1 ;;
    --only)
      shift
      ONLY="$1"
      ;;
    --only=*)     ONLY="${1#--only=}" ;;
    *)
      printf 'Unknown flag: %s\n' "$1" >&2
      exit 1
      ;;
  esac
  shift
done

# --------------------------------------------------------------------------
# is_macos_only: return 0 (true) if this test should only run on macOS.
# --------------------------------------------------------------------------
is_macos_only() {
  local path="$1"
  for entry in "${MACOS_ONLY_TESTS[@]}"; do
    [[ "$path" == "$entry" ]] && return 0
  done
  # Heuristic: filename mentions a macOS-specific facility
  [[ "${path##*/}" =~ (apfs|mds|spotlight|install-flow|osascript) ]] && return 0
  return 1
}

# --------------------------------------------------------------------------
# Discover suites into SUITES array: each entry is "path|runner"
# --------------------------------------------------------------------------
SUITES=()

# Group 1: tests/test-*.sh (shell tests)
if [[ -n "$ONLY" ]]; then
  : # filtered below
else
  shopt -s nullglob
  for f in tests/test-*.sh; do
    SUITES+=("$f|bash")
  done
  shopt -u nullglob
fi

# Group 2: tests/test-*.py (Python tests)
if [[ -z "$ONLY" ]]; then
  shopt -s nullglob
  for f in tests/test-*.py; do
    SUITES+=("$f|python3")
  done
  shopt -u nullglob
fi

# Group 3: specialty paths (explicit list)
if [[ -z "$ONLY" ]]; then
  for spec in "${SPECIALTY_TESTS[@]}"; do
    [[ -f "$spec" ]] && SUITES+=("$spec|bash")
  done
fi

# Apply --only filter (replace SUITES with only matching entries)
if [[ -n "$ONLY" ]]; then
  shopt -s nullglob
  for f in $ONLY; do
    case "$f" in
      *.py) SUITES+=("$f|python3") ;;
      *)    SUITES+=("$f|bash") ;;
    esac
  done
  shopt -u nullglob
fi

# --------------------------------------------------------------------------
# --list mode
# --------------------------------------------------------------------------
if (( LIST_ONLY == 1 )); then
  printf 'Discovered suites:\n'
  applicable=0
  for entry in "${SUITES[@]}"; do
    path="${entry%%|*}"
    if is_macos_only "$path"; then
      gate="macOS-only"
      note=" (will skip on Linux)"
      if (( IS_DARWIN == 1 )); then (( applicable++ )); fi
    else
      gate="Darwin+Linux"
      note=""
      (( applicable++ ))
    fi
    printf '  [%-13s] %s%s\n' "$gate" "$path" "$note"
  done
  total="${#SUITES[@]}"
  printf '\nTotal: %d suites; %d applicable on this platform (%s).\n' \
    "$total" "$applicable" "$PLATFORM"
  exit 0
fi

# --------------------------------------------------------------------------
# run_suite: execute one suite, capture output, report PASS/FAIL/SKIP
# --------------------------------------------------------------------------
run_suite() {
  local path="$1"
  local runner="$2"
  local label="$path"

  if is_macos_only "$path" && (( IS_DARWIN == 0 || SKIP_MACOS == 1 )); then
    printf '%-60s %s\n' "$label" "SKIP (macOS-only)"
    return 2   # special sentinel: skipped
  fi

  local log="$REPO_ROOT/.run-all-tests.log.$$.${path//\//_}"
  local start=$SECONDS

  if (( VERBOSE == 1 )); then
    "$runner" "$path" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
  else
    "$runner" "$path" >"$log" 2>&1
    local rc=$?
  fi
  local elapsed=$((SECONDS - start))

  if (( rc == 0 )); then
    printf '%-60s PASS  (%ds)\n' "$label" "$elapsed"
    rm -f "$log"
    return 0
  elif (( rc == 77 )); then
    # Autoconf convention: a suite may exit 77 to mean "SKIP — environment
    # or install-state prerequisites are not met". Differs from macOS-only
    # skip above in that the test itself chose to skip at runtime.
    #
    # N1 hardening (v0.2.2): exit 77 alone is NOT enough to grant SKIP
    # status. The suite MUST also emit a line starting with "SKIP: " on
    # stdout/stderr to DECLARE its intent. This prevents a buggy test
    # that coincidentally exits 77 (e.g. an uncaught awk error path,
    # a custom error code) from being silently masked as a skip.
    local reason
    reason=$(grep -m1 '^SKIP: ' "$log" 2>/dev/null || true)
    if [[ -z "$reason" ]]; then
      printf '%-60s FAIL  (%ds, rc=77 with no SKIP: marker)\n' "$label" "$elapsed"
      printf '       └─ exit 77 without an explicit "SKIP: ..." line is treated as failure.\n'
      printf '       └─ if this test meant to skip, emit  echo "SKIP: <reason>"  before exit 77.\n'
      printf '       └─ tail of output (%s):\n' "$log"
      tail -n 20 "$log" | sed 's/^/       │ /'
      return 1
    fi
    printf '%-60s %s\n' "$label" "SKIP (needs env/deps)"
    printf '       └─ %s\n' "$reason"
    rm -f "$log"
    return 3
  else
    printf '%-60s FAIL  (%ds, rc=%d)\n' "$label" "$elapsed" "$rc"
    printf '       └─ tail of output (%s):\n' "$log"
    tail -n 20 "$log" | sed 's/^/       │ /'
    return 1
  fi
}

# --------------------------------------------------------------------------
# Main loop
# --------------------------------------------------------------------------
PASSED=0
FAILED=0
SKIPPED=0
FAILED_NAMES=()
SKIPPED_NAMES=()

for entry in "${SUITES[@]}"; do
  path="${entry%%|*}"
  runner="${entry##*|}"

  run_suite "$path" "$runner"
  rc=$?

  case $rc in
    0) (( PASSED++ )) ;;
    2)
      (( SKIPPED++ ))
      SKIPPED_NAMES+=("$path (macOS-only)")
      ;;
    3)
      (( SKIPPED++ ))
      SKIPPED_NAMES+=("$path (needs env/deps)")
      ;;
    *)
      (( FAILED++ ))
      FAILED_NAMES+=("$path")
      ;;
  esac
done

TOTAL=$(( PASSED + FAILED + SKIPPED ))

# --------------------------------------------------------------------------
# Summary block
# --------------------------------------------------------------------------
printf '\n%s\n' "──────────────────────────────────────────────────────────────"
printf ' Suite summary: %d total  |  %d passed  |  %d failed  |  %d skipped\n' \
  "$TOTAL" "$PASSED" "$FAILED" "$SKIPPED"
printf '%s\n' "──────────────────────────────────────────────────────────────"

if (( ${#FAILED_NAMES[@]} > 0 )); then
  printf ' Failed:\n'
  for name in "${FAILED_NAMES[@]}"; do
    printf '   - %s\n' "$name"
  done
fi

if (( ${#SKIPPED_NAMES[@]} > 0 )); then
  printf ' Skipped:\n'
  for name in "${SKIPPED_NAMES[@]}"; do
    printf '   - %s\n' "$name"
  done
fi

# Exit code = number of failed suites (skipped does not count)
exit "$FAILED"
