#!/bin/bash
# test-compaction-sidecar-sha256.sh
#
# Verifies the N2 fix (v0.2.2): proposal sha256 sidecar file written at
# generation time and verified at apply time, giving file-mode compaction
# the same tamper protection as sqlite mode had.
#
# Exercises the two helpers directly (write_proposal_sidecar,
# verify_proposal_sidecar), plus the "backward-compat / pre-v0.2.2 proposal"
# case where no sidecar exists.
#
# Exits 0 on PASS, non-zero on FAIL. Auto-discovered by run-all-tests.sh.

set -u

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DAEMON="$REPO_ROOT/daemons/compaction/compaction-daemon.sh"

if [[ ! -f "$DAEMON" ]]; then
  echo "FAIL: daemon not found at $DAEMON"
  exit 1
fi

# Extract the three helpers without sourcing the whole daemon (which would
# try to acquire locks, enforce environment guards, etc.). awk range pattern
# from the function header to the first line-start `}`.
extract_fn() {
  awk -v name="$1" '
    $0 ~ "^"name"\\(\\) \\{" { printing=1 }
    printing { print }
    printing && /^}$/ { exit }
  ' "$DAEMON"
}

sha256_src=$(extract_fn sha256_file)
write_src=$(extract_fn write_proposal_sidecar)
verify_src=$(extract_fn verify_proposal_sidecar)

if [[ -z "$sha256_src" || -z "$write_src" || -z "$verify_src" ]]; then
  echo "FAIL: could not extract one or more helpers from $DAEMON"
  echo "  sha256_file: $([[ -n "$sha256_src" ]] && echo found || echo MISSING)"
  echo "  write_proposal_sidecar: $([[ -n "$write_src" ]] && echo found || echo MISSING)"
  echo "  verify_proposal_sidecar: $([[ -n "$verify_src" ]] && echo found || echo MISSING)"
  exit 1
fi

# Source all three helpers
eval "$sha256_src"
eval "$write_src"
eval "$verify_src"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

PASS=0
FAIL=0

# ─── Test 1: write_proposal_sidecar creates <path>.sha256 with a hex digest ─
prop="$tmp/quarter-2026-Q2.proposed.md"
printf 'summary line 1\nsummary line 2\n' > "$prop"
if write_proposal_sidecar "$prop"; then
  if [[ -f "${prop}.sha256" ]]; then
    contents=$(cat "${prop}.sha256")
    # Expect 64 hex chars (sha256sum) or "unknown" on weird platforms
    if [[ "$contents" =~ ^[0-9a-f]{64}$ ]]; then
      echo "PASS: test 1 (sidecar written, 64-char hex digest)"
      PASS=$((PASS+1))
    else
      echo "FAIL: test 1 — sidecar contents '$contents' are not a 64-char hex sha256"
      FAIL=$((FAIL+1))
    fi
  else
    echo "FAIL: test 1 — sidecar file ${prop}.sha256 was not created"
    FAIL=$((FAIL+1))
  fi
else
  echo "FAIL: test 1 — write_proposal_sidecar returned non-zero"
  FAIL=$((FAIL+1))
fi

# ─── Test 2: verify_proposal_sidecar returns 0 on unchanged file ────────────
if verify_proposal_sidecar "$prop"; then
  echo "PASS: test 2 (verify returns 0 on unchanged file)"
  PASS=$((PASS+1))
else
  echo "FAIL: test 2 — verify returned non-zero on unchanged file"
  FAIL=$((FAIL+1))
fi

# ─── Test 3: verify_proposal_sidecar returns 1 on tampered content ──────────
# Append a byte to the file; sidecar still holds the old sha. Should detect.
echo "MALICIOUS APPEND" >> "$prop"
if verify_proposal_sidecar "$prop"; then
  echo "FAIL: test 3 — tampered file passed verify (sha256 sidecar not enforced)"
  FAIL=$((FAIL+1))
else
  echo "PASS: test 3 (verify correctly rejects tampered file)"
  PASS=$((PASS+1))
fi

# ─── Test 4: no-sidecar case passes (backward-compat with pre-v0.2.2) ───────
no_sidecar="$tmp/ancient.proposed.md"
echo "pre-v0.2.2 proposal, no sidecar" > "$no_sidecar"
if verify_proposal_sidecar "$no_sidecar"; then
  echo "PASS: test 4 (no-sidecar = pass, preserving backward compat)"
  PASS=$((PASS+1))
else
  echo "FAIL: test 4 — pre-v0.2.2 proposal (no sidecar) was rejected"
  FAIL=$((FAIL+1))
fi

# ─── Test 5: sidecar with 'unknown' passes (platform without sha256 tools) ──
weird="$tmp/weird.proposed.md"
echo "content" > "$weird"
echo "unknown" > "${weird}.sha256"
if verify_proposal_sidecar "$weird"; then
  echo "PASS: test 5 (sidecar='unknown' passes — platform-tolerant)"
  PASS=$((PASS+1))
else
  echo "FAIL: test 5 — sidecar with 'unknown' was rejected instead of passing"
  FAIL=$((FAIL+1))
fi

# ─── Test 6: sidecar survives a round-trip (write → verify → pass) ──────────
rt="$tmp/rt.proposed.md"
dd if=/dev/urandom of="$rt" bs=1024 count=4 2>/dev/null
write_proposal_sidecar "$rt"
if verify_proposal_sidecar "$rt"; then
  echo "PASS: test 6 (write→verify round-trip on 4 KiB random content)"
  PASS=$((PASS+1))
else
  echo "FAIL: test 6 — round-trip failed for random binary content"
  FAIL=$((FAIL+1))
fi

echo ""
echo "─────────────────────────────────────────"
echo "  sidecar sha256 tests: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
exit $FAIL
