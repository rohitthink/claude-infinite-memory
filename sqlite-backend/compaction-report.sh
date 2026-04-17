#!/bin/bash
# compaction-report.sh — L4 state summary for the compaction + MOC subsystems.
#
# Replaces the scattered --list-pending / --dry-run outputs from the daemons
# with a single unified view. Reads only from the SQLite DB; never writes.
#
# Prints:
#   1. Staged (pending) proposals — ordered by quarter
#   2. Recently applied proposals (last 12 months)
#   3. Orphaned proposals (file disappeared; need investigation)
#   4. MOC cache freshness stats (oldest scan timestamp, file count, tag count)
#
# Usage:
#   compaction-report.sh [--help]
#
# Environment:
#   CLAUDE_BRIDGE_HOME  — DB location (default: ~/.claude)

set -uo pipefail

CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
SQLITE_DB="${CLAUDE_BRIDGE_HOME}/claude-bridge.db"

usage() {
  cat <<'EOF'
compaction-report.sh — unified L4 compaction + MOC cache state report

Usage:
  compaction-report.sh [--help]

Environment:
  CLAUDE_BRIDGE_HOME   Where the DB lives (default: ~/.claude)
  CLAUDE_BRIDGE_VAULT  Path to vault (only used to verify proposal file existence)

Output sections:
  1. Staged (pending) proposals
  2. Recently applied proposals (last 12 months)
  3. Orphaned proposals (file missing — need investigation)
  4. MOC cache freshness
EOF
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage; exit 0; }

if [[ ! -f "$SQLITE_DB" ]]; then
  echo "ERROR: DB not found at $SQLITE_DB" >&2
  echo "       Run migrate-l4-cache.sh first, or enable CLAUDE_BRIDGE_COMPACTION_CACHE=sqlite." >&2
  exit 1
fi

q() { sqlite3 "$SQLITE_DB" "$1" 2>/dev/null; }

hr() { printf '%0.s─' {1..70}; echo; }

# ============================================================
echo ""
echo "┌──────────────────────────────────────────────────────────────────────┐"
echo "│  L4 Compaction + MOC Cache Report                                   │"
echo "│  DB: $SQLITE_DB"
echo "│  $(date '+%Y-%m-%d %H:%M:%S')"
echo "└──────────────────────────────────────────────────────────────────────┘"
echo ""

# ============================================================
# 1. Staged (pending) proposals
# ============================================================
echo "── Staged proposals (awaiting --apply) ─────────────────────────────────"
staged_rows=$(q "SELECT id,quarter,kind,source_entries,proposal_path,created_at FROM compaction_proposals WHERE status='staged' ORDER BY quarter;")

if [[ -z "$staged_rows" ]]; then
  echo "  (none)"
else
  printf '  %-6s  %-12s  %-22s  %-8s  %-30s  %s\n' "ID" "QUARTER" "KIND" "ENTRIES" "PATH" "STAGED"
  printf '  %-6s  %-12s  %-22s  %-8s  %-30s  %s\n' "------" "------------" "----------------------" "--------" "------------------------------" "-------------------"
  while IFS='|' read -r id quarter kind entries path created_at; do
    [[ -z "$id" ]] && continue
    printf '  %-6s  %-12s  %-22s  %-8s  %-30s  %s\n' \
      "$id" "$quarter" "$kind" "$entries" "${path:0:30}" "$created_at"
  done <<< "$staged_rows"
fi
echo ""

# ============================================================
# 2. Recently applied proposals (last 12 months)
# ============================================================
cutoff=$(date -v -12m '+%Y-%m-%d' 2>/dev/null || date -d '-12 months' '+%Y-%m-%d' 2>/dev/null || echo "1970-01-01")
echo "── Applied proposals (last 12 months, since $cutoff) ───────────────────"
applied_rows=$(q "SELECT id,quarter,kind,source_entries,applied_at,applied_by FROM compaction_proposals WHERE status='applied' AND applied_at>='$cutoff' ORDER BY applied_at DESC;")

if [[ -z "$applied_rows" ]]; then
  echo "  (none in the last 12 months)"
else
  printf '  %-6s  %-12s  %-22s  %-8s  %-20s  %s\n' "ID" "QUARTER" "KIND" "ENTRIES" "APPLIED AT" "BY"
  printf '  %-6s  %-12s  %-22s  %-8s  %-20s  %s\n' "------" "------------" "----------------------" "--------" "--------------------" "----------"
  while IFS='|' read -r id quarter kind entries applied_at applied_by; do
    [[ -z "$id" ]] && continue
    printf '  %-6s  %-12s  %-22s  %-8s  %-20s  %s\n' \
      "$id" "$quarter" "$kind" "$entries" "${applied_at:-—}" "${applied_by:-—}"
  done <<< "$applied_rows"
fi
echo ""

# ============================================================
# 3. Orphaned proposals (need investigation)
# ============================================================
echo "── Orphaned proposals (file missing — investigation needed) ─────────────"
orphan_rows=$(q "SELECT id,quarter,kind,proposal_path,created_at FROM compaction_proposals WHERE status='orphaned' ORDER BY created_at DESC;")

if [[ -z "$orphan_rows" ]]; then
  echo "  (none)"
else
  echo "  WARNING: These proposals were staged but the proposal file disappeared."
  echo "  Likely cause: process killed mid-write. Re-run compaction to regenerate."
  echo ""
  printf '  %-6s  %-12s  %-22s  %-35s  %s\n' "ID" "QUARTER" "KIND" "PATH" "STAGED"
  printf '  %-6s  %-12s  %-22s  %-35s  %s\n' "------" "------------" "----------------------" "-----------------------------------" "-------------------"
  while IFS='|' read -r id quarter kind path created_at; do
    [[ -z "$id" ]] && continue
    printf '  %-6s  %-12s  %-22s  %-35s  %s\n' \
      "$id" "$quarter" "$kind" "${path:0:35}" "$created_at"
  done <<< "$orphan_rows"
fi
echo ""

# ============================================================
# 4. MOC cache freshness
# ============================================================
echo "── MOC cache freshness ──────────────────────────────────────────────────"
total_files=$(q "SELECT COUNT(DISTINCT file_path) FROM moc_file_tags;" 2>/dev/null || echo 0)
total_tags=$(q "SELECT COUNT(DISTINCT tag) FROM moc_file_tags;" 2>/dev/null || echo 0)
total_rows=$(q "SELECT COUNT(*) FROM moc_file_tags;" 2>/dev/null || echo 0)
oldest_scan=$(q "SELECT MIN(last_scanned_at) FROM moc_file_tags;" 2>/dev/null || echo "—")
newest_scan=$(q "SELECT MAX(last_scanned_at) FROM moc_file_tags;" 2>/dev/null || echo "—")
top_tags=$(q "SELECT tag, COUNT(DISTINCT file_path) as n FROM moc_file_tags GROUP BY tag ORDER BY n DESC LIMIT 5;" 2>/dev/null || echo "")

if [[ "${total_rows:-0}" -eq 0 ]]; then
  echo "  Cache is empty. Run migrate-l4-cache.sh or auto-moc-daemon.sh with"
  echo "  CLAUDE_BRIDGE_MOC_CACHE=sqlite to populate."
else
  printf '  %-25s  %s\n' "Distinct files cached:" "$total_files"
  printf '  %-25s  %s\n' "Distinct tags:" "$total_tags"
  printf '  %-25s  %s\n' "Total (file,tag) rows:" "$total_rows"
  printf '  %-25s  %s\n' "Oldest scan:" "${oldest_scan:-—}"
  printf '  %-25s  %s\n' "Newest scan:" "${newest_scan:-—}"
  echo ""
  echo "  Top 5 tags by file count:"
  if [[ -n "$top_tags" ]]; then
    while IFS='|' read -r tag_name n; do
      [[ -z "$tag_name" ]] && continue
      printf '    %-30s  %s files\n' "$tag_name" "$n"
    done <<< "$top_tags"
  fi
fi
echo ""

# ============================================================
# Summary line
# ============================================================
staged_count=$(q "SELECT COUNT(*) FROM compaction_proposals WHERE status='staged';" 2>/dev/null || echo 0)
orphan_count=$(q "SELECT COUNT(*) FROM compaction_proposals WHERE status='orphaned';" 2>/dev/null || echo 0)
echo "── Summary ──────────────────────────────────────────────────────────────"
printf '  staged=%s  orphaned=%s  moc_files=%s  moc_tags=%s\n' \
  "${staged_count:-0}" "${orphan_count:-0}" "${total_files:-0}" "${total_tags:-0}"
if [[ "${staged_count:-0}" -gt 0 ]]; then
  echo ""
  echo "  Action required: review staged proposals above, then run:"
  echo "    compaction-daemon.sh --apply"
fi
if [[ "${orphan_count:-0}" -gt 0 ]]; then
  echo ""
  echo "  Orphaned proposals detected. Investigate or re-run compaction."
fi
echo ""
exit 0
