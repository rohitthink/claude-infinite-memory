#!/bin/bash
# apfs-clone-status.sh — APFS clone storage diagnostic
#
# Given a path, prints:
#   - Whether the volume is APFS
#   - Apparent size vs on-disk size (clone savings estimate)
#   - Heuristic: which of the N largest files may share clone ancestors
#     (same size + same inode number = almost certainly same clone)
#
# Usage:
#   apfs-clone-status.sh [<path>]
#   <path>  defaults to $CLAUDE_BRIDGE_VAULT
#
# Used by install.sh post-install and by gdpr-export.sh (W8) to give users
# a clear picture of their storage situation.
#
# macOS-only. On Linux, prints "not APFS" and exits.

set -uo pipefail

TARGET="${1:-${CLAUDE_BRIDGE_VAULT:-}}"

if [[ -z "$TARGET" ]]; then
  echo "Usage: apfs-clone-status.sh <path>" >&2
  echo "  or set CLAUDE_BRIDGE_VAULT" >&2
  exit 1
fi

if [[ ! -d "$TARGET" && ! -f "$TARGET" ]]; then
  echo "FAIL: path does not exist: $TARGET" >&2
  exit 1
fi

TARGET="${TARGET%/}"

# ---- macOS check ----
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Volume: NOT APFS (non-macOS platform: $(uname -s))"
  echo "Clone savings: N/A"
  exit 0
fi

# ---- APFS detection ----
DEV=$(df -P "$TARGET" 2>/dev/null | awk 'NR==2 {print $1}')
IS_APFS=0
FS_TYPE="unknown"

if [[ -n "$DEV" ]]; then
  _di=$(diskutil info "$DEV" 2>/dev/null)
  if echo "$_di" | grep -qi 'File System Personality.*APFS\|Type (Bundle).*apfs'; then
    IS_APFS=1
    FS_TYPE="APFS"
  else
    FS_TYPE=$(echo "$_di" | awk -F: '/File System Personality/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
    [[ -z "$FS_TYPE" ]] && FS_TYPE="non-APFS"
  fi
fi

echo "=== APFS Clone Status: $TARGET ==="
echo ""
echo "Volume:      $DEV"
echo "Filesystem:  $FS_TYPE"
if (( IS_APFS == 0 )); then
  echo "APFS clones: NOT AVAILABLE (filesystem is not APFS)"
  echo ""
  echo "Note: cp -cR clonefile(2) clone snapshots require APFS."
  exit 0
fi

echo "APFS clones: AVAILABLE"
echo ""

# ---- Size analysis ----
# Apparent size: sum of logical file sizes (what du --apparent-size would give)
# On-disk size:  what macOS actually uses (cloned blocks are shared)
# We use `du -sk` for actual disk blocks (512-byte units -> multiply by 512)
# and `find + stat -f %z` for apparent sizes.

echo "--- Size Analysis ---"

APPARENT_BYTES=0
while IFS= read -r size; do
  APPARENT_BYTES=$(( APPARENT_BYTES + size ))
done < <(find "$TARGET" -type f -exec stat -f '%z' {} \; 2>/dev/null)

# du -sk reports 1024-byte blocks on macOS
DISK_KB=$(du -sk "$TARGET" 2>/dev/null | awk '{print $1}')
DISK_BYTES=$(( ${DISK_KB:-0} * 1024 ))

human() {
  local b="$1"
  if (( b >= 1073741824 )); then
    awk "BEGIN {printf \"%.1f GB\", $b/1073741824}"
  elif (( b >= 1048576 )); then
    awk "BEGIN {printf \"%.1f MB\", $b/1048576}"
  elif (( b >= 1024 )); then
    awk "BEGIN {printf \"%.1f KB\", $b/1024}"
  else
    echo "${b} B"
  fi
}

echo "Apparent size: $(human $APPARENT_BYTES)"
echo "On-disk size:  $(human $DISK_BYTES)"

if (( APPARENT_BYTES > 0 && DISK_BYTES < APPARENT_BYTES )); then
  SAVED=$(( APPARENT_BYTES - DISK_BYTES ))
  PCT=$(( 100 * SAVED / APPARENT_BYTES ))
  echo "Clone savings: ~$(human $SAVED) (~${PCT}% of apparent size saved via shared clone blocks)"
elif (( DISK_BYTES >= APPARENT_BYTES && APPARENT_BYTES > 0 )); then
  echo "Clone savings: None detected (on-disk >= apparent; no shared clone blocks, or files have diverged)"
else
  echo "Clone savings: N/A (could not compute)"
fi

echo ""

# ---- Heuristic: files that share clone ancestors ----
# Heuristic: same inode = definitely the same clone (hardlink or identical source).
# Same size AND same inode = almost certainly a clonefile clone that hasn't diverged.
# We look at the top 20 largest files and group by (size, inode).

echo "--- Top Clone Candidates (by inode sharing) ---"
echo "(files sharing inodes are backed by the same clone blocks)"
echo ""

# Collect: size inode path — then group by (size, inode)
TMPFILE=$(mktemp -t apfs-clone-status.XXXXXX)
find "$TARGET" -type f -exec stat -f '%z %i %N' {} \; 2>/dev/null | sort -rn > "$TMPFILE"

# Find (size, inode) pairs that appear more than once
awk '{key=$1" "$2; count[key]++; if(count[key]==1) first[key]=$0} END {
  for(k in count) if(count[k]>1) print count[k], first[k]
}' "$TMPFILE" | sort -rn | head -10 | while read -r cnt size inode path; do
  echo "  inode=$inode size=$(human "$size" 2>/dev/null || echo "${size}B") shared_by=${cnt}_files  $path ..."
done

SHARED_INODES=$(awk '{key=$1" "$2; count[key]++} END {n=0; for(k in count) if(count[k]>1) n++; print n}' "$TMPFILE")
echo ""
echo "Unique (size,inode) pairs with >1 file: $SHARED_INODES"
rm -f "$TMPFILE"

echo ""
echo "--- File Count ---"
TOTAL_FILES=$(find "$TARGET" -type f 2>/dev/null | wc -l | tr -d ' ')
MD_FILES=$(find "$TARGET" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
echo "Total files: $TOTAL_FILES"
echo "Markdown:    $MD_FILES"

echo ""
echo "Tip: run 'scripts/apfs-snapshot.sh --dry-run' to preview a clone-backed snapshot."
