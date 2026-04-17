#!/bin/bash
# migrate-l4-cache.sh — seed the L4 SQLite cache from existing vault state.
#
# Idempotent: re-running is a no-op thanks to PK and UNIQUE constraints.
#
# What it does:
#   1. Walks VAULT/07 - Claude Knowledge/Historical Summaries/*.proposed.md
#      and upserts a compaction_proposals row with status='staged'.
#   2. Walks VAULT/07 - Claude Knowledge/Historical Summaries/*.md (applied
#      summaries — no .proposed. in the name) and upserts rows with
#      status='applied', applied_at=file mtime.
#   3. Does a full vault scan to seed moc_file_tags for all .md files.
#
# Usage:
#   migrate-l4-cache.sh [--vault-override <path>] [--dry-run] [--help]
#
# Environment:
#   CLAUDE_BRIDGE_HOME  — where the DB lives (default: ~/.claude)
#   CLAUDE_BRIDGE_VAULT — your Obsidian vault path

set -uo pipefail

CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
DEFAULT_VAULT="${CLAUDE_BRIDGE_VAULT:-}"
SQLITE_DB="${CLAUDE_BRIDGE_HOME}/claude-bridge.db"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_SQL="$SCRIPT_DIR/schema.sql"

LOG_DIR="${CLAUDE_BRIDGE_HOME}/logs"
LOG="$LOG_DIR/compaction.log"
mkdir -p "$LOG_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [migrate-l4-$$] $*" >> "$LOG"; }

DRY_RUN=0
VAULT="${VAULT_OVERRIDE:-$DEFAULT_VAULT}"

usage() {
  cat <<'EOF'
migrate-l4-cache.sh — seed the L4 SQLite cache from existing vault state

Usage:
  migrate-l4-cache.sh [flags]

Flags:
  --vault-override <path>  Use a different vault (default: CLAUDE_BRIDGE_VAULT).
  --dry-run                Print what would be inserted; no DB writes.
  --help                   Show this help.

This script is idempotent — safe to run multiple times.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-override) VAULT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$VAULT" ]] || [[ ! -d "$VAULT" ]]; then
  echo "ERROR: vault not set or not found: $VAULT" >&2
  exit 1
fi

HISTORICAL_DIR="$VAULT/07 - Claude Knowledge/Historical Summaries"
KNOWLEDGE_DIR="$VAULT/07 - Claude Knowledge"

# ---- Helpers ----

sql_esc() { printf '%s' "$1" | sed "s/'/''/g"; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    echo "unknown"
  fi
}

mtime_iso() {
  local ts
  ts=$(stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || echo 0)
  date -r "$ts" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d "@$ts" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "$ts"
}

quarter_for_basename() {
  local base="$1"
  if [[ "$base" =~ ^([0-9]{4}-Q[1-4]) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "unknown"
  fi
}

db_exec() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN SQL] $1"
  else
    sqlite3 "$SQLITE_DB" "$1" 2>>"$LOG" || log "WARN: db_exec failed: $1"
  fi
}

db_query() {
  sqlite3 "$SQLITE_DB" "$1" 2>>"$LOG"
}

# ---- Ensure DB schema ----
if [[ "$DRY_RUN" -ne 1 ]]; then
  if [[ ! -f "$SCHEMA_SQL" ]]; then
    echo "ERROR: schema.sql not found at $SCHEMA_SQL" >&2
    exit 1
  fi
  sqlite3 "$SQLITE_DB" < "$SCHEMA_SQL" 2>>"$LOG" || { echo "ERROR: schema init failed" >&2; exit 1; }
  log "schema ensured at $SQLITE_DB"
fi

echo "=== migrate-l4-cache: starting ==="
log "=== migrate-l4-cache start | vault=$VAULT dry_run=$DRY_RUN ==="

staged_count=0
applied_count=0
moc_files=0
moc_tags=0

# ========================================================================
# 1. Seed compaction_proposals from *.proposed.md (staged)
# ========================================================================
if [[ -d "$HISTORICAL_DIR" ]]; then
  while IFS= read -r -d '' prop; do
    base="${prop##*/}"
    qname="${base%.proposed.md}"
    if ! [[ "$qname" =~ ^[0-9]{4}-Q[1-4]$ ]]; then
      echo "  SKIP (non-quarter filename): $base"
      continue
    fi
    rel_path="${prop#$VAULT/}"
    sha=$(sha256_file "$prop")
    file_mtime_iso=$(mtime_iso "$prop")

    # Only insert if no staged row already exists for this path+quarter.
    existing=$(db_query "SELECT COUNT(*) FROM compaction_proposals WHERE proposal_path='$(sql_esc "$rel_path")' AND status='staged';" 2>/dev/null || echo 0)
    if [[ "${existing:-0}" -gt 0 ]]; then
      echo "  SKIP (already staged in DB): $base"
      log "migrate: skip already-staged $rel_path"
      continue
    fi

    echo "  STAGED proposal: $base (sha256=$sha)"
    log "migrate: inserting staged proposal $rel_path quarter=$qname"

    db_exec "INSERT OR IGNORE INTO compaction_proposals (quarter,kind,source_entries,source_start,source_end,proposal_path,proposal_sha256,status,created_at) VALUES ('$(sql_esc "$qname")','session_log',0,'$(sql_esc "$qname")','$(sql_esc "$qname")','$(sql_esc "$rel_path")','$(sql_esc "$sha")','staged','$(sql_esc "$file_mtime_iso")');"
    staged_count=$((staged_count + 1))
  done < <(find "$HISTORICAL_DIR" -maxdepth 1 -type f -name '*.proposed.md' -print0 2>/dev/null)

  # ---- Applied summaries *.md (no .proposed. in name) ----
  while IFS= read -r -d '' sumfile; do
    base="${sumfile##*/}"
    [[ "$base" == *".proposed."* ]] && continue
    qname="${base%.md}"
    if ! [[ "$qname" =~ ^[0-9]{4}-Q[1-4]$ ]]; then
      continue
    fi
    rel_path="${sumfile#$VAULT/}"
    sha=$(sha256_file "$sumfile")
    applied_ts=$(mtime_iso "$sumfile")

    existing=$(db_query "SELECT COUNT(*) FROM compaction_proposals WHERE proposal_path='$(sql_esc "$rel_path")' AND status='applied';" 2>/dev/null || echo 0)
    if [[ "${existing:-0}" -gt 0 ]]; then
      echo "  SKIP (already applied in DB): $base"
      continue
    fi

    echo "  APPLIED summary: $base (applied_at=$applied_ts)"
    log "migrate: inserting applied summary $rel_path quarter=$qname"

    db_exec "INSERT OR IGNORE INTO compaction_proposals (quarter,kind,source_entries,source_start,source_end,proposal_path,proposal_sha256,status,created_at,applied_at) VALUES ('$(sql_esc "$qname")','session_log',0,'$(sql_esc "$qname")','$(sql_esc "$qname")','$(sql_esc "$rel_path")','$(sql_esc "$sha")','applied','$(sql_esc "$applied_ts")','$(sql_esc "$applied_ts")');"
    applied_count=$((applied_count + 1))
  done < <(find "$HISTORICAL_DIR" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)
fi

echo "  compaction_proposals: staged=$staged_count applied=$applied_count"
log "migrate: proposals done staged=$staged_count applied=$applied_count"

# ========================================================================
# 2. Seed moc_file_tags via full vault scan
# ========================================================================
echo ""
echo "=== Seeding moc_file_tags (full vault scan) ==="

# Build candidate list from 07 - Claude Knowledge/ + _Maps/
SCAN_LIST="$(mktemp -t mig-scan.XXXXXX)"
trap 'rm -f "$SCAN_LIST"' EXIT INT TERM

find "$KNOWLEDGE_DIR" -maxdepth 1 -type f -name '*.md' -print 2>/dev/null >> "$SCAN_LIST" || true
if [[ -d "$VAULT/_Maps" ]]; then
  find "$VAULT/_Maps" -maxdepth 1 -type f -name '*.md' -print 2>/dev/null >> "$SCAN_LIST" || true
fi

now_ts=$(date '+%Y-%m-%d %H:%M:%S')

while IFS= read -r file; do
  [[ -f "$file" ]] || continue
  rel_file="${file#$VAULT/}"
  current_mtime=$(stat -f '%m' "$file" 2>/dev/null || stat -c '%Y' "$file" 2>/dev/null || echo 0)

  # Skip if already cached and mtime unchanged.
  if [[ "$DRY_RUN" -ne 1 ]]; then
    cached_mtime=$(db_query "SELECT MAX(file_mtime) FROM moc_file_tags WHERE file_path='$(sql_esc "$rel_file")';" 2>/dev/null || echo 0)
    cached_mtime="${cached_mtime:-0}"
    if [[ "$current_mtime" -le "${cached_mtime:-0}" ]]; then
      moc_files=$((moc_files + 1))
      continue
    fi
  fi

  # Parse frontmatter tags.
  fm_tags=$(awk '
    BEGIN { in_fm=0; fm_seen=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; fm_seen=1; next }
    in_fm && /^---[[:space:]]*$/ { in_fm=0; exit }
    in_fm && /^tags:[[:space:]]*\[/ {
      line=$0; sub(/^tags:[[:space:]]*\[/,"",line); sub(/\].*$/,"",line); print line
    }
  ' "$file" 2>/dev/null)

  file_tags=()
  if [[ -n "$fm_tags" ]]; then
    IFS=',' read -r -a tag_array <<< "$fm_tags"
    for t in "${tag_array[@]}"; do
      t="${t## }"; t="${t%% }"; t="${t//\"/}"; t="${t//\'/}"
      t=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]'); t="${t#\#}"
      [[ -n "$t" ]] && file_tags+=("$t")
    done
  fi

  # Parse inline heading #tags.
  while IFS= read -r hline; do
    while IFS= read -r token; do
      t="${token#\#}"; t=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
      [[ -n "$t" ]] && file_tags+=("$t")
    done < <(printf '%s' "$hline" | grep -oE '#[a-zA-Z][a-zA-Z0-9_-]+' || true)
  done < <(grep -E '^#+\s+' "$file" 2>/dev/null || true)

  # Deduplicate.
  IFS=$'\n' sorted_tags=($(printf '%s\n' "${file_tags[@]:-}" | sort -u))
  unset IFS

  [[ "${#sorted_tags[@]}" -eq 0 ]] && { moc_files=$((moc_files + 1)); continue; }

  echo "  $rel_file: ${#sorted_tags[@]} tag(s)"

  if [[ "$DRY_RUN" -ne 1 ]]; then
    {
      echo "BEGIN;"
      echo "DELETE FROM moc_file_tags WHERE file_path='$(sql_esc "$rel_file")';"
      for tag_val in "${sorted_tags[@]}"; do
        echo "INSERT OR REPLACE INTO moc_file_tags (file_path,tag,last_scanned_at,file_mtime) VALUES ('$(sql_esc "$rel_file")','$(sql_esc "$tag_val")','$now_ts',$current_mtime);"
        moc_tags=$((moc_tags + 1))
      done
      echo "COMMIT;"
    } | sqlite3 "$SQLITE_DB" 2>>"$LOG"
  else
    for tag_val in "${sorted_tags[@]}"; do
      echo "  [DRY-RUN] INSERT moc_file_tags: $rel_file tag=$tag_val"
      moc_tags=$((moc_tags + 1))
    done
  fi
  moc_files=$((moc_files + 1))
done < "$SCAN_LIST"

echo "  moc_file_tags: files=$moc_files tags=$moc_tags"
log "migrate: moc_file_tags seeded files=$moc_files tags=$moc_tags"
echo ""
echo "=== migrate-l4-cache done: proposals(staged=$staged_count applied=$applied_count) moc(files=$moc_files tags=$moc_tags) ==="
log "=== migrate-l4-cache done ==="
exit 0
