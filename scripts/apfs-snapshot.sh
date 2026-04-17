#!/bin/bash
# apfs-snapshot.sh — APFS clone-backed vault snapshot
#
# Creates a near-instantaneous copy of your Obsidian vault using macOS
# clonefile(2) via `cp -cR`. On APFS, this consumes near-zero additional
# disk until individual files diverge from the original.
#
# Usage:
#   apfs-snapshot.sh [--vault <path>] [--dest <path>] [--keep N] [--dry-run]
#
# Options:
#   --vault <path>   Vault source (default: $CLAUDE_BRIDGE_VAULT)
#   --dest <path>    Snapshot destination dir (default: ~/.claude-bridge-backups/vault-snapshots/<ts>/)
#   --keep N         Keep only N newest snapshots, prune older (default: 10)
#   --dry-run        Print what would happen, make no changes
#
# macOS-only: requires APFS on both source and destination volumes.
# On non-APFS or cross-volume paths, warns but still runs (cp -c falls back
# to a full copy — functionally correct but not instantaneous).

set -uo pipefail

# ---- Defaults ----
VAULT="${CLAUDE_BRIDGE_VAULT:-}"
SNAP_BASE="$HOME/.claude-bridge-backups/vault-snapshots"
TS="$(date '+%Y%m%d-%H%M%S')"
DEST=""
KEEP=10
DRY_RUN=0

# ---- Parse flags ----
while (( $# > 0 )); do
  case "$1" in
    --vault)   VAULT="$2"; shift ;;
    --dest)    DEST="$2"; shift ;;
    --keep)    KEEP="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

[[ -z "$DEST" ]] && DEST="$SNAP_BASE/$TS"

# ---- Helpers ----
info()  { echo "==> $*"; }
ok()    { echo "OK  $*"; }
warn()  { echo "WARN $*" >&2; }
fail()  { echo "FAIL $*" >&2; exit 1; }
dry()   { echo "[dry-run] $*"; }

# ---- Validate vault ----
if [[ -z "$VAULT" ]]; then
  fail "No vault specified. Set CLAUDE_BRIDGE_VAULT or pass --vault <path>."
fi
if [[ ! -d "$VAULT" ]]; then
  fail "Vault path does not exist or is not a directory: $VAULT"
fi

VAULT="${VAULT%/}"

# ---- macOS-only check ----
if [[ "$(uname -s)" != "Darwin" ]]; then
  warn "apfs-snapshot.sh is macOS-only. clonefile(2) is not available on $(uname -s)."
  exit 1
fi

# ---- APFS check on source volume ----
is_apfs() {
  local path="$1"
  local dev
  # Walk up to the nearest existing parent if path doesn't exist yet
  local check="$path"
  while [[ ! -e "$check" ]]; do
    check="$(dirname "$check")"
    [[ "$check" == "/" ]] && break
  done
  dev=$(df -P "$check" 2>/dev/null | awk 'NR==2 {print $1}')
  [[ -z "$dev" ]] && return 1
  diskutil info "$dev" 2>/dev/null | grep -qi 'Type.*APFS\|File System.*APFS'
}

SOURCE_IS_APFS=0
DEST_IS_APFS=0

if is_apfs "$VAULT"; then
  SOURCE_IS_APFS=1
fi

# Check destination parent (the snapshot dir doesn't exist yet)
mkdir -p "$SNAP_BASE" 2>/dev/null || true
if is_apfs "$SNAP_BASE"; then
  DEST_IS_APFS=1
fi

if (( SOURCE_IS_APFS == 0 )); then
  warn "Source vault ($VAULT) is NOT on an APFS volume. cp -c will fall back to a full copy."
fi
if (( DEST_IS_APFS == 0 )); then
  warn "Destination ($SNAP_BASE) is NOT on an APFS volume. cp -c will fall back to a full copy."
fi

# ---- Same-volume check (APFS clonefile only works within the same volume) ----
if (( SOURCE_IS_APFS == 1 && DEST_IS_APFS == 1 )); then
  SRC_DEV=$(stat -f %d "$VAULT" 2>/dev/null || echo "?")
  DST_DEV=$(stat -f %d "$SNAP_BASE" 2>/dev/null || echo "?")
  if [[ "$SRC_DEV" != "$DST_DEV" || "$SRC_DEV" == "?" ]]; then
    warn "Source and destination are on different volumes (src_dev=$SRC_DEV dst_dev=$DST_DEV)."
    warn "cp -c will perform a full copy instead of a clone. Consider placing snapshots on the same volume."
  else
    ok "Source and destination are on the same APFS volume (dev=$SRC_DEV) — clonefile(2) active"
  fi
fi

# ---- Reject if snapshot dir already exists ----
if [[ -e "$DEST" ]]; then
  fail "Destination already exists: $DEST (timestamp collision? pick a different --dest)"
fi

# ---- Dry-run output ----
if (( DRY_RUN == 1 )); then
  dry "Would create snapshot:"
  dry "  source: $VAULT"
  dry "  dest:   $DEST"
  dry "  clone:  $(( SOURCE_IS_APFS && DEST_IS_APFS )) (1=yes, via clonefile(2); 0=full copy)"
  dry "  keep:   $KEEP snapshots (would prune older ones in $SNAP_BASE)"
  SOURCE_SIZE=$(du -sh "$VAULT" 2>/dev/null | cut -f1)
  dry "  apparent source size: ${SOURCE_SIZE:-unknown}"
  dry "Existing snapshots in $SNAP_BASE:"
  ls -1t "$SNAP_BASE" 2>/dev/null | nl -ba || dry "  (none)"
  exit 0
fi

# ---- Source size (for user confidence printout) ----
SOURCE_SIZE=$(du -sh "$VAULT" 2>/dev/null | cut -f1 || echo "unknown")

info "Creating APFS snapshot"
info "  source: $VAULT ($SOURCE_SIZE apparent)"
info "  dest:   $DEST"

mkdir -p "$(dirname "$DEST")"

START=$(date +%s)
cp -cR "$VAULT" "$DEST"
END=$(date +%s)
ELAPSED=$(( END - START ))

ok "Snapshot created in ${ELAPSED}s"

# On-disk size after clone: should be near-zero on same APFS volume
CLONE_DISK=$(du -sh "$DEST" 2>/dev/null | cut -f1 || echo "unknown")
info "  on-disk usage of snapshot: $CLONE_DISK (vs $SOURCE_SIZE apparent — APFS clones share data blocks until diverged)"

# ---- Prune old snapshots ----
if [[ -d "$SNAP_BASE" ]]; then
  SNAP_COUNT=$(ls -1 "$SNAP_BASE" 2>/dev/null | wc -l | tr -d ' ')
  if (( SNAP_COUNT > KEEP )); then
    PRUNE_COUNT=$(( SNAP_COUNT - KEEP ))
    info "Pruning $PRUNE_COUNT oldest snapshot(s) (keeping $KEEP)"
    ls -1t "$SNAP_BASE" | tail -n "$PRUNE_COUNT" | while IFS= read -r old; do
      info "  removing: $SNAP_BASE/$old"
      rm -rf "$SNAP_BASE/$old"
    done
  else
    info "Snapshot count: $SNAP_COUNT of $KEEP max — no pruning needed"
  fi
fi

ok "Done. Snapshot at: $DEST"
