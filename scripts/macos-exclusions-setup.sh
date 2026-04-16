#!/bin/bash
# macos-exclusions-setup.sh
#
# Applies macOS-specific exclusions to the Claude Code home directory and any
# local state directories the bridge writes to:
#
#   1. Spotlight: creates a `.metadata_never_index` flag file so mdworker
#      doesn't index every JSONL transcript Claude Code writes. Without this,
#      a busy Claude Code session can spike CPU and slow Finder search.
#   2. Time Machine: runs `tmutil addexclusion` against the log/spool dirs so
#      they aren't backed up every hour. Keep CLAUDE_BRIDGE_HOME's projects
#      dir (transcripts) in backups if you want session history preserved;
#      this script only excludes ephemeral state.
#
# Idempotent: re-runs are cheap no-ops.
#
# Usage:
#   macos-exclusions-setup.sh                 # applies to $CLAUDE_BRIDGE_HOME
#   CLAUDE_BRIDGE_HOME=... macos-exclusions-setup.sh

set -uo pipefail

CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is macOS-specific. Skipping on non-Darwin."
  exit 0
fi

if [[ ! -d "$CLAUDE_BRIDGE_HOME" ]]; then
  echo "ERROR: CLAUDE_BRIDGE_HOME ($CLAUDE_BRIDGE_HOME) not found" >&2
  exit 1
fi

echo "Applying macOS exclusions to $CLAUDE_BRIDGE_HOME"

# ---- Spotlight: .metadata_never_index ----
# Placing this empty file in a directory tells Spotlight not to index ANY
# contents under that tree. Claude Code writes high-frequency transcript
# JSONLs which spin up mdworker without benefit.
SPOTLIGHT_FLAG="$CLAUDE_BRIDGE_HOME/.metadata_never_index"
if [[ ! -f "$SPOTLIGHT_FLAG" ]]; then
  touch "$SPOTLIGHT_FLAG"
  echo "  created: $SPOTLIGHT_FLAG (Spotlight will skip this tree)"
else
  echo "  exists:  $SPOTLIGHT_FLAG"
fi

# Also put one in the sync-spool (ephemeral prompt/wrapper files) and logs
# dirs even if they're inside the parent, so tools that check the direct
# parent see it.
for subdir in sync-spool sync-active logs sync-state; do
  full="$CLAUDE_BRIDGE_HOME/$subdir"
  mkdir -p "$full"
  flag="$full/.metadata_never_index"
  if [[ ! -f "$flag" ]]; then
    touch "$flag"
    echo "  created: $flag"
  fi
done

# ---- Time Machine: tmutil addexclusion ----
# `tmutil addexclusion -p` marks the path so backups skip it. The -p flag
# attaches the exclusion to the path itself (sticky, survives path moves).
# Must run as the user who owns the path (no sudo needed for user dirs).
if command -v tmutil >/dev/null 2>&1; then
  for subdir in logs sync-spool sync-active sync-state; do
    full="$CLAUDE_BRIDGE_HOME/$subdir"
    [[ -d "$full" ]] || continue
    # tmutil prints noisy status; suppress unless it fails.
    if tmutil addexclusion -p "$full" >/dev/null 2>&1; then
      echo "  tmutil excluded: $full"
    else
      # Non-fatal: this can fail if Full Disk Access isn't granted to Terminal.
      echo "  tmutil exclusion failed (often means Terminal lacks Full Disk Access): $full"
    fi
  done
else
  echo "  tmutil not on PATH, skipping Time Machine exclusions"
fi

echo "Done."
echo ""
echo "Notes:"
echo "  - Spotlight exclusion takes effect immediately; Time Machine honors it on next backup."
echo "  - If tmutil exclusion failed, grant Terminal.app Full Disk Access in"
echo "    System Settings > Privacy & Security > Full Disk Access, then re-run this script."
