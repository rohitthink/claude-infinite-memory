#!/bin/bash
# test-harness-exit77-discipline.sh
#
# Verifies the N1 fix (v0.2.2): run-all-tests.sh requires BOTH an exit code
# of 77 AND an explicit "SKIP: ..." marker on stdout/stderr before treating
# a test as skipped. A test that crashes with exit 77 without a marker is
# treated as FAIL — not silently masked.
#
# Strategy: copy the harness into a tmpdir, create two fixture tests
# alongside it (one declares SKIP, one doesn't), run the harness, and
# assert the observed PASS/FAIL/SKIP counts.
#
# Exits 0 on PASS. Auto-discovered by run-all-tests.sh.

set -u

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HARNESS="$REPO_ROOT/tests/run-all-tests.sh"

if [[ ! -x "$HARNESS" ]]; then
  echo "FAIL: harness not found or not executable at $HARNESS"
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Create a fake tests/ tree with just two fixtures
mkdir -p "$tmp/tests"

cat > "$tmp/tests/test-skip-declared.sh" <<'EOF'
#!/bin/bash
# Declares skip intent explicitly. Harness MUST treat as SKIP.
echo "SKIP: fixture deliberately declares a skip for harness testing"
exit 77
EOF

cat > "$tmp/tests/test-skip-accidental.sh" <<'EOF'
#!/bin/bash
# Exits 77 WITHOUT a SKIP: marker — simulates a buggy test whose exit
# code happens to be 77. Harness MUST treat this as FAIL (N1 fix).
echo "oops, something went wrong, exiting 77 without announcing skip"
exit 77
EOF

chmod +x "$tmp/tests/"*.sh

# Place a harness copy that auto-discovers fixtures from the tmp tests/ dir.
# The harness computes REPO_ROOT as one level up from its own dir and globs
# tests/test-*.sh relative to that. So placing the harness at $tmp/tests/
# works — REPO_ROOT will be $tmp.
cp "$HARNESS" "$tmp/tests/run-all-tests.sh"
chmod +x "$tmp/tests/run-all-tests.sh"

# Run the copied harness, capturing output and exit code.
# NOTE: no `|| true` — that would swallow the harness's real exit code.
# `$(...)` captures stdout regardless of exit status; we need the rc.
output=$("$tmp/tests/run-all-tests.sh" 2>&1)
rc=$?

PASS=0
FAIL=0

# Assertion 1: test-skip-declared is reported as SKIP
if echo "$output" | grep -q 'test-skip-declared.sh.*SKIP'; then
  echo "PASS: test 1 (test-skip-declared correctly reported as SKIP)"
  PASS=$((PASS+1))
else
  echo "FAIL: test 1 — test-skip-declared was not reported as SKIP"
  echo "  harness output excerpt:"
  echo "$output" | grep -E 'test-skip-declared|Suite summary' | head -3 | sed 's/^/    /'
  FAIL=$((FAIL+1))
fi

# Assertion 2: test-skip-accidental is reported as FAIL (the N1 fix)
if echo "$output" | grep -q 'test-skip-accidental.sh.*FAIL'; then
  echo "PASS: test 2 (test-skip-accidental correctly reported as FAIL — N1 fix holds)"
  PASS=$((PASS+1))
else
  echo "FAIL: test 2 — test-skip-accidental (exit 77 without SKIP: marker) was NOT reported as FAIL"
  echo "       This indicates the exit-77 masking regression has re-opened."
  echo "  harness output excerpt:"
  echo "$output" | grep -E 'test-skip-accidental|Suite summary' | head -3 | sed 's/^/    /'
  FAIL=$((FAIL+1))
fi

# Assertion 3: overall harness exit code is 1 (one failing suite counts)
if [[ "$rc" -eq 1 ]]; then
  echo "PASS: test 3 (harness exit code 1, reflecting the one failed suite)"
  PASS=$((PASS+1))
else
  echo "FAIL: test 3 — harness exit code was $rc (expected 1)"
  FAIL=$((FAIL+1))
fi

# Assertion 4: the FAIL diagnostic for the accidental-77 case mentions the
# missing SKIP: marker (aids debugging when the regression fires).
if echo "$output" | grep -q 'rc=77.*no SKIP: marker\|no SKIP: marker'; then
  echo "PASS: test 4 (FAIL diagnostic names the missing SKIP: marker)"
  PASS=$((PASS+1))
else
  echo "FAIL: test 4 — harness FAIL output doesn't mention the missing SKIP: marker"
  FAIL=$((FAIL+1))
fi

echo ""
echo "─────────────────────────────────────────"
echo "  harness exit-77 discipline: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
exit $FAIL
