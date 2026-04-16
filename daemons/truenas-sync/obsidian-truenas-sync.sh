#!/bin/bash
# obsidian-truenas-sync.sh
#
# Real-time backup of the Obsidian vault to a remote host (e.g., TrueNAS, a
# second Mac, any SSH-reachable machine) via rsync-over-SSH.
#
# Flow:
#   vault source   -> rsync-SSH ->   $CLAUDE_BRIDGE_TRUENAS_HOST:$CLAUDE_BRIDGE_TRUENAS_PATH
#
# Modes:
#   --once    Single push, exit. Good for cron / manual runs.
#   --watch   fswatch-driven continuous mode; debounced so we rsync at most
#             once per DEBOUNCE_SEC (default 10s) of filesystem quiet. This
#             avoids thrashing on rapid Obsidian autosaves.
#   --help    Print usage.
#
# Lock:
#   LOCAL lock at $CLAUDE_BRIDGE_HOME/sync-active/truenas-sync.lock (mkdir).
#   Distinct from vault-sync.lock (that one serializes Claude-side writes;
#   this one just serializes concurrent remote pushes).
#
# SSH probe:
#   Non-interactive SSH probe before every rsync. On probe failure we log
#   and bail quickly the next --watch debounce cycle (or next cron tick)
#   will retry naturally.
#
# Hard timeout:
#   rsync wrapped in perl alarm (300s). Protects against hung SSH sessions.
#
# Logging:
#   logs/truenas-sync.log, rotated at 1MB -> .log.1
#   One structured line per run:
#     YYYY-MM-DD HH:MM:SS [truenas-sync] mode=X duration=Ys exit=Z bytes-xferred=N
#
# Exit codes:
#   0   sync completed cleanly
#   1   fatal pre-flight failure (vault missing, lock held, config incomplete, etc.)
#   2   SSH probe failed (remote unreachable)
#   3   rsync failed / timed out
#   4   bad flag

set -uo pipefail

# ---- Config (override via env) ----
CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
VAULT="${CLAUDE_BRIDGE_VAULT:-}"
REMOTE_HOST="${CLAUDE_BRIDGE_TRUENAS_HOST:-}"
REMOTE_PATH="${CLAUDE_BRIDGE_TRUENAS_PATH:-}"

LOG_DIR="${CLAUDE_BRIDGE_HOME}/logs"
LOG="$LOG_DIR/truenas-sync.log"
LOG_MAX_BYTES=$((1024 * 1024))  # 1 MB
LOCK_DIR="${CLAUDE_BRIDGE_HOME}/sync-active"
LOCK="$LOCK_DIR/truenas-sync.lock"
LOCK_WAIT_SEC=60

FSWATCH="/opt/homebrew/bin/fswatch"
RSYNC="/usr/bin/rsync"
PERL="/usr/bin/perl"
SSH="/usr/bin/ssh"

RSYNC_TIMEOUT_SEC=300
DEBOUNCE_SEC=10

# ---- Helpers ----

usage() {
  cat <<'EOF'
obsidian-truenas-sync.sh — real-time vault backup to a remote host

Usage:
  obsidian-truenas-sync.sh --once     Single rsync push, exit.
  obsidian-truenas-sync.sh --watch    fswatch-driven debounced push loop.
  obsidian-truenas-sync.sh --help     Show this help.

Required env (set via claude-infinite-memory.env):
  CLAUDE_BRIDGE_VAULT          local vault path
  CLAUDE_BRIDGE_TRUENAS_HOST   SSH host (must be passwordless-capable)
  CLAUDE_BRIDGE_TRUENAS_PATH   remote path (trailing slash recommended)

Optional:
  CLAUDE_BRIDGE_HOME           defaults to ~/.claude
EOF
}

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_init() {
  mkdir -p "$LOG_DIR"
  if [[ -f "$LOG" ]]; then
    local size
    size=$(stat -f%z "$LOG" 2>/dev/null || stat -c%s "$LOG" 2>/dev/null || echo 0)
    if (( size > LOG_MAX_BYTES )); then
      mv -f "$LOG" "$LOG.1"
    fi
  fi
  touch "$LOG"
}

log_line() {
  echo "$(ts) [truenas-sync] $1" >> "$LOG"
}

log_summary() {
  log_line "mode=$1 duration=${2}s exit=$3 bytes-xferred=${4}"
}

acquire_lock() {
  mkdir -p "$LOCK_DIR"
  local waited=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    if (( waited >= LOCK_WAIT_SEC )); then
      log_line "lock held by pid=$(cat "$LOCK/pid" 2>/dev/null || echo ?); skipping run"
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo $$ > "$LOCK/pid" 2>/dev/null || true
  trap release_lock EXIT INT TERM
  return 0
}

release_lock() {
  rm -rf "$LOCK" 2>/dev/null || true
}

probe_ssh() {
  "$SSH" -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" true 2>/dev/null
}

check_vault() {
  if [[ -z "$VAULT" || ! -d "$VAULT" ]]; then
    log_line "abort: vault not set or not mounted at '$VAULT'"
    return 1
  fi
  return 0
}

check_config() {
  if [[ -z "$REMOTE_HOST" || -z "$REMOTE_PATH" ]]; then
    log_line "abort: CLAUDE_BRIDGE_TRUENAS_HOST or CLAUDE_BRIDGE_TRUENAS_PATH not set"
    return 1
  fi
  return 0
}

run_rsync() {
  local tmp
  tmp=$(mktemp -t truenas-sync.XXXXXX)
  "$PERL" -e 'alarm shift @ARGV; exec @ARGV' "$RSYNC_TIMEOUT_SEC" \
    "$RSYNC" \
      -a --delete --partial --human-readable \
      --stats \
      --exclude='.obsidian/workspace*' \
      --exclude='.obsidian/cache*' \
      --exclude='.Trash/' \
      --exclude='.DS_Store' \
      -e "$SSH -o BatchMode=yes -o ConnectTimeout=10" \
      "${VAULT%/}/" "$REMOTE_HOST:$REMOTE_PATH" \
      > "$tmp" 2>&1
  local rc=$?

  local bytes
  bytes=$(awk '/^Total transferred file size:/ {
                 for (i=1;i<=NF;i++) if ($i ~ /^[0-9,]+$/) { gsub(",","",$i); print $i; exit }
               }' "$tmp" 2>/dev/null)
  if [[ -z "$bytes" ]]; then
    bytes=$(awk '/^sent / { gsub(",","",$2); print $2; exit }' "$tmp" 2>/dev/null)
  fi
  [[ -z "$bytes" ]] && bytes=0

  if (( rc != 0 )); then
    log_line "rsync output tail:"
    tail -n 8 "$tmp" 2>/dev/null | while IFS= read -r line; do
      log_line "  $line"
    done
  fi
  rm -f "$tmp"

  echo "$bytes"
  return $rc
}

do_sync() {
  local mode="$1"
  local start end duration rc bytes

  if ! check_config; then
    return 1
  fi
  if ! check_vault; then
    return 1
  fi

  if ! probe_ssh; then
    log_summary "$mode" 0 2 0
    return 2
  fi

  start=$(date +%s)
  bytes=$(run_rsync)
  rc=$?
  end=$(date +%s)
  duration=$((end - start))

  log_summary "$mode" "$duration" "$rc" "${bytes:-0}"
  (( rc == 0 )) || return 3
  return 0
}

# ---- Modes ----

mode_once() {
  log_init
  if ! acquire_lock; then
    return 1
  fi
  do_sync once
  return $?
}

mode_watch() {
  log_init
  if ! acquire_lock; then
    return 1
  fi

  if [[ ! -x "$FSWATCH" ]]; then
    log_line "abort: fswatch not found at $FSWATCH (install with: brew install fswatch)"
    return 1
  fi
  if ! check_config; then
    return 1
  fi
  if ! check_vault; then
    return 1
  fi

  log_line "mode=watch starting (debounce=${DEBOUNCE_SEC}s)"

  do_sync watch-boot || true

  local pending=0
  while true; do
    if IFS= read -r -t "$DEBOUNCE_SEC" _event; then
      pending=1
    else
      if (( pending == 1 )); then
        do_sync watch || true
        pending=0
      fi
    fi
  done < <("$FSWATCH" \
              --latency=1 \
              --exclude='\.obsidian/workspace' \
              --exclude='\.obsidian/cache' \
              --exclude='\.Trash' \
              --exclude='\.DS_Store' \
              "$VAULT" 2>>"$LOG")
}

# ---- Entrypoint ----

main() {
  if (( $# != 1 )); then
    usage >&2
    return 4
  fi
  case "$1" in
    --once)  mode_once  ;;
    --watch) mode_watch ;;
    --help|-h) usage; return 0 ;;
    *) usage >&2; return 4 ;;
  esac
}

main "$@"
