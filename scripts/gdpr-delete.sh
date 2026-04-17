#!/usr/bin/env bash
# gdpr-delete.sh — right-to-erasure helper for claude-infinite-memory.
# See docs/gdpr.md §Erasure for the full narrative.
#
# Usage:
#   gdpr-delete.sh [--tier=system-state|claude-vault-content|all]
#                  [--dry-run] [--confirm] [--skip-export-offer]
#
# Tiers:
#   system-state         (default) transcripts, logs, sync-state, sqlite DB.
#                        Leaves your vault untouched.
#   claude-vault-content Above + removes 07 - Claude Knowledge/ from vault.
#                        This is Claude's "brain"; your own notes are unaffected.
#   all                  Above + the entire $CLAUDE_BRIDGE_HOME directory.
#                        A fresh install will recreate everything.
#
# SAFETY:
#   --dry-run is the DEFAULT.  Nothing is deleted unless --confirm is passed.
#   --confirm is required for real deletion; there is no undo.

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
TIER="system-state"
DRY_RUN=1          # DEFAULT: dry-run; --confirm flips this
CONFIRM=0
SKIP_EXPORT_OFFER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier=*)
      TIER="${1#--tier=}"; shift ;;
    --tier)
      TIER="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    --confirm)
      DRY_RUN=0; CONFIRM=1; shift ;;
    --skip-export-offer)
      SKIP_EXPORT_OFFER=1; shift ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30
      exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

case "$TIER" in
  system-state|claude-vault-content|all) ;;
  *)
    echo "Error: --tier must be one of: system-state, claude-vault-content, all" >&2
    exit 1 ;;
esac

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { printf '\033[0;34m[delete]\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33m[delete]\033[0m %s\n' "$*" >&2; }
err()   { printf '\033[0;31m[delete]\033[0m %s\n' "$*" >&2; }
ok()    { printf '\033[0;32m[delete]\033[0m %s\n' "$*"; }
skip()  { printf '\033[0;90m[delete]\033[0m (not present, skipped) %s\n' "$*"; }

# Returns "X.XM" size or "(not present)"
entry_size() {
  local p="$1"
  if [[ -e "$p" ]]; then
    du -sh "$p" 2>/dev/null | cut -f1
  else
    echo "(not present)"
  fi
}

# ── Build deletion plan ───────────────────────────────────────────────────────
# Each entry: "path|label|description"
declare -a PLAN=()

plan_add() {
  PLAN+=("$1|$2|$3")
}

# Tier 1: system-state (always included)
plan_add \
  "$CLAUDE_BRIDGE_HOME/projects" \
  "Transcripts" \
  "Claude Code session JSONL files (everything you typed or pasted)"

plan_add \
  "$CLAUDE_BRIDGE_HOME/sync-state" \
  "Sync state" \
  "reconciled.txt (session IDs) + truenas heartbeat timestamp"

plan_add \
  "$CLAUDE_BRIDGE_HOME/logs" \
  "Log files" \
  "Hook activity, REJECTED events, redactor output, daemon logs"

plan_add \
  "$CLAUDE_BRIDGE_HOME/sqlite-backend/vault-staging.db" \
  "SQLite DB" \
  "L2 preferences, L3 session log, L4 compaction proposals (vault-staging.db)"

# Tier 2: claude-vault-content (includes tier 1)
if [[ "$TIER" == "claude-vault-content" || "$TIER" == "all" ]]; then
  if [[ -n "$VAULT" ]]; then
    CLAUDE_KNO="$VAULT/07 - Claude Knowledge"
    plan_add \
      "$CLAUDE_KNO" \
      "Claude vault content" \
      "07 - Claude Knowledge/: User Profile, Session Log, Technical Learnings, Historical Summaries, MOCs"
  else
    warn "CLAUDE_BRIDGE_VAULT is not set — cannot include vault content in plan."
    warn "Set CLAUDE_BRIDGE_VAULT in $ENV_FILE or export it before running."
  fi
fi

# Tier 3: all (includes tier 1 + 2 + entire CLAUDE_BRIDGE_HOME)
if [[ "$TIER" == "all" ]]; then
  plan_add \
    "$CLAUDE_BRIDGE_HOME" \
    "CLAUDE_BRIDGE_HOME" \
    "Entire bridge home directory ($CLAUDE_BRIDGE_HOME) — hooks, daemons, MCP server, config, all of the above"
fi

# ── Print plan ────────────────────────────────────────────────────────────────
echo
echo "══════════════════════════════════════════════════════════════"
echo "  claude-infinite-memory — Erasure Plan"
printf "  Tier: %s\n" "$TIER"
printf "  Mode: %s\n" "$([ $DRY_RUN -eq 1 ] && echo 'DRY RUN (no changes)' || echo '*** LIVE DELETION ***')"
echo "══════════════════════════════════════════════════════════════"
echo
echo "The following will be $([ $DRY_RUN -eq 1 ] && echo 'deleted (dry-run preview)' || echo 'PERMANENTLY DELETED'):"
echo

ITEM_NUM=0
declare -a EXISTING_PATHS=()

for entry in "${PLAN[@]}"; do
  IFS='|' read -r path label desc <<< "$entry"
  ITEM_NUM=$((ITEM_NUM + 1))
  sz=$(entry_size "$path")
  if [[ -e "$path" ]]; then
    printf "  %2d. %-22s  %s\n" "$ITEM_NUM" "[$sz]" "$path"
    printf "      %s\n" "$desc"
    EXISTING_PATHS+=("$path")
  else
    printf "  %2d. %-22s  %s\n" "$ITEM_NUM" "(not present)" "$path"
    printf "      %s — SKIPPED\n" "$desc"
  fi
  echo
done

if [[ ${#EXISTING_PATHS[@]} -eq 0 ]]; then
  info "Nothing to delete — all paths are absent."
  exit 0
fi

echo "══════════════════════════════════════════════════════════════"
echo

# ── Dry-run exit ──────────────────────────────────────────────────────────────
if [[ $DRY_RUN -eq 1 ]]; then
  info "Dry-run complete. No files were modified."
  echo
  echo "To actually delete, re-run with --confirm:"
  echo "  $0 --tier=$TIER --confirm"
  echo
  echo "To back up first (recommended):"
  local_script_dir="$(cd "$(dirname "$0")" && pwd)"
  echo "  $local_script_dir/gdpr-export.sh"
  exit 0
fi

# ── Export offer ──────────────────────────────────────────────────────────────
if [[ $SKIP_EXPORT_OFFER -eq 0 ]]; then
  echo "Before deletion, would you like to create an export archive?"
  echo "  This backs up everything about to be deleted."
  printf "  Back up first? [y/N] "
  read -r ANSWER
  if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    EXPORT_SCRIPT="$SCRIPT_DIR/gdpr-export.sh"
    if [[ -x "$EXPORT_SCRIPT" ]]; then
      info "Running gdpr-export.sh ..."
      "$EXPORT_SCRIPT"
      echo
    else
      warn "gdpr-export.sh not found or not executable at $EXPORT_SCRIPT"
      warn "Skipping export. Continue with deletion? [y/N]"
      read -r ANS2
      if [[ ! "$ANS2" =~ ^[Yy]$ ]]; then
        info "Aborted."
        exit 0
      fi
    fi
  fi
fi

# ── Final confirmation ────────────────────────────────────────────────────────
echo
warn "THIS WILL PERMANENTLY DELETE ${#EXISTING_PATHS[@]} ITEM(S). THERE IS NO UNDO."
printf "  Type 'DELETE' to confirm: "
read -r CONFIRMATION
if [[ "$CONFIRMATION" != "DELETE" ]]; then
  info "Confirmation not received. Aborted — no files deleted."
  exit 0
fi

# ── Execute deletion ──────────────────────────────────────────────────────────
echo
info "Deleting..."

for entry in "${PLAN[@]}"; do
  IFS='|' read -r path label desc <<< "$entry"
  if [[ -e "$path" ]]; then
    if [[ -d "$path" ]]; then
      rm -rf "$path"
      ok "Removed directory: $path"
    else
      rm -f "$path"
      ok "Removed file: $path"
    fi
  else
    skip "$path"
  fi
done

# ── Post-deletion messaging ───────────────────────────────────────────────────
echo
echo "══════════════════════════════════════════════════════════════"
ok "Local data removal complete."
echo
echo "Your local claude-infinite-memory data has been removed."
echo
echo "IMPORTANT — data that was NOT removed by this script:"
echo
echo "  1. Anthropic API history (claude -p call logs):"
echo "     To request deletion, contact Anthropic:"
echo "       https://privacy.anthropic.com/"
echo "       privacy@anthropic.com"
echo "     Instructions: docs/gdpr.md §Erasure"
echo
if [[ -n "$VAULT" ]]; then
  TRUENAS_HOST="${TRUENAS_USER:-<truenas-user>}@${TRUENAS_HOST:-<truenas-host>}"
  echo "  2. TrueNAS / remote backup (if configured):"
  echo "     This script does NOT touch remote hosts."
  echo "     To delete the vault backup from your TrueNAS host:"
  echo "       rsync --delete -av --filter='P ./' \\"
  echo "         /tmp/empty-dir/ \\"
  echo "         $TRUENAS_HOST:<vault-backup-path>/"
  echo "     Or remove the dataset directly on the TrueNAS host."
  echo
fi
echo "  3. Cloud sync copies (Obsidian Sync, iCloud, Syncthing):"
echo "     Remove the synced vault from your cloud provider's"
echo "     dashboard or sync settings."
echo "══════════════════════════════════════════════════════════════"
