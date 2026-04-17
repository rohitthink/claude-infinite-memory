#!/bin/bash
# obsidian-reconciliation-daemon.sh
#
# Reconciliation daemon: catches orphaned Claude Code session transcripts that
# never triggered the SessionEnd hook (SIGKILL, API 500, OS crash, force-quit).
# Periodically scans $CLAUDE_BRIDGE_HOME/projects/*/[a-f0-9]*.jsonl, identifies
# orphans (>15 min stale, not yet reconciled, >=8 lines), and routes them
# through the same secret-redaction + claude -p sync pipeline as the main hook.
#
# Companion to: hooks/session-end-vault-sync.sh
#
# Usage:
#   obsidian-reconciliation-daemon.sh            # daemon mode: poll every 5 min
#   obsidian-reconciliation-daemon.sh --once     # single scan, exit
#   obsidian-reconciliation-daemon.sh --test-mode  # single scan; log WOULD SYNC + mark reconciled, no claude -p
#
# Safety:
#   - Single-instance enforced via PID file in $LOCK_DIR
#   - Recursion-safe: sets CLAUDE_OBSIDIAN_SYNC_CHILD=1 before invoking claude -p
#   - Reuses global mkdir-based vault-sync lock to coordinate with the main hook
#   - realpath validates transcript paths are inside $CLAUDE_BRIDGE_HOME/projects/
#   - Same 27-category regex secret redaction as main hook (deterministic pre-filter)
#   - perl alarm enforces 300s hard timeout on claude -p
#   - SIGTERM/SIGINT trigger graceful shutdown at next loop iteration

set -uo pipefail

# ---- Configuration (override via env) ----
CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
VAULT="${CLAUDE_BRIDGE_VAULT:-}"
CLAUDE_BIN="${CLAUDE_BRIDGE_CLAUDE_BIN:-/opt/homebrew/bin/claude}"

PROJECTS_DIR="${CLAUDE_BRIDGE_HOME}/projects"
LOG_DIR="${CLAUDE_BRIDGE_HOME}/logs"
LOG="$LOG_DIR/obsidian-sync.log"
SPOOL_DIR="${CLAUDE_BRIDGE_HOME}/sync-spool"
LOCK_DIR="${CLAUDE_BRIDGE_HOME}/sync-active"
GLOBAL_LOCK="$LOCK_DIR/vault-sync.lock"
PID_FILE="$LOCK_DIR/reconciler.pid"
STATE_DIR="${CLAUDE_BRIDGE_HOME}/sync-state"
RECONCILED_FILE="$STATE_DIR/reconciled.txt"

# /usr/bin/perl is macOS-standard and stable across versions; leave as-is.
PERL_BIN="/usr/bin/perl"

POLL_INTERVAL_SEC=300       # 5 minutes
STALE_THRESHOLD_SEC=900     # 15 minutes — under this, treat session as still active
MIN_LINES=8

# ---- Modes ----
MODE="daemon"
for arg in "$@"; do
  case "$arg" in
    --once)      MODE="once" ;;
    --test-mode) MODE="test" ;;
    *)           echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$LOG_DIR" "$SPOOL_DIR" "$LOCK_DIR" "$STATE_DIR"
touch "$RECONCILED_FILE"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [reconciler-$$] $*" >> "$LOG"
}

# ---- Preflight binary checks ----
if [[ ! -x "$PERL_BIN" ]]; then
  log "ABORT: perl not found at $PERL_BIN"
  exit 1
fi
if [[ ! -x "$CLAUDE_BIN" ]] && ! command -v claude >/dev/null 2>&1; then
  log "ABORT: claude not found at $CLAUDE_BIN and not on PATH"
  exit 1
fi
# Resolve the effective claude binary once
if [[ ! -x "$CLAUDE_BIN" ]]; then
  CLAUDE_BIN="$(command -v claude)"
fi
command -v jq >/dev/null 2>&1 || { log "ABORT: jq not on PATH"; exit 1; }

# ---- Single-instance enforcement via PID file ----
if [[ -f "$PID_FILE" ]]; then
  existing_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    log "another reconciler already running (pid=$existing_pid); exiting"
    exit 0
  fi
  # Stale PID file
  rm -f "$PID_FILE"
fi
echo "$$" > "$PID_FILE"

# ---- Graceful shutdown ----
SHUTDOWN=0
on_signal() {
  log "signal received; will exit after current scan"
  SHUTDOWN=1
}
trap on_signal TERM INT

cleanup_pidfile() {
  # Only remove if it's still ours
  if [[ -f "$PID_FILE" ]] && [[ "$(cat "$PID_FILE" 2>/dev/null)" == "$$" ]]; then
    rm -f "$PID_FILE"
  fi
}
trap cleanup_pidfile EXIT

# ---- Log rotation at 1MB (mirrors main hook) ----
rotate_log_if_big() {
  if [[ -f "$LOG" ]] && [[ $(wc -c < "$LOG" 2>/dev/null || echo 0) -gt 1048576 ]]; then
    mv -f "$LOG" "$LOG.1" 2>/dev/null || true
  fi
}

# ---- Check if session_id already reconciled ----
already_reconciled() {
  local sid="$1"
  [[ -z "$sid" ]] && return 1
  grep -Fxq "$sid" "$RECONCILED_FILE" 2>/dev/null
}

# ---- Mark session_id as reconciled ----
mark_reconciled() {
  local sid="$1"
  [[ -z "$sid" ]] && return 0
  # Atomic-ish append; grep-check again to avoid duplicates under concurrency
  if ! grep -Fxq "$sid" "$RECONCILED_FILE" 2>/dev/null; then
    echo "$sid" >> "$RECONCILED_FILE"
  fi
}

# ---- Extract session_id from a transcript (first jsonl line that has one) ----
extract_session_id() {
  local transcript="$1"
  local sid
  # Look in first 5 lines — Claude Code transcripts include sessionId near the top
  sid=$(head -n 5 "$transcript" 2>/dev/null | jq -r 'try .sessionId // try .session_id // empty' 2>/dev/null | head -n 1)
  if [[ -z "$sid" ]]; then
    # Fallback: derive from filename (e.g., <uuid>.jsonl)
    sid=$(basename "$transcript" .jsonl)
  fi
  echo "$sid"
}

# ---- Process a single orphan transcript ----
process_orphan() {
  local transcript_raw="$1"
  local test_only="$2"  # "test" or "real"

  # realpath validation
  local transcript
  transcript=$("$PERL_BIN" -e 'use Cwd "abs_path"; print abs_path($ARGV[0]) // ""' "$transcript_raw" 2>/dev/null)
  local allowed_prefix="${CLAUDE_BRIDGE_HOME}/projects/"
  if [[ -z "$transcript" ]] || [[ "$transcript" != "$allowed_prefix"* ]]; then
    log "REJECTED path_outside_allowed raw=$transcript_raw resolved=$transcript"
    return 1
  fi

  # Line count check
  local line_count
  line_count=$(wc -l < "$transcript" 2>/dev/null || echo 0)
  if [[ "$line_count" -lt "$MIN_LINES" ]]; then
    return 1
  fi

  local session_id
  session_id=$(extract_session_id "$transcript")
  if [[ -z "$session_id" ]]; then
    log "SKIP no session_id extractable from $transcript"
    return 1
  fi

  if already_reconciled "$session_id"; then
    return 1
  fi

  if [[ "$test_only" == "test" ]]; then
    log "WOULD SYNC session_id=$session_id transcript=$transcript lines=$line_count"
    mark_reconciled "$session_id"
    return 0
  fi

  # ---- Real sync path: redact + spool + wrapper ----
  local timestamp timestamp_tag redacted_transcript prompt_file wrapper
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  timestamp_tag=$(date "+%Y%m%d-%H%M%S")
  redacted_transcript="$SPOOL_DIR/recon-transcript-${session_id}-${timestamp_tag}.jsonl"
  prompt_file="$SPOOL_DIR/recon-prompt-${session_id}-${timestamp_tag}.txt"
  wrapper="$SPOOL_DIR/recon-wrapper-${session_id}-${timestamp_tag}.sh"

  # Same 27-category secret redaction as main hook
  sed -E \
    -e 's/ghp_[A-Za-z0-9]{36}/[REDACTED_GITHUB_PAT]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{80,}/[REDACTED_GITHUB_FGPAT]/g' \
    -e 's/gho_[A-Za-z0-9]{36}/[REDACTED_GITHUB_OAUTH]/g' \
    -e 's/AKIA[A-Z0-9]{16}/[REDACTED_AWS_ACCESS_KEY]/g' \
    -e 's/ASIA[A-Z0-9]{16}/[REDACTED_AWS_STS_KEY]/g' \
    -e 's/sk-ant-[A-Za-z0-9_-]{20,}/[REDACTED_ANTHROPIC_KEY]/g' \
    -e 's/sk-proj-[A-Za-z0-9_-]{20,}/[REDACTED_OPENAI_PROJECT_KEY]/g' \
    -e 's/sk-[A-Za-z0-9]{20,}/[REDACTED_OPENAI_KEY]/g' \
    -e 's/AIza[A-Za-z0-9_-]{35}/[REDACTED_GOOGLE_API_KEY]/g' \
    -e 's/ya29\.[A-Za-z0-9_-]+/[REDACTED_GOOGLE_OAUTH]/g' \
    -e 's/xox[abpr]-[A-Za-z0-9-]{10,}/[REDACTED_SLACK_TOKEN]/g' \
    -e 's/glpat-[A-Za-z0-9_-]{20}/[REDACTED_GITLAB_PAT]/g' \
    -e 's/eyJ0eX[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/[REDACTED_AZURE_JWT]/g' \
    -e 's/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/[REDACTED_JWT]/g' \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTED_PRIVATE_KEY_START]/g' \
    -e 's/-----END [A-Z ]*PRIVATE KEY-----/[REDACTED_PRIVATE_KEY_END]/g' \
    -e 's|Authorization:[[:space:]]*[Bb]earer[[:space:]]+[A-Za-z0-9._~+/\-]{10,}={0,2}|Authorization: [REDACTED_BEARER_TOKEN]|g' \
    -e 's/(password|passwd|passwort|secret|api[_-]?key|auth[_-]?token|bearer)[[:space:]"'\'':=]+[A-Za-z0-9!@#$%^&*()_+=/-]{8,}/\1=[REDACTED_SECRET]/gi' \
    -e 's|AccountKey=[A-Za-z0-9+/=]{88}|[REDACTED_AZURE_STORAGE_KEY]|g' \
    -e 's/hf_[A-Za-z0-9]{34,}/[REDACTED_HUGGINGFACE_KEY]/g' \
    -e 's/dop_v1_[a-f0-9]{64}/[REDACTED_DIGITALOCEAN_TOKEN]/g' \
    -e 's/sbp_[a-f0-9]{40}/[REDACTED_SUPABASE_KEY]/g' \
    -e 's/sk_(test|live)_[A-Za-z0-9]{24,}/[REDACTED_STRIPE_KEY]/g' \
    -e 's|postgresql://[^:[:space:]]+:[^@[:space:]]+@[^[:space:]]+|[REDACTED_POSTGRESQL_DSN]|g' \
    -e 's|mysql://[^:[:space:]]+:[^@[:space:]]+@[^[:space:]]+|[REDACTED_MYSQL_DSN]|g' \
    -e 's|mongodb(\+srv)?://[^:[:space:]]+:[^@[:space:]]+@[^[:space:]]+|[REDACTED_MONGODB_DSN]|g' \
    -e 's|otpauth://[^[:space:]]+|[REDACTED_OTPAUTH_URI]|g' \
    "$transcript" > "$redacted_transcript" 2>/dev/null

  if [[ ! -s "$redacted_transcript" ]]; then
    rm -f "$redacted_transcript"
    log "SKIP redaction produced empty output for session_id=$session_id"
    return 1
  fi

  cat >"$prompt_file" <<PROMPT_EOF
Run the obsidian-sync skill to sync this ORPHANED session's outcomes to your Obsidian vault.

Session ID: $session_id
End reason: orphan-reconciled (SessionEnd hook never fired — likely SIGKILL, crash, force-quit, or API 500)
Transcript: $redacted_transcript (PRE-REDACTED for common secret patterns by the reconciliation daemon)
Timestamp: $timestamp

IMPORTANT CONTEXT:
- This session never exited gracefully. Outcomes were not previously synced.
- The transcript has already had common credential patterns (GitHub PATs, AWS keys, Anthropic/OpenAI/Google keys, Azure Storage/AD JWTs, HuggingFace/DigitalOcean/Supabase/Stripe keys, database DSNs, OTP URIs, Bearer tokens, JWTs, SSH private keys, Slack/GitLab tokens, generic password/secret/api_key/bearer patterns) replaced with [REDACTED_*] markers via regex pre-filtering.
- If you see any content resembling a secret that WASN'T caught by the regex, omit it from your vault write.
- The vault may be synced to a cloud service. Anything you write becomes cloud-resident.

Read the redacted transcript, extract meaningful outcomes (shipped features, decisions, learnings, project status changes, new skills/automations, infrastructure changes), and append to the appropriate vault files per the obsidian-sync skill's documented structure.

Be concise. If the session was trivial, off-topic, or purely exploratory without concrete outcomes, write nothing and exit with a one-line note explaining why.

Preserve existing content; never overwrite. Always append.
PROMPT_EOF

  cat >"$wrapper" <<WRAPPER_EOF
#!/bin/bash
export CLAUDE_OBSIDIAN_SYNC_CHILD=1
unset CLAUDECODE
unset CLAUDE_CODE_ENTRYPOINT

sleep 3

LOG='$LOG'
GLOBAL_LOCK='$GLOBAL_LOCK'
VAULT='$VAULT'
PROMPT_FILE='$prompt_file'
REDACTED_TRANSCRIPT='$redacted_transcript'
WRAPPER='$wrapper'
SESSION_ID='$session_id'
RECONCILED_FILE='$RECONCILED_FILE'
CLAUDE_BIN='$CLAUDE_BIN'

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') [reconciler-sync-\$\$] \$*" >> "\$LOG"; }

cleanup() {
  rm -f "\$PROMPT_FILE" "\$REDACTED_TRANSCRIPT" "\$WRAPPER"
  rmdir "\$GLOBAL_LOCK" 2>/dev/null
}
trap cleanup EXIT INT TERM

log "=== Reconcile sync start | session=\$SESSION_ID reason=orphan ==="

if [[ ! -d "\$VAULT" ]]; then
  log "ABORT: vault volume not mounted at \$VAULT"
  exit 1
fi

ACQUIRED=0
for i in \$(seq 1 300); do
  if mkdir "\$GLOBAL_LOCK" 2>/dev/null; then
    ACQUIRED=1
    break
  fi
  sleep 1
done

if [[ \$ACQUIRED -eq 0 ]]; then
  log "ABORT: could not acquire vault lock after 300s wait"
  exit 1
fi

log "lock acquired"
PROMPT_CONTENT=\$(cat "\$PROMPT_FILE")
log "invoking claude -p (timeout=300s)"
/usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV' 300 \\
  "\$CLAUDE_BIN" -p "\$PROMPT_CONTENT" \\
    --allowedTools "Read,Write,Edit,Glob,Grep,Bash,Skill" >> "\$LOG" 2>&1
RC=\$?

log "claude -p exit=\$RC"
if [[ \$RC -eq 0 ]]; then
  if ! grep -Fxq "\$SESSION_ID" "\$RECONCILED_FILE" 2>/dev/null; then
    echo "\$SESSION_ID" >> "\$RECONCILED_FILE"
  fi
  log "marked \$SESSION_ID as reconciled"
else
  log "NOT marking reconciled (non-zero exit); will retry on next scan"
fi
log "=== Reconcile sync end ==="
WRAPPER_EOF

  chmod +x "$wrapper"

  log "spawning detached sync for orphan session_id=$session_id transcript=$transcript lines=$line_count"
  nohup "$wrapper" </dev/null >/dev/null 2>&1 &
  disown
  return 0
}

# ---- One scan pass ----
scan_once() {
  rotate_log_if_big
  local now found=0
  now=$(date +%s)

  # Pattern: $CLAUDE_BRIDGE_HOME/projects/*/[a-f0-9]*.jsonl
  shopt -s nullglob
  local tfile
  for tfile in "$PROJECTS_DIR"/*/[a-f0-9]*.jsonl; do
    [[ -f "$tfile" ]] || continue

    # mtime check: skip if younger than STALE_THRESHOLD_SEC
    local mtime age
    mtime=$(stat -f %m "$tfile" 2>/dev/null || stat -c %Y "$tfile" 2>/dev/null || echo 0)
    age=$((now - mtime))
    if [[ $age -lt $STALE_THRESHOLD_SEC ]]; then
      continue
    fi

    # Quick session_id precheck (avoid reading the file twice when already done)
    local sid
    sid=$(extract_session_id "$tfile")
    if [[ -n "$sid" ]] && already_reconciled "$sid"; then
      continue
    fi

    # Line count cheap filter
    local lc
    lc=$(wc -l < "$tfile" 2>/dev/null || echo 0)
    if [[ "$lc" -lt "$MIN_LINES" ]]; then
      continue
    fi

    local mode_tag="real"
    if [[ "$MODE" == "test" ]]; then
      mode_tag="test"
    fi

    if process_orphan "$tfile" "$mode_tag"; then
      found=$((found + 1))
    fi
  done
  shopt -u nullglob

  log "scan complete: processed=$found mode=$MODE"
}

# ---- Main ----
log "=== reconciliation daemon starting (mode=$MODE pid=$$) ==="

if [[ "$MODE" == "once" ]] || [[ "$MODE" == "test" ]]; then
  scan_once
  log "=== reconciliation daemon exiting after single scan (mode=$MODE) ==="
  exit 0
fi

# Daemon mode: poll loop
while [[ $SHUTDOWN -eq 0 ]]; do
  scan_once
  # Sleep in 5s increments so SIGTERM responds quickly
  elapsed=0
  while [[ $elapsed -lt $POLL_INTERVAL_SEC ]] && [[ $SHUTDOWN -eq 0 ]]; do
    sleep 5
    elapsed=$((elapsed + 5))
  done
done

log "=== reconciliation daemon exiting gracefully ==="
exit 0
