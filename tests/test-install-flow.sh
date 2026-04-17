#!/usr/bin/env bash
# test-install-flow.sh — end-to-end install/use/uninstall round trip.
#
# macOS-only. Skips on Linux via platform guard below.
#
# Isolation strategy:
#   - CLAUDE_BRIDGE_HOME → a tmpdir under $TMPDIR
#   - CLAUDE_BRIDGE_VAULT → a fake vault scaffolded in another tmpdir
#   - HOME → points ~/.claude + ~/Library/LaunchAgents at tmpdir-based
#             overrides so the test NEVER mutates the real user's config
#   - PATH → prepended with a stub-bin dir containing a fake `claude`
#             binary, so claude -p calls hit the stub
#
# Everything cleaned up on trap EXIT regardless of test outcome.

set -o pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "SKIP: macOS-only"; exit 0; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR=""
FAIL_COUNT=0

cleanup() {
  local exit_code=$?
  if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
    # Force-unload any LaunchAgents we may have bootstrapped (defensive;
    # install.sh default is NOT to bootstrap, but be explicit about cleanup)
    find "$TEST_DIR/home/Library/LaunchAgents" -name '*.plist' 2>/dev/null | while read -r plist; do
      label="$(basename "$plist" .plist)"
      launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    done
    rm -rf "$TEST_DIR"
  fi
  exit $exit_code
}
trap cleanup EXIT INT TERM

# ─── Scratch environment ──────────────────────────────────────────────────────

TEST_DIR=$(mktemp -d -t cim-install-flow-XXXXXX)
# Resolve through perl so macOS /var → /private/var symlink is normalised;
# the session-end hook uses perl abs_path for its prefix check, so CLAUDE_BRIDGE_HOME
# must carry the same resolved form or the transcript path validation silently rejects.
TEST_DIR=$(perl -e 'use Cwd "abs_path"; print abs_path($ARGV[0]) // ""' "$TEST_DIR" 2>/dev/null || echo "$TEST_DIR")
export CLAUDE_BRIDGE_HOME="$TEST_DIR/bridge-home"
export CLAUDE_BRIDGE_VAULT="$TEST_DIR/fake-vault"

# Scaffold a minimal Obsidian vault
mkdir -p "$CLAUDE_BRIDGE_VAULT/07 - Claude Knowledge/Historical Summaries"
mkdir -p "$CLAUDE_BRIDGE_VAULT/07 - Claude Knowledge/MOCs"
mkdir -p "$CLAUDE_BRIDGE_VAULT/.obsidian"
touch "$CLAUDE_BRIDGE_VAULT/.obsidian/workspace.json"

# Override HOME so install.sh writes into our scratch tree instead of ~/.claude
FAKE_HOME="$TEST_DIR/home"
mkdir -p "$FAKE_HOME/.claude/hooks" \
         "$FAKE_HOME/.claude/mcp-servers" \
         "$FAKE_HOME/.claude/skills" \
         "$FAKE_HOME/Library/LaunchAgents"
export HOME="$FAKE_HOME"

# Stub claude binary — writes invocation evidence to STUB_LOG, simulates
# the obsidian-sync write by creating a markdown file in the vault.
mkdir -p "$TEST_DIR/stub-bin"
cat >"$TEST_DIR/stub-bin/claude" <<'STUB'
#!/usr/bin/env bash
STUB_LOG="${STUB_LOG:-/tmp/cim-stub-claude.log}"
echo "[$(date +%s)] claude $*" >> "$STUB_LOG"
# Drain stdin (the prompt passed via -p arg) to log
if ! [[ -t 0 ]]; then
  cat >> "$STUB_LOG"
fi
# Simulate the obsidian-sync write so the vault assertion passes.
# Real claude would invoke the Write tool; stub writes the file directly.
if [[ -n "${CLAUDE_BRIDGE_VAULT:-}" && -d "${CLAUDE_BRIDGE_VAULT}" ]]; then
  LOG_DIR="${CLAUDE_BRIDGE_VAULT}/07 - Claude Knowledge"
  mkdir -p "$LOG_DIR"
  HOSTNAME_S=$(hostname -s 2>/dev/null || echo "stub-host")
  cat >> "$LOG_DIR/Session Log - ${HOSTNAME_S}.md" <<EOF

## $(date '+%Y-%m-%d') — stub install-flow test

- Source: W19 end-to-end install-flow test
- Outcome: stub claude invoked successfully; install.sh respects HOME override
EOF
fi
# Deterministic stdout
cat <<'OUT'
## Session outcomes

- User asked about test harness installation flow
- Resolved via install.sh + scratch HOME override

## Technical learnings

- install.sh respects $HOME env-override for isolation testing
OUT
STUB
chmod +x "$TEST_DIR/stub-bin/claude"
export STUB_LOG="$TEST_DIR/stub-claude.log"
export PATH="$TEST_DIR/stub-bin:$PATH"

# Pre-flight: verify jq and perl are available (hook hard-requires both)
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not found in PATH (required by session-end hook)"
  exit 0
fi
if ! command -v perl >/dev/null 2>&1; then
  echo "SKIP: perl not found in PATH (required by session-end hook)"
  exit 0
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

assert_exists() {
  if [[ ! -e "$1" ]]; then
    printf '  FAIL missing: %s\n' "$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    printf '  OK   present: %s\n' "$1"
  fi
}

assert_missing() {
  if [[ -e "$1" ]]; then
    printf '  FAIL leftover: %s\n' "$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    printf '  OK   removed: %s\n' "$1"
  fi
}

# ─── 1. Install ───────────────────────────────────────────────────────────────

printf '\n---- running install.sh ----\n'
UNATTENDED=1 \
  CLAUDE_BRIDGE_HOME="$CLAUDE_BRIDGE_HOME" \
  CLAUDE_BRIDGE_VAULT="$CLAUDE_BRIDGE_VAULT" \
  CLAUDE_BRIDGE_LABEL_PREFIX="com.example" \
  CLAUDE_BRIDGE_TRUENAS_HOST="" \
  bash "$REPO_ROOT/install.sh" --yes 2>&1 | tee "$TEST_DIR/install.log"
install_rc=${PIPESTATUS[0]}
if [[ $install_rc -ne 0 ]]; then
  echo "FAIL: install.sh exited $install_rc"
  exit 1
fi

# ─── 2. Post-install assertions ───────────────────────────────────────────────

printf '\n---- verifying install ----\n'
assert_exists "$CLAUDE_BRIDGE_HOME/hooks/session-start-vault-context.sh"
assert_exists "$CLAUDE_BRIDGE_HOME/hooks/session-end-vault-sync.sh"
assert_exists "$CLAUDE_BRIDGE_HOME/mcp-servers/obsidian-brain/server.py"
assert_exists "$CLAUDE_BRIDGE_HOME/skills/obsidian-sync"
assert_exists "$FAKE_HOME/Library/LaunchAgents"

# Plists installed but NOT bootstrapped (no --bootstrap flag)
plist_count=$(find "$FAKE_HOME/Library/LaunchAgents" -name 'com.example.*.plist' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$plist_count" -ge 1 ]]; then
  printf '  OK   %d LaunchAgent plist(s) installed (not bootstrapped)\n' "$plist_count"
else
  printf '  FAIL no LaunchAgent plists found under %s\n' "$FAKE_HOME/Library/LaunchAgents"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Confirm plists are NOT active in launchctl (we did not bootstrap them)
if launchctl list 2>/dev/null | grep -q 'com.example.obsidian-reconciliation'; then
  printf '  FAIL LaunchAgent is running (should not be bootstrapped)\n'
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  printf '  OK   no com.example plists bootstrapped\n'
fi

# ─── 3. Synthesize fake transcript ───────────────────────────────────────────

printf '\n---- synthesizing transcript ----\n'
SESSION_ID="test-session-W19"
TRANSCRIPT_DIR="$CLAUDE_BRIDGE_HOME/projects/$SESSION_ID"
mkdir -p "$TRANSCRIPT_DIR"
TRANSCRIPT_FILE="$TRANSCRIPT_DIR/$(date +%s).jsonl"

# Hook requires >= 8 lines; provide 10
cat >"$TRANSCRIPT_FILE" <<'TRANSCRIPT'
{"role":"user","content":"Hello, can you help me set up the test harness?"}
{"role":"assistant","content":"Sure — walking through install.sh now."}
{"role":"user","content":"I prefer terse replies. My repo uses bash 4.x."}
{"role":"assistant","content":"Understood. Using bash 4.x compatible syntax."}
{"role":"user","content":"Also use n8n not Make for automations."}
{"role":"assistant","content":"Noted: n8n preferred over Make for automation workflows."}
{"role":"user","content":"Great. What did we accomplish today?"}
{"role":"assistant","content":"Verified install.sh works with HOME override."}
{"role":"user","content":"Perfect."}
{"role":"assistant","content":"Session complete. Outcomes logged."}
TRANSCRIPT
printf '  OK   transcript written: %s (%d lines)\n' "$TRANSCRIPT_FILE" "$(wc -l < "$TRANSCRIPT_FILE")"

# ─── 4. Invoke SessionEnd hook ────────────────────────────────────────────────

printf '\n---- invoking SessionEnd hook ----\n'
# Hook reads JSON from stdin; runs a detached nohup child then returns immediately
HOOK_SCRIPT="$CLAUDE_BRIDGE_HOME/hooks/session-end-vault-sync.sh"
HOOK_INPUT=$(printf '{"transcript_path":"%s","session_id":"%s","reason":"completed"}' \
  "$TRANSCRIPT_FILE" "$SESSION_ID")

# The hook has an env-var recursion guard (CLAUDE_OBSIDIAN_SYNC_CHILD=1) that
# causes it to exit silently when running inside an existing Claude session.
# Unset it so the hook runs normally in this test environment.
unset CLAUDE_OBSIDIAN_SYNC_CHILD

printf '%s\n' "$HOOK_INPUT" | \
  CLAUDE_BRIDGE_HOME="$CLAUDE_BRIDGE_HOME" \
  CLAUDE_BRIDGE_VAULT="$CLAUDE_BRIDGE_VAULT" \
  CLAUDE_BRIDGE_CLAUDE_BIN="$TEST_DIR/stub-bin/claude" \
  STUB_LOG="$STUB_LOG" \
  bash "$HOOK_SCRIPT" 2>&1 | tee "$TEST_DIR/hook.log"
hook_rc=${PIPESTATUS[0]}
printf '  hook parent exited: %d\n' "$hook_rc"

# Hook detaches the wrapper via nohup — poll up to 20s for stub invocation
printf '  waiting for detached stub invocation'
for i in $(seq 1 20); do
  if [[ -s "$STUB_LOG" ]]; then
    printf ' done (%ds)\n' "$i"
    break
  fi
  sleep 1
  printf '.'
done
echo

if [[ ! -s "$STUB_LOG" ]]; then
  echo "FAIL: stub claude was never invoked (STUB_LOG empty after 20s)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  printf '  OK   stub invoked; STUB_LOG has %d bytes\n' "$(wc -c < "$STUB_LOG")"
fi

# ─── 5. Verify vault was updated ─────────────────────────────────────────────

printf '\n---- verifying vault update ----\n'
# Give stub a moment to finish writing after being invoked
sleep 2
VAULT_KB="$CLAUDE_BRIDGE_VAULT/07 - Claude Knowledge"
file_count=$(find "$VAULT_KB" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ "$file_count" -lt 1 ]]; then
  printf '  FAIL no markdown files under %s\n' "$VAULT_KB"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  printf '  OK   vault has %d markdown file(s) under 07 - Claude Knowledge/\n' "$file_count"
fi

# ─── 6. Uninstall ─────────────────────────────────────────────────────────────

printf '\n---- running uninstall.sh --confirm ----\n'
CLAUDE_BRIDGE_HOME="$CLAUDE_BRIDGE_HOME" \
  HOME="$FAKE_HOME" \
  "$REPO_ROOT/uninstall.sh" --confirm 2>&1 | tee "$TEST_DIR/uninstall.log"
uninstall_rc=${PIPESTATUS[0]}
if [[ $uninstall_rc -ne 0 ]]; then
  echo "FAIL: uninstall.sh exited $uninstall_rc"
  exit 1
fi

# ─── 7. Post-uninstall assertions ────────────────────────────────────────────

printf '\n---- verifying uninstall ----\n'
assert_missing "$CLAUDE_BRIDGE_HOME/hooks/session-start-vault-context.sh"
assert_missing "$CLAUDE_BRIDGE_HOME/hooks/session-end-vault-sync.sh"
assert_missing "$CLAUDE_BRIDGE_HOME/mcp-servers/obsidian-brain"
assert_missing "$CLAUDE_BRIDGE_HOME/skills/obsidian-sync"

# Check the specific plists that uninstall.sh commits to removing.
# Note: com.example.mds-watchdog.plist is installed but intentionally absent
# from uninstall.sh's _launchagents array — not asserted here.
_plists_to_check=(
  "$FAKE_HOME/Library/LaunchAgents/com.example.obsidian-reconciliation.plist"
  "$FAKE_HOME/Library/LaunchAgents/com.example.vault-compaction.plist"
  "$FAKE_HOME/Library/LaunchAgents/com.example.vault-auto-moc.plist"
  "$FAKE_HOME/Library/LaunchAgents/com.example.obsidian-brain-indexer.plist"
)
for _plist in "${_plists_to_check[@]}"; do
  assert_missing "$_plist"
done

# Vault MUST be preserved (uninstall.sh contract: vault is untouched)
if [[ ! -d "$CLAUDE_BRIDGE_VAULT/07 - Claude Knowledge" ]]; then
  echo "FAIL: uninstall removed the vault (must not)"
  exit 1
fi
printf '  OK   vault preserved at %s\n' "$CLAUDE_BRIDGE_VAULT"

# ─── 8. Final result ──────────────────────────────────────────────────────────

printf '\n---- result ----\n'
if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo "PASS"
  exit 0
else
  printf 'FAIL (%d assertion failure(s))\n' "$FAIL_COUNT"
  exit 1
fi
