#!/bin/bash
# tests/test-topic-map-containment.sh
#
# SIMULATION REPORT — W12 (2026-04-17)
# ======================================
# Simulates every rule in config/vault-topic-map.example.yaml against the
# 5-layer containment logic in hooks/session-start-vault-context.sh (lines
# 247-300), then adds 8 adversarial probes to verify security boundaries hold.
#
# CONTEXT
# -------
# Gemini Tier-2 audit finding #4 claimed 5-of-12 rules in a hypothetical
# 12-rule yaml would fail the containment filter due to glob patterns.
# The shipped yaml has only 5 rules, all using direct relative paths — no
# globs. This simulation tests the actual shipped config, not the hypothetical.
#
# SHIPPED RULE RESULTS (all 5 rules, 7 unique paths)
# ---------------------------------------------------
# Rule 1 — ProjectA        PASS  _Maps/Dashboard.md + 02 - Projects/ProjectA/Overview.md
# Rule 2 — ProjectB        PASS  _Maps/Dashboard.md + 02 - Projects/ProjectB/Overview.md
#                                + 01 - Clients/ProjectB Client/Brand Voice.md
# Rule 3 — ProjectC        PASS  _Maps/Dashboard.md + 02 - Projects/ProjectC/Overview.md
#                                + 07 - Claude Knowledge/Automation Stack.md
# Rule 4 — Claude config   PASS  _Maps/Dashboard.md + 07 - Claude Knowledge/Automation Stack.md
# Rule 5 — fallback        PASS  _Maps/Dashboard.md + _Maps/Project Status Map.md
#
# ADVERSARIAL PROBE RESULTS (8 probes)
# -------------------------------------
# Probe 1 — ../../../etc/passwd           REJECTED   Layer 2 (parent traversal)
# Probe 2 — /etc/passwd                   REJECTED   Layer 1 (absolute path)
# Probe 3 — 05 - Personal/Journal.md      SILENT SKIP  Layer 3 (Personal folder, no log)
# Probe 4 — _Maps/../_Maps/Dashboard.md   REJECTED   Layer 2 (embedded .. component)
# Probe 5 — _Maps/evil.md → /etc/hosts    REJECTED   Layer 4 (symlink resolves outside vault)
# Probe 6 — _Maps/Never.md (missing)      SILENT CONTINUE  (file absent, not an error)
# Probe 7 — _Maps/Dashboard.md            PASS       valid path passes all 5 layers
# Probe 8 — 02 - Projects/ProjectA/...   PASS       spaces in path work correctly
#
# FINDING
# -------
# Zero failures on the shipped example yaml. Gemini's 5/12 claim applied to a
# hypothetical 12-rule yaml with glob patterns that do not exist in the repo.
# No Remediation A (rule re-phrasing) or B (glob expansion) is needed.
# See docs/WORKER_FINDINGS.md for the full rule-by-rule analysis.
#
# USAGE
#   bash tests/test-topic-map-containment.sh   # exits 0 on all pass
#
# REQUIREMENTS: bash, perl, jq (same as the hook itself)
#
# CRON-SAFE: no interactive prompts; temp directory is removed on EXIT trap.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/hooks/session-start-vault-context.sh"
EXAMPLE_YAML="$REPO_ROOT/config/vault-topic-map.example.yaml"

# ---- Preflight checks ----
if [[ ! -f "$HOOK" ]]; then
  echo "ERROR: hook not found at $HOOK" >&2
  exit 1
fi
if [[ ! -f "$EXAMPLE_YAML" ]]; then
  echo "ERROR: example yaml not found at $EXAMPLE_YAML" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available — cannot run containment simulation" >&2
  exit 0
fi
if ! command -v perl >/dev/null 2>&1; then
  echo "SKIP: perl not available — cannot run containment simulation" >&2
  exit 0
fi

# ---- Temp environment (cleaned on exit) ----
TMPDIR_TEST=$(mktemp -d "/tmp/topic-map-test-$$-XXXX")
trap 'rm -rf "$TMPDIR_TEST"' EXIT

VAULT="$TMPDIR_TEST/vault"
BRIDGE_HOME="$TMPDIR_TEST/bridge-home"
SESSION_LOG="$BRIDGE_HOME/logs/session-start.log"
TOPIC_MAP_FILE="$BRIDGE_HOME/vault-topic-map.yaml"

# ---- Counters ----
PASS_COUNT=0
FAIL_COUNT=0

# ---- Assertion helpers ----
pass() {
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS  %s\n" "$*"
}

fail() {
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL  %s\n" "$*"
}

# ---- Infrastructure helpers ----

# Clear the session log so each invocation gets a fresh slate
reset_log() {
  : > "$SESSION_LOG" 2>/dev/null || true
}

# Run the hook with a given cwd; returns hook stdout (JSON)
run_hook() {
  local cwd="$1"
  reset_log
  printf '{"source":"user","cwd":"%s"}' "$cwd" | \
    CLAUDE_BRIDGE_VAULT="$VAULT" \
    CLAUDE_BRIDGE_HOME="$BRIDGE_HOME" \
    CLAUDE_OBSIDIAN_SYNC_CHILD="" \
    bash "$HOOK" 2>/dev/null
}

# Extract additionalContext string from hook JSON output
get_ctx() {
  printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null || echo ""
}

# Write a minimal adversarial topic-map yaml with a single fallback rule
# whose only include is the given rel_path.
use_adversarial_yaml() {
  local rel_path="$1"
  printf 'rules:\n  - name: adversarial\n    cwd_contains: ["*"]\n    include:\n      - "%s"\n' \
    "$rel_path" > "$TOPIC_MAP_FILE"
}

# Assert that running the hook with a given adversarial path produces a
# REJECTED log entry matching a given grep pattern.
assert_rejected() {
  local probe="$1" path="$2" layer="$3" log_pat="$4"
  use_adversarial_yaml "$path"
  run_hook "/tmp" > /dev/null
  if grep -qF "$log_pat" "$SESSION_LOG" 2>/dev/null; then
    pass "Probe $probe ($path): REJECTED by $layer"
  else
    fail "Probe $probe ($path): NOT rejected — $layer bypassed!"
  fi
}

# ---- Build vault skeleton ----
mkdir -p \
  "$VAULT/_Maps" \
  "$VAULT/02 - Projects/ProjectA" \
  "$VAULT/02 - Projects/ProjectB" \
  "$VAULT/02 - Projects/ProjectC" \
  "$VAULT/07 - Claude Knowledge" \
  "$VAULT/01 - Clients/ProjectB Client" \
  "$VAULT/05 - Personal" \
  "$BRIDGE_HOME/logs"

touch "$SESSION_LOG"

# Files referenced by shipped rules
printf '# Dashboard\n'                          > "$VAULT/_Maps/Dashboard.md"
printf '# Project Status\n'                     > "$VAULT/_Maps/Project Status Map.md"
printf '# ProjectA Overview\n'                  > "$VAULT/02 - Projects/ProjectA/Overview.md"
printf '# ProjectB Overview\n'                  > "$VAULT/02 - Projects/ProjectB/Overview.md"
printf '# ProjectC Overview\n'                  > "$VAULT/02 - Projects/ProjectC/Overview.md"
printf '# Automation Stack\n'                   > "$VAULT/07 - Claude Knowledge/Automation Stack.md"
printf '# Brand Voice\n'                        > "$VAULT/01 - Clients/ProjectB Client/Brand Voice.md"
# Baseline files (hook always injects these; providing stubs avoids awk warnings)
printf '# Technical Learnings\n'               > "$VAULT/07 - Claude Knowledge/Technical Learnings.md"
printf '# User Profile\n'                       > "$VAULT/07 - Claude Knowledge/User Profile.md"
# Private file for Layer 3 test (must NOT appear in output)
printf 'Private journal entry\n'                > "$VAULT/05 - Personal/Journal.md"

# ==============================================================
printf "\n=== PART 1: Shipped rule simulation (%d rules) ===\n" 5
# ==============================================================

cp "$EXAMPLE_YAML" "$TOPIC_MAP_FILE"

# --- Rule 1: ProjectA ---
output=$(run_hook "/home/user/Projects/ProjectA")
ctx=$(get_ctx "$output")
if printf '%s' "$ctx" | grep -qF "### _Maps/Dashboard.md" && \
   printf '%s' "$ctx" | grep -qF "### 02 - Projects/ProjectA/Overview.md"; then
  pass "Rule 1 (ProjectA): Dashboard.md + ProjectA/Overview.md rendered"
else
  fail "Rule 1 (ProjectA): one or more includes missing — headers found: $(printf '%s' "$ctx" | grep '###' | head -5 | tr '\n' '|')"
fi

# --- Rule 2: ProjectB ---
output=$(run_hook "/home/user/Projects/ProjectB")
ctx=$(get_ctx "$output")
if printf '%s' "$ctx" | grep -qF "### _Maps/Dashboard.md" && \
   printf '%s' "$ctx" | grep -qF "### 02 - Projects/ProjectB/Overview.md" && \
   printf '%s' "$ctx" | grep -qF "### 01 - Clients/ProjectB Client/Brand Voice.md"; then
  pass "Rule 2 (ProjectB): Dashboard.md + ProjectB/Overview.md + Brand Voice.md rendered"
else
  fail "Rule 2 (ProjectB): one or more includes missing — headers found: $(printf '%s' "$ctx" | grep '###' | head -5 | tr '\n' '|')"
fi

# --- Rule 3: ProjectC ---
output=$(run_hook "/home/user/Projects/ProjectC")
ctx=$(get_ctx "$output")
if printf '%s' "$ctx" | grep -qF "### _Maps/Dashboard.md" && \
   printf '%s' "$ctx" | grep -qF "### 02 - Projects/ProjectC/Overview.md" && \
   printf '%s' "$ctx" | grep -qF "### 07 - Claude Knowledge/Automation Stack.md"; then
  pass "Rule 3 (ProjectC): Dashboard.md + ProjectC/Overview.md + Automation Stack.md rendered"
else
  fail "Rule 3 (ProjectC): one or more includes missing — headers found: $(printf '%s' "$ctx" | grep '###' | head -5 | tr '\n' '|')"
fi

# --- Rule 4: Claude config/hooks ---
output=$(run_hook "/home/user/Projects/.claude/hooks")
ctx=$(get_ctx "$output")
if printf '%s' "$ctx" | grep -qF "### _Maps/Dashboard.md" && \
   printf '%s' "$ctx" | grep -qF "### 07 - Claude Knowledge/Automation Stack.md"; then
  pass "Rule 4 (Claude config): Dashboard.md + Automation Stack.md rendered"
else
  fail "Rule 4 (Claude config): one or more includes missing — headers found: $(printf '%s' "$ctx" | grep '###' | head -5 | tr '\n' '|')"
fi

# --- Rule 5: fallback (wildcard *) ---
output=$(run_hook "/home/user/Projects/SomethingElse")
ctx=$(get_ctx "$output")
if printf '%s' "$ctx" | grep -qF "### _Maps/Dashboard.md" && \
   printf '%s' "$ctx" | grep -qF "### _Maps/Project Status Map.md"; then
  pass "Rule 5 (fallback): Dashboard.md + Project Status Map.md rendered"
else
  fail "Rule 5 (fallback): one or more includes missing — headers found: $(printf '%s' "$ctx" | grep '###' | head -5 | tr '\n' '|')"
fi

# ==============================================================
printf "\n=== PART 2: Adversarial probe tests (8 probes) ===\n"
# ==============================================================

# --- Probe 1: parent traversal — MUST be REJECTED by Layer 2 ---
assert_rejected 1 "../../../etc/passwd" "Layer 2 (parent traversal)" \
  "REJECTED include path (parent traversal)"

# --- Probe 2: absolute path — MUST be REJECTED by Layer 1 ---
assert_rejected 2 "/etc/passwd" "Layer 1 (absolute path)" \
  "REJECTED include path (absolute)"

# --- Probe 3: Personal folder — MUST be silently skipped by Layer 3 ---
# Layer 3 emits no log entry; the path must also be absent from output.
use_adversarial_yaml "05 - Personal/Journal.md"
output=$(run_hook "/tmp")
ctx=$(get_ctx "$output")
if ! grep -qF "REJECTED" "$SESSION_LOG" 2>/dev/null && \
   ! printf '%s' "$ctx" | grep -qF "05 - Personal"; then
  pass "Probe 3 (05 - Personal/Journal.md): Layer 3 silently skipped (no log, not in output)"
else
  fail "Probe 3 (05 - Personal/Journal.md): Layer 3 failed — unexpected REJECTED or path appeared in output"
fi

# --- Probe 4: embedded .. component — MUST be REJECTED by Layer 2 ---
assert_rejected 4 "_Maps/../_Maps/Dashboard.md" "Layer 2 (embedded .. component)" \
  "REJECTED include path (parent traversal)"

# --- Probe 5: symlink pointing outside vault — MUST be REJECTED by Layer 4 ---
ln -sf /etc/hosts "$VAULT/_Maps/evil.md"
use_adversarial_yaml "_Maps/evil.md"
run_hook "/tmp" > /dev/null
if grep -qF "REJECTED include path outside vault" "$SESSION_LOG" 2>/dev/null; then
  pass "Probe 5 (_Maps/evil.md -> /etc/hosts): REJECTED by Layer 4 (resolved outside vault)"
else
  fail "Probe 5 (_Maps/evil.md -> /etc/hosts): NOT rejected — Layer 4 symlink escape missed!"
fi
rm -f "$VAULT/_Maps/evil.md"

# --- Probe 6: nonexistent file — MUST be silent-continue (not REJECTED) ---
use_adversarial_yaml "_Maps/Never.md"
output=$(run_hook "/tmp")
ctx=$(get_ctx "$output")
if ! grep -qF "REJECTED" "$SESSION_LOG" 2>/dev/null && \
   ! printf '%s' "$ctx" | grep -qF "Never.md"; then
  pass "Probe 6 (_Maps/Never.md nonexistent): silent continue (no REJECTED log, not in output)"
else
  fail "Probe 6 (_Maps/Never.md nonexistent): unexpected REJECTED or path appeared in output"
fi

# --- Probe 7: valid path in adversarial context — MUST succeed ---
use_adversarial_yaml "_Maps/Dashboard.md"
output=$(run_hook "/tmp")
ctx=$(get_ctx "$output")
if printf '%s' "$ctx" | grep -qF "### _Maps/Dashboard.md"; then
  pass "Probe 7 (_Maps/Dashboard.md): PASS — valid path passes all 5 layers"
else
  fail "Probe 7 (_Maps/Dashboard.md): NOT in output — valid path wrongly rejected!"
fi

# --- Probe 8: path with embedded spaces — MUST succeed (current shipped behavior) ---
use_adversarial_yaml "02 - Projects/ProjectA/Overview.md"
output=$(run_hook "/tmp")
ctx=$(get_ctx "$output")
if printf '%s' "$ctx" | grep -qF "### 02 - Projects/ProjectA/Overview.md"; then
  pass "Probe 8 (02 - Projects/ProjectA/Overview.md): PASS — spaces in path handled"
else
  fail "Probe 8 (02 - Projects/ProjectA/Overview.md): NOT in output — space handling regression!"
fi

# ==============================================================
printf "\n=== Summary: %d PASS, %d FAIL (of 13 assertions) ===\n" \
  "$PASS_COUNT" "$FAIL_COUNT"
# ==============================================================

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf "\nTo debug, inspect: %s\n" "$BRIDGE_HOME/logs/session-start.log"
  exit 1
fi

exit 0
