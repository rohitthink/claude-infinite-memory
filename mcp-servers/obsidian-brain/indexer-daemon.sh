#!/bin/bash
# launchd-invoked wrapper for the obsidian-brain indexer.
#
# Runs every StartInterval seconds (see the plist). Philosophy:
#   - One-shot per invocation (no daemon loop inside  launchd handles cadence).
#   - Cheap no-op if the vault is unmounted.
#   - Cheap no-op if nothing has changed since the last run, decided by
#     comparing the newest file mtime in the vault to the indexer's DB mtime.
#     The indexer itself is also incremental, but this shortcut avoids even
#     booting the Python interpreter when nothing has changed.
#   - Atomic-enough via mkdir lock  if two invocations race (e.g., user
#     ran indexer.py by hand while launchd fired), only one proceeds.

set -uo pipefail

# ---- Configuration (override via env) ----
CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
VAULT="${CLAUDE_BRIDGE_VAULT:-}"
PYTHON="${CLAUDE_BRIDGE_PYTHON:-/opt/homebrew/bin/python3}"

BRAIN_DIR="${CLAUDE_BRIDGE_HOME}/mcp-servers/obsidian-brain"
DB="$BRAIN_DIR/index.db"
INDEXER="$BRAIN_DIR/indexer.py"
LOG_DIR="${CLAUDE_BRIDGE_HOME}/logs"
LOG="$LOG_DIR/obsidian-brain-indexer.log"
LOCK_DIR="$BRAIN_DIR/.indexer-lock"

mkdir -p "$LOG_DIR"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [daemon] $*" >> "$LOG"
}

# Vault must be present.
if [[ -z "$VAULT" || ! -d "$VAULT" ]]; then
  # Don't spam the log on every 5-min tick when the volume is missing
  # only log if the last line isn't already "vault not mounted".
  last=$(tail -1 "$LOG" 2>/dev/null || true)
  if [[ "$last" != *"vault not mounted"* ]]; then
    log "vault not mounted at $VAULT  skipping"
  fi
  exit 0
fi

# Python must exist. (Homebrew on external drives sometimes isn't on PATH
# for launchd, which has a minimal env.)
if [[ ! -x "$PYTHON" ]]; then
  log "ABORT: python missing at $PYTHON"
  exit 1
fi

# Acquire mkdir-based lock. atomic on POSIX.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "skipped (another indexer is running)"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

# Fast-path: if the DB is newer than the newest .md file in the vault,
# there's nothing to do. `find -newer` with the DB gives us the first file
# that postdates the DB  if none, we skip.
if [[ -f "$DB" ]]; then
  newer=$(find "$VAULT" -type f -name "*.md" \
    ! -path "$VAULT/.*" \
    ! -path "$VAULT/05 - Personal/*" \
    -newer "$DB" -print -quit 2>/dev/null || true)
  if [[ -z "$newer" ]]; then
    exit 0
  fi
fi

log "running incremental index"
"$PYTHON" "$INDEXER" --quiet >> "$LOG" 2>&1
rc=$?
log "indexer exit=$rc"
exit "$rc"
