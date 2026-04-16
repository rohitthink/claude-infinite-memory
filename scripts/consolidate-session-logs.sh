#!/bin/bash
# consolidate-session-logs.sh
#
# Merges per-device Session Log files (`Session Log - <hostname>.md`) into
# the canonical `Session Log.md` and archives the per-device files.
#
# Designed to run weekly via cron (or manually). Uses the same global
# mkdir-based lockfile as the SessionEnd hook so it serializes against
# live session sync writes.
#
# Architecture:
#   - Reads each `Session Log - *.md` from vault/07 - Claude Knowledge/
#   - Extracts entries matching `## YYYY-MM-DD` (each entry = one section)
#   - Merges with existing canonical entries, sorts by date descending
#   - Writes merged result to canonical file (preserves frontmatter + footer)
#   - Moves consumed per-device files to `_device-logs-archive/YYYYMMDD/`
#
# Safety:
#   - Dry-run by default (DRYRUN=1 env var or --dry-run flag)
#   - Won't run if lockfile is held by another sync
#   - Validates per-device files match `Session Log - *.md` glob
#   - Never deletes files always moves to archive

set -uo pipefail

# ---- Configuration (override via env) ----
CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
VAULT="${CLAUDE_BRIDGE_VAULT:-}"

CK_DIR="$VAULT/07 - Claude Knowledge"
CANONICAL="$CK_DIR/Session Log.md"
ARCHIVE_ROOT="$CK_DIR/_device-logs-archive"
LOCK_DIR="${CLAUDE_BRIDGE_HOME}/sync-active/vault-sync.lock"
LOG_DIR="${CLAUDE_BRIDGE_HOME}/logs"
LOG="$LOG_DIR/consolidate-session-logs.log"

DRYRUN="${DRYRUN:-0}"
if [[ "${1:-}" == "--dry-run" ]]; then DRYRUN=1; fi
if [[ "${1:-}" == "--help" ]]; then
  cat <<HELP
consolidate-session-logs.sh merge per-device Session Log files into canonical

Usage:
  consolidate-session-logs.sh              # live merge (with lock)
  consolidate-session-logs.sh --dry-run    # preview what would happen
  DRYRUN=1 consolidate-session-logs.sh     # same as --dry-run

Run this after multiple devices have written their per-device session logs.
Archives consumed files to _device-logs-archive/YYYYMMDD/.
HELP
  exit 0
fi

mkdir -p "$LOG_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [consolidate-$$] $*" >> "$LOG"; echo "$*"; }

# ---- Sanity checks ----
if [[ -z "$VAULT" || ! -d "$VAULT" ]]; then
  log "ERROR: vault not set or not mounted at $VAULT"
  exit 1
fi
if [[ ! -f "$CANONICAL" ]]; then
  log "ERROR: canonical Session Log.md not found at $CANONICAL"
  exit 1
fi

# ---- Enumerate per-device logs ----
shopt -s nullglob
DEVICE_LOGS=("$CK_DIR/Session Log - "*.md)
shopt -u nullglob

if [[ ${#DEVICE_LOGS[@]} -eq 0 ]]; then
  log "no per-device Session Log files found; nothing to consolidate"
  exit 0
fi

log "found ${#DEVICE_LOGS[@]} per-device logs:"
for f in "${DEVICE_LOGS[@]}"; do
  log "  - $(basename "$f") ($(wc -l <"$f" | tr -d ' ') lines)"
done

# ---- Acquire global lock (unless dry-run) ----
if [[ "$DRYRUN" != "1" ]]; then
  log "acquiring global vault lock (wait up to 300s)..."
  ACQUIRED=0
  for i in $(seq 1 300); do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      ACQUIRED=1
      break
    fi
    sleep 1
  done
  if [[ $ACQUIRED -eq 0 ]]; then
    log "ABORT: could not acquire vault lock (is a sync in progress?)"
    exit 1
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM
  log "lock acquired"
fi

# ---- Extract entries from each per-device file ----
TODAY=$(date '+%Y%m%d')
ARCHIVE_DIR="$ARCHIVE_ROOT/$TODAY"
WORK_DIR=$(mktemp -d -t consolidate.XXXXXX)

log "staging entries in $WORK_DIR"

ENTRY_COUNT=0
for f in "${DEVICE_LOGS[@]}"; do
  DEVICE_NAME=$(basename "$f" | sed 's/^Session Log - //; s/\.md$//')
  awk -v device="$DEVICE_NAME" -v outdir="$WORK_DIR" '
    BEGIN { entry=""; date="" }
    /^## [0-9]{4}-[0-9]{2}-[0-9]{2}/ {
      if (entry != "" && date != "") {
        outfile = outdir "/" date "_" device "_" NR ".entry"
        print entry > outfile
        close(outfile)
      }
      date = $2
      entry = $0
      next
    }
    /^## [A-Z]/ || /^---$/ {
      if (entry != "" && date != "") {
        outfile = outdir "/" date "_" device "_" NR ".entry"
        print entry > outfile
        close(outfile)
        entry = ""
        date = ""
      }
      next
    }
    {
      if (entry != "") entry = entry "\n" $0
    }
    END {
      if (entry != "" && date != "") {
        outfile = outdir "/" date "_" device "_END.entry"
        print entry > outfile
        close(outfile)
      }
    }
  ' "$f"
  COUNT=$(ls "$WORK_DIR" 2>/dev/null | grep -c "_${DEVICE_NAME}_" || echo 0)
  log "  extracted $COUNT entries from $(basename "$f")"
  ENTRY_COUNT=$((ENTRY_COUNT + COUNT))
done

if [[ $ENTRY_COUNT -eq 0 ]]; then
  log "no entries extracted from per-device files; nothing to merge"
  rm -rf "$WORK_DIR"
  exit 0
fi

log "total entries to merge: $ENTRY_COUNT"

# ---- Build merged canonical ----
NEW_CANONICAL=$(mktemp -t new-canonical.XXXXXX.md)

awk '
  BEGIN { section=0 }
  /^---$/ { section++; print; if (section == 2) exit; next }
  { print }
' "$CANONICAL" > "$NEW_CANONICAL"

TODAY_ISO=$(date '+%Y-%m-%d')
sed -i '' "s/^last-updated: .*$/last-updated: $TODAY_ISO/" "$NEW_CANONICAL" 2>/dev/null || \
  sed -i "s/^last-updated: .*$/last-updated: $TODAY_ISO/" "$NEW_CANONICAL"

echo "" >> "$NEW_CANONICAL"

awk '
  BEGIN { in_body=0; entry=""; date="" }
  /^---$/ { sep++; if (sep == 2) in_body=1; next }
  in_body == 0 { next }
  /^## [0-9]{4}-[0-9]{2}-[0-9]{2}/ {
    if (entry != "" && date != "") print entry > "'"$WORK_DIR"'/" date "_canonical_" NR ".entry"
    date = $2
    entry = $0
    next
  }
  /^> \[!tip\]/ || /^## Related/ {
    if (entry != "" && date != "") print entry > "'"$WORK_DIR"'/" date "_canonical_END.entry"
    exit
  }
  {
    if (entry != "") entry = entry "\n" $0
  }
' "$CANONICAL"

ls "$WORK_DIR"/*.entry 2>/dev/null | sort -r | while read entry_file; do
  cat "$entry_file" >> "$NEW_CANONICAL"
  echo "" >> "$NEW_CANONICAL"
done

awk '/^> \[!tip\]/,0' "$CANONICAL" >> "$NEW_CANONICAL"

BEFORE_SIZE=$(wc -c <"$CANONICAL" | tr -d ' ')
AFTER_SIZE=$(wc -c <"$NEW_CANONICAL" | tr -d ' ')
log "canonical: $BEFORE_SIZE bytes -> $AFTER_SIZE bytes"

if [[ "$DRYRUN" == "1" ]]; then
  log "DRY RUN not writing canonical or archiving per-device files"
  log "preview of merged canonical (first 40 lines):"
  head -40 "$NEW_CANONICAL" | sed 's/^/    /'
  rm -rf "$WORK_DIR" "$NEW_CANONICAL"
  exit 0
fi

# ---- Commit: replace canonical, archive per-device logs ----
cp "$CANONICAL" "$CANONICAL.backup-$TODAY"
mv "$NEW_CANONICAL" "$CANONICAL"
log "wrote merged canonical; backup at $CANONICAL.backup-$TODAY"

mkdir -p "$ARCHIVE_DIR"
for f in "${DEVICE_LOGS[@]}"; do
  mv "$f" "$ARCHIVE_DIR/"
  log "archived $(basename "$f") -> $ARCHIVE_DIR/"
done

rm -rf "$WORK_DIR"
log "consolidation complete"
