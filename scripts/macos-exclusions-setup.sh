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
#   macos-exclusions-setup.sh --exclude-vault # also excludes the Obsidian vault
#                                             # WARNING: disables Finder search
#                                             # for the entire vault; Obsidian's
#                                             # own search still works fine.
#   CLAUDE_BRIDGE_HOME=... macos-exclusions-setup.sh

set -uo pipefail

CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
CLAUDE_BRIDGE_VAULT="${CLAUDE_BRIDGE_VAULT:-}"

# ---- Parse flags ----
EXCLUDE_VAULT=0
for arg in "${@:-}"; do
  case "$arg" in
    --exclude-vault) EXCLUDE_VAULT=1 ;;
    --help|-h)
      sed -n '2,25p' "$0" | sed 's/^# //'
      exit 0
      ;;
  esac
done

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

# ---- Spotlight: optional vault exclusion ----
if [[ $EXCLUDE_VAULT == 1 ]]; then
  if [[ -z "$CLAUDE_BRIDGE_VAULT" ]]; then
    echo "  WARNING: --exclude-vault requested but CLAUDE_BRIDGE_VAULT is not set; skipping vault exclusion." >&2
  elif [[ ! -d "$CLAUDE_BRIDGE_VAULT" ]]; then
    echo "  WARNING: vault path does not exist: $CLAUDE_BRIDGE_VAULT; skipping vault exclusion." >&2
  else
    echo ""
    echo "  WARNING: --exclude-vault will disable Spotlight/Finder search for your entire vault."
    echo "           Obsidian's built-in search (Cmd+O / Cmd+Shift+F) is NOT affected."
    echo "           This is irreversible via this script alone; to re-enable Finder search,"
    echo "           remove the flag file or run: sudo mdutil -i on \"$CLAUDE_BRIDGE_VAULT\""
    echo ""
    VAULT_FLAG="$CLAUDE_BRIDGE_VAULT/.metadata_never_index"
    if [[ ! -f "$VAULT_FLAG" ]]; then
      touch "$VAULT_FLAG"
      echo "  created: $VAULT_FLAG (Finder/Spotlight will skip your vault)"
    else
      echo "  exists:  $VAULT_FLAG"
    fi
  fi
fi

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

# ---- Sanity: current Spotlight indexing status ----
echo ""
echo "── Spotlight status ─────────────────────────────────────────────────────"
if command -v mdutil >/dev/null 2>&1; then
  echo "  CLAUDE_BRIDGE_HOME ($CLAUDE_BRIDGE_HOME):"
  mdutil -s "$CLAUDE_BRIDGE_HOME" 2>/dev/null | sed 's/^/    /' || echo "    (mdutil unavailable or permission denied)"

  if [[ -n "$CLAUDE_BRIDGE_VAULT" && -d "$CLAUDE_BRIDGE_VAULT" ]]; then
    echo ""
    echo "  Vault ($CLAUDE_BRIDGE_VAULT):"
    mdutil -s "$CLAUDE_BRIDGE_VAULT" 2>/dev/null | sed 's/^/    /' || echo "    (mdutil unavailable or permission denied)"
    echo ""
    echo "  Tip: if you want to fully disable Spotlight on the vault (not just exclude it):"
    echo "    sudo mdutil -i off \"$CLAUDE_BRIDGE_VAULT\""
    echo "  To re-enable Spotlight on the vault:"
    echo "    sudo mdutil -i on \"$CLAUDE_BRIDGE_VAULT\""
  fi
else
  echo "  mdutil not found (unexpected on macOS)"
fi
echo "─────────────────────────────────────────────────────────────────────────"
