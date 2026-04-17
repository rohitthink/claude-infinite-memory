#!/bin/bash
# test-perl-alarm-timeout.sh
#
# Verifies the perl_alarm_exec helper in daemons/truenas-sync/obsidian-truenas-sync.sh:
#   1. Normal completion — command finishes under budget → command's exit code + stdout preserved
#   2. Timeout exit code — command exceeds timeout → exit 124 within timeout+1s
#   3. Grandchild reaping — command forks a grandchild; on timeout the grandchild is killed
#      (the original `perl -e 'alarm N; exec @ARGV'` pattern would orphan it).
#
# This is the W21 "defense-in-depth" test for the Perl alarm POSIX process-group fix.
#
# Exits 0 on PASS, non-zero on FAIL. Auto-discovered by tests/run-all-tests.sh.

set -u

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DAEMON="$REPO_ROOT/daemons/truenas-sync/obsidian-truenas-sync.sh"

if [[ ! -f "$DAEMON" ]]; then
  echo "FAIL: sync daemon not found at $DAEMON"
  exit 1
fi

# Extract just the perl_alarm_exec function so we can source it without
# running the daemon's top-level entrypoint. awk range from the function
# header to the first line-start `}`.
fn_src=$(awk '/^perl_alarm_exec\(\) \{/,/^}$/' "$DAEMON")
if [[ -z "$fn_src" ]]; then
  echo "FAIL: could not extract perl_alarm_exec from $DAEMON"
  exit 1
fi

# Provide the variables the helper expects (the daemon exports these).
PERL=/usr/bin/perl
if [[ ! -x "$PERL" ]]; then
  echo "SKIP: $PERL not available (helper requires system perl)"
  exit 77   # Autoconf skip convention (harness interprets as SKIP)
fi

# Source the extracted function into the current shell
eval "$fn_src"

PASS=0
FAIL=0

# ─── Test 1: normal completion ─────────────────────────────────────────────
out=$(perl_alarm_exec 3 /bin/echo "hello-world" 2>/dev/null)
rc=$?
if [[ "$rc" -eq 0 && "$out" == "hello-world" ]]; then
  echo "PASS: test 1 (normal completion; rc=0, stdout preserved)"
  PASS=$((PASS+1))
else
  echo "FAIL: test 1 — expected rc=0 stdout='hello-world', got rc=$rc stdout='$out'"
  FAIL=$((FAIL+1))
fi

# ─── Test 2: timeout → exit 124 within budget ──────────────────────────────
start=$(date +%s)
perl_alarm_exec 1 /bin/sleep 5 >/dev/null 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
if [[ "$rc" -eq 124 && "$elapsed" -le 3 ]]; then
  echo "PASS: test 2 (timeout; rc=124, elapsed ${elapsed}s)"
  PASS=$((PASS+1))
else
  echo "FAIL: test 2 — expected rc=124 elapsed<=3s, got rc=$rc elapsed=${elapsed}s"
  FAIL=$((FAIL+1))
fi

# ─── Test 3: grandchild reaped on timeout (orphan prevention) ──────────────
# Spawn a bash that forks a long-running sleeper, writes its PID to a marker
# file, and then waits. The helper's 1s timeout should trigger SIGTERM to the
# entire process group, reaping both bash AND the sleeper.
marker=$(mktemp)
rm -f "$marker"
# Background-run the helper so we can inspect the marker afterwards.
(
  perl_alarm_exec 1 /bin/bash -c "/bin/sleep 30 & echo \$! > $marker; wait" >/dev/null 2>&1
) &
helper_bg=$!

# Wait up to 2s for the bash child to write the sleeper's PID.
for _ in 1 2 3 4 5 6 7 8; do
  [[ -s "$marker" ]] && break
  sleep 0.25
done

if [[ ! -s "$marker" ]]; then
  echo "FAIL: test 3 — marker file never written; test harness broken"
  kill -9 $helper_bg 2>/dev/null || true
  rm -f "$marker"
  FAIL=$((FAIL+1))
else
  grandchild=$(cat "$marker")
  # Wait for the helper itself to finish (should be ~1s for the timeout path)
  wait $helper_bg 2>/dev/null
  # Give the kernel a moment to reap signals fully
  sleep 0.5
  if kill -0 "$grandchild" 2>/dev/null; then
    echo "FAIL: test 3 — grandchild PID $grandchild still alive after timeout (orphan leaked)"
    kill -9 "$grandchild" 2>/dev/null || true
    FAIL=$((FAIL+1))
  else
    echo "PASS: test 3 (grandchild PID $grandchild reaped; no orphan)"
    PASS=$((PASS+1))
  fi
  rm -f "$marker"
fi

echo ""
echo "─────────────────────────────────────────"
echo "  perl_alarm_exec tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
exit $FAIL
