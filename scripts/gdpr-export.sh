#!/usr/bin/env bash
# gdpr-export.sh — portable archive of everything claude-infinite-memory
# stores about you locally.  See docs/gdpr.md §Portability for context.
#
# Usage:
#   gdpr-export.sh [--output <path>] [--include-full-vault] [--dry-run]
#
# Default output: ~/Desktop/claude-memory-export-YYYYMMDD.tar.gz
# The archive includes a MANIFEST.md at its root.
#
# NOTE: The archive is raw (unfiltered).  Transcripts may contain content
# that the secret-redactor strips before sending to Anthropic.  Treat the
# archive with the same care you'd give the source files.

set -euo pipefail

# ── Locate config ────────────────────────────────────────────────────────────
ENV_FILE="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}/claude-infinite-memory.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
VAULT="${CLAUDE_BRIDGE_VAULT:-}"

# ── Argument parsing ─────────────────────────────────────────────────────────
DRY_RUN=0
INCLUDE_FULL_VAULT=0
DATESTAMP="$(date +%Y%m%d)"
OUTPUT_PATH="$HOME/Desktop/claude-memory-export-${DATESTAMP}.tar.gz"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_PATH="$2"; shift 2 ;;
    --include-full-vault)
      INCLUDE_FULL_VAULT=1; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
      exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { printf '\033[0;34m[export]\033[0m %s\n' "$*"; }
ok()    { printf '\033[0;32m[export]\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33m[export]\033[0m %s\n' "$*" >&2; }
skip()  { printf '\033[0;90m[export]\033[0m (not present, skipped) %s\n' "$*"; }

# Print size of a path if it exists, else "(not present)"
path_size() {
  local p="$1"
  if [[ -e "$p" ]]; then
    du -sh "$p" 2>/dev/null | cut -f1
  else
    echo "(not present)"
  fi
}

# Collect files/dirs into ENTRIES array: "source_path archive_name purpose origin"
declare -a ENTRIES=()
declare -a MANIFEST_LINES=()

add_entry() {
  local src="$1" arc_name="$2" purpose="$3" origin="$4"
  if [[ -e "$src" ]]; then
    ENTRIES+=("$src|$arc_name|$purpose|$origin")
  else
    skip "$src"
    MANIFEST_LINES+=("| \`$arc_name\` | $purpose | $origin | **(not present at export time)** |")
  fi
}

# ── Build file list ──────────────────────────────────────────────────────────
info "Scanning personal-data locations..."

add_entry \
  "$CLAUDE_BRIDGE_HOME/projects" \
  "projects" \
  "Claude Code session transcripts (JSONL) — raw session content" \
  "Created by Claude Code CLI; read by SessionEnd hook"

add_entry \
  "$CLAUDE_BRIDGE_HOME/sync-state" \
  "sync-state" \
  "Reconciliation state: processed session IDs + backup heartbeat timestamp" \
  "Written by reconciliation daemon and truenas-sync daemon"

add_entry \
  "$CLAUDE_BRIDGE_HOME/logs" \
  "logs" \
  "Hook activity logs: session IDs, REJECTED events, redactor output, daemon heartbeats" \
  "Written by SessionStart/SessionEnd hooks and background daemons"

# SQLite: dump as SQL (human-readable) rather than binary
DB_PATH="$CLAUDE_BRIDGE_HOME/sqlite-backend/vault-staging.db"
if [[ -f "$DB_PATH" ]]; then
  ENTRIES+=("$DB_PATH|sqlite-backend/vault-staging.sql|SQLite DB: L2 preferences, L3 session log, L4 compaction proposals (dumped as SQL)|Written by W5-W7 sqlite-backend daemons")
else
  skip "$DB_PATH"
  MANIFEST_LINES+=("| \`sqlite-backend/vault-staging.sql\` | SQLite DB (SQL dump) | W5-W7 sqlite-backend | **(not present at export time)** |")
fi

# Vault: Claude-authored knowledge files only (default scope)
CLAUDE_VAULT_DIR=""
if [[ -n "$VAULT" && -d "$VAULT/07 - Claude Knowledge" ]]; then
  CLAUDE_VAULT_DIR="$VAULT/07 - Claude Knowledge"
  ENTRIES+=("$CLAUDE_VAULT_DIR|vault-claude-knowledge|Claude-authored vault content: User Profile, Session Log, Technical Learnings, Historical Summaries, MOCs|Written by obsidian-sync skill and compaction/MOC daemons")
elif [[ -n "$VAULT" ]]; then
  skip "$VAULT/07 - Claude Knowledge"
  MANIFEST_LINES+=("| \`vault-claude-knowledge/\` | Claude-authored vault content | obsidian-sync skill | **(07 - Claude Knowledge not present)** |")
else
  warn "CLAUDE_BRIDGE_VAULT is not set — skipping vault content. Set it in $ENV_FILE or export it."
fi

# Optional: full vault
if [[ $INCLUDE_FULL_VAULT -eq 1 ]]; then
  if [[ -n "$VAULT" && -d "$VAULT" ]]; then
    ENTRIES+=("$VAULT|full-vault|ENTIRE vault directory (user-authored + Claude-authored content) — included via --include-full-vault|User-authored Obsidian notes + Claude writes")
  else
    warn "--include-full-vault requested but CLAUDE_BRIDGE_VAULT is not set or does not exist"
  fi
fi

# ── Dry-run: print file list ─────────────────────────────────────────────────
echo
echo "Files to archive:"
echo "─────────────────────────────────────────────────────────────"
TOTAL_SIZE=0
for entry in "${ENTRIES[@]}"; do
  IFS='|' read -r src arc purpose origin <<< "$entry"
  sz=$(path_size "$src")
  printf "  %-8s  %s\n" "$sz" "$src"
  printf "             → archive path: %s\n" "$arc"
  printf "             → purpose: %s\n" "$purpose"
done
echo "─────────────────────────────────────────────────────────────"

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  info "Dry-run complete. No archive created."
  info "Remove --dry-run to create: $OUTPUT_PATH"
  exit 0
fi

# ── Create staging area ──────────────────────────────────────────────────────
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

mkdir -p "$STAGING_DIR/export"

info "Copying files into staging area..."

for entry in "${ENTRIES[@]}"; do
  IFS='|' read -r src arc purpose origin <<< "$entry"

  if [[ "$arc" == "sqlite-backend/vault-staging.sql" ]]; then
    # Special case: dump SQLite to SQL text
    mkdir -p "$STAGING_DIR/export/sqlite-backend"
    info "Dumping SQLite DB to SQL..."
    sqlite3 "$src" .dump > "$STAGING_DIR/export/sqlite-backend/vault-staging.sql" \
      || warn "sqlite3 dump failed — DB may be locked or corrupt"
  elif [[ -d "$src" ]]; then
    mkdir -p "$STAGING_DIR/export/$(dirname "$arc")"
    cp -R "$src" "$STAGING_DIR/export/$arc"
  else
    mkdir -p "$STAGING_DIR/export/$(dirname "$arc")"
    cp "$src" "$STAGING_DIR/export/$arc"
  fi
done

# ── Generate MANIFEST.md ─────────────────────────────────────────────────────
MANIFEST="$STAGING_DIR/export/MANIFEST.md"
{
  echo "# Export Manifest"
  echo
  echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "System: claude-infinite-memory"
  echo "Host: $(hostname)"
  echo "Scope: $([ $INCLUDE_FULL_VAULT -eq 1 ] && echo 'full-vault (opt-in)' || echo 'system-generated content only')"
  echo
  echo "## Contents"
  echo
  echo "| Archive path | Purpose | Origin |"
  echo "|---|---|---|"

  for entry in "${ENTRIES[@]}"; do
    IFS='|' read -r src arc purpose origin <<< "$entry"
    echo "| \`$arc/\` | $purpose | $origin |"
  done

  # Pre-populated skipped entries
  for line in "${MANIFEST_LINES[@]+"${MANIFEST_LINES[@]}"}"; do
    echo "$line"
  done

  echo
  echo "## Notes"
  echo
  echo "- **Raw export**: transcripts are NOT pre-filtered by the secret redactor."
  echo "  Treat this archive with the same care you'd give the original files."
  echo "- **Anthropic API data** (claude -p call history) is not included here."
  echo "  To request deletion of that data, visit https://privacy.anthropic.com/"
  echo "- **Remote TrueNAS backup** is not included. Delete that separately."
  echo "  See docs/gdpr.md §Erasure for the rsync delete command."
  echo
  echo "## Data protection"
  echo
  echo "See docs/gdpr.md in the project repository for the full data-protection"
  echo "reference, including retention schedules and your rights."
} > "$MANIFEST"

# ── Create tarball ───────────────────────────────────────────────────────────
OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_DIR"

info "Creating archive at $OUTPUT_PATH ..."
tar -czf "$OUTPUT_PATH" -C "$STAGING_DIR/export" .

echo
ok "Export complete: $OUTPUT_PATH"
ok "$(du -sh "$OUTPUT_PATH" | cut -f1) compressed"
echo
echo "The archive contains a MANIFEST.md at its root describing every included file."
echo
echo "To inspect:"
echo "  tar -tzf $OUTPUT_PATH"
echo "  tar -xzf $OUTPUT_PATH -C ~/Desktop/claude-export-review/"
echo
echo "Anthropic API data (claude -p call history) is NOT in this archive."
echo "To request deletion: https://privacy.anthropic.com/"
