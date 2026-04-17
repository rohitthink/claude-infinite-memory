#!/bin/bash
# migrate-from-markdown.sh  One-time migration of User Profile.md into SQLite.
#
# Reads the existing markdown file, parses each section's bullet points,
# extracts seen_count and last_reinforced from inline annotations, and
# upserts each preference into user_preferences via ingest_preference().
#
# Idempotency: reruns are safe — the UNIQUE index on (category, preference)
# means re-inserting an existing row just increments seen_count by 1.
#
# On success, the original file is renamed to User Profile.md.pre-sqlite-backup.
# If the backup already exists it is overwritten (keeping only one backup copy).
#
# Exit codes:
#   0  migration complete (or no source file — nothing to do)
#   1  missing dependency or unreadable source file
#   2  DB initialisation / ingest failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source ingest.sh to inherit: CLAUDE_BRIDGE_HOME, DB, SQLITE, SQLITE_BUSY_MS,
# LOG, sqlq(), sqlq_int(), and ingest_preference().
# shellcheck source=ingest.sh
source "$SCRIPT_DIR/ingest.sh"

VAULT="${CLAUDE_BRIDGE_VAULT:-}"
KNOWLEDGE_DIR="${VAULT}/07 - Claude Knowledge"
PROFILE_FILE="${KNOWLEDGE_DIR}/User Profile.md"
BACKUP_FILE="${PROFILE_FILE}.pre-sqlite-backup"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [migrate-$$] $*" >> "$LOG"; }
echo_log() { echo "$*"; log "$*"; }

# ---- Dependency checks ----
if [[ ! -x "$SQLITE" ]]; then
  echo_log "ERROR: sqlite3 not executable at $SQLITE"
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo_log "ERROR: python3 not found in PATH"
  exit 1
fi
if [[ -z "$VAULT" || ! -d "$VAULT" ]]; then
  echo_log "ERROR: CLAUDE_BRIDGE_VAULT not set or not mounted: $VAULT"
  exit 1
fi

# ---- Locate source file ----
SOURCE_FILE=""
if [[ -f "$PROFILE_FILE" ]]; then
  SOURCE_FILE="$PROFILE_FILE"
elif [[ -f "$BACKUP_FILE" ]]; then
  echo_log "NOTE: original file already migrated; reading backup for idempotent rerun: $BACKUP_FILE"
  SOURCE_FILE="$BACKUP_FILE"
else
  echo_log "Nothing to migrate: $PROFILE_FILE not found"
  exit 0
fi

echo_log "Migrating $SOURCE_FILE → SQLite at $DB"

# ---- Ensure DB + schema exist ----
if [[ ! -f "$DB" ]]; then
  echo_log "Initialising DB at $DB"
  "$SQLITE" -cmd ".timeout $SQLITE_BUSY_MS" "$DB" < "$SCRIPT_DIR/schema.sql" 2>>"$LOG" || {
    echo_log "ERROR: schema apply failed"
    exit 2
  }
else
  # Always reapply schema so user_preferences table is present even if DB predates it.
  "$SQLITE" -cmd ".timeout $SQLITE_BUSY_MS" "$DB" < "$SCRIPT_DIR/schema.sql" 2>>"$LOG" || true
fi

# Ensure WAL mode.
"$SQLITE" -cmd ".timeout $SQLITE_BUSY_MS" "$DB" "PRAGMA journal_mode=WAL;" >/dev/null 2>>"$LOG" || true

# ---- Parse markdown and extract preferences using Python ----
PARSE_OUTPUT=$(python3 - "$SOURCE_FILE" <<'PYEOF'
import sys
import re

SECTION_MAP = {
    'communication style':  'communication',
    'technical preferences':'technical',
    'anti-patterns':        'antipattern',
    'tooling preferences':  'tooling',
    'pending review':       'pending',
    'pending':              'pending',
    'archive':              'archive',
}

try:
    content = open(sys.argv[1], encoding='utf-8').read()
except Exception as e:
    sys.exit(f"ERROR: cannot read file: {e}")

current_category = None
results = []

for line in content.split('\n'):
    # Section heading: ## Title or ## Title (date)
    m = re.match(r'^#{1,3}\s+(.+?)(?:\s*\(.*?\))?\s*$', line)
    if m:
        heading = m.group(1).strip().lower()
        # Strip "auto-expired YYYY-MM-DD" suffix for archive headings
        heading = re.sub(r'\s*\(auto-expired\s+[\d-]+\)', '', heading).strip()
        matched = False
        for key, cat in SECTION_MAP.items():
            if key in heading:
                current_category = cat
                matched = True
                break
        if not matched:
            current_category = None
        continue

    # Bullet point
    if current_category is None:
        continue
    bm = re.match(r'^[-*]\s+(.+)$', line)
    if not bm:
        continue
    entry = bm.group(1).strip()

    # Extract seen_count from "(seen Nx)" or "(seen N times)"
    seen_count = 1
    sm = re.search(r'\(seen\s+(\d+)\s*(?:x|times?)\b', entry, re.IGNORECASE)
    if sm:
        seen_count = int(sm.group(1))

    # Extract last_reinforced timestamp from various annotation patterns:
    #   (seen 3x, last 2026-04-15)
    #   (confirmed explicitly 2026-04-10 14:30:00)
    #   , last 2026-04-15
    last_reinforced = ''
    lr_m = re.search(
        r'(?:last|confirmed[^)]*?)\s+(20\d\d-\d{2}-\d{2}(?:\s+\d{2}:\d{2}:\d{2})?)',
        entry, re.IGNORECASE)
    if lr_m:
        last_reinforced = lr_m.group(1).strip()

    # Strip all annotation parentheticals and trailing noise.
    cleaned = re.sub(r'\s*\([^)]*\)', '', entry).strip()
    cleaned = re.sub(r',?\s*last\s+20\d\d-\d{2}-\d{2}.*$', '', cleaned).strip()
    cleaned = cleaned.rstrip('.,;').strip()

    if not cleaned:
        continue

    # Tab-separated: category \t preference \t seen_count \t last_reinforced
    # Replace literal tabs in fields just in case.
    row_parts = [
        current_category,
        cleaned.replace('\t', ' '),
        str(seen_count),
        last_reinforced,
    ]
    print('\t'.join(row_parts))

PYEOF
)

PARSE_EXIT=$?
if [[ $PARSE_EXIT -ne 0 ]]; then
  echo_log "ERROR: Python parser exited $PARSE_EXIT"
  exit 1
fi

if [[ -z "$PARSE_OUTPUT" ]]; then
  echo_log "No preferences found in $SOURCE_FILE"
else
  # Read tab-separated rows and call ingest_preference for each.
  MIGRATED=0
  FAILED=0
  while IFS=$'\t' read -r category preference seen_count last_reinforced; do
    [[ -z "$preference" ]] && continue
    if ingest_preference "$category" "$preference" "migration" "$(hostname -s 2>/dev/null || echo unknown)" "" "$seen_count" "$last_reinforced"; then
      MIGRATED=$((MIGRATED + 1))
    else
      FAILED=$((FAILED + 1))
      echo_log "WARN: failed to ingest: [$category] $preference"
    fi
  done <<< "$PARSE_OUTPUT"

  echo_log "Migration complete: $MIGRATED preferences ingested, $FAILED failed"
  [[ $FAILED -gt 0 ]] && exit 2
fi

# ---- Rename original to backup (only if we read the original, not the backup) ----
if [[ "$SOURCE_FILE" == "$PROFILE_FILE" ]]; then
  mv -f "$PROFILE_FILE" "$BACKUP_FILE"
  echo_log "Renamed $PROFILE_FILE → $BACKUP_FILE"
fi

echo_log "Done. Run export-to-vault.sh --section user-profile to regenerate the markdown view."
exit 0
