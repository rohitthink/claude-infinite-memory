#!/bin/bash
# uninstall.sh  Remove claude-infinite-memory from this machine.
#
# Removes hooks, MCP server, skills, daemons, LaunchAgents, the env file,
# and the SQLite backend. Does NOT touch the Obsidian vault. Does NOT
# remove ~/.claude/settings.json (see note below about manual steps).
#
# Usage:
#   ./uninstall.sh              # dry-run: list what would be removed
#   ./uninstall.sh --dry-run    # same as above (explicit)
#   ./uninstall.sh --confirm    # actually remove everything

set -uo pipefail

# ---- Parse flags ----
DRY_RUN=1
for arg in "${@:-}"; do
  case "$arg" in
    --confirm)  DRY_RUN=0 ;;
    --dry-run)  DRY_RUN=1 ;;
    --help|-h)
      sed -n '2,15p' "$0" | sed 's/^# //'
      exit 0
      ;;
  esac
done

# ---- Colors ----
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_BOLD=$'\033[1m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; C_CYAN=""
fi

info()   { echo "${C_BOLD}==>${C_RESET} $*"; }
ok()     { echo "${C_GREEN}OK${C_RESET}  $*"; }
warn()   { echo "${C_YELLOW}WARN${C_RESET}  $*" >&2; }
dry()    { echo "${C_CYAN}[dry-run]${C_RESET} would remove: $*"; }
doing()  { echo "${C_RED}removing${C_RESET}: $*"; }

# ---- Load config ----
# Try to source the installed env file to get path variables.
_env_file="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}/claude-infinite-memory.env"
if [[ -f "$_env_file" ]]; then
  # shellcheck source=/dev/null
  source "$_env_file"
else
  warn "Config file not found: $_env_file"
  warn "Falling back to defaults. Set CLAUDE_BRIDGE_HOME / CLAUDE_BRIDGE_LABEL_PREFIX if needed."
fi

CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
CLAUDE_BRIDGE_LABEL_PREFIX="${CLAUDE_BRIDGE_LABEL_PREFIX:-com.example}"
CLAUDE_BRIDGE_VAULT="${CLAUDE_BRIDGE_VAULT:-}"

# ---- Collect items to remove ----
LA_DIR="$HOME/Library/LaunchAgents"

_launchagents=(
  "$LA_DIR/${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-reconciliation.plist"
  "$LA_DIR/${CLAUDE_BRIDGE_LABEL_PREFIX}.vault-compaction.plist"
  "$LA_DIR/${CLAUDE_BRIDGE_LABEL_PREFIX}.vault-auto-moc.plist"
  "$LA_DIR/${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-brain-indexer.plist"
  "$LA_DIR/${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-truenas-sync.plist"
)

_dirs=(
  "$CLAUDE_BRIDGE_HOME/hooks"
  "$CLAUDE_BRIDGE_HOME/mcp-servers/obsidian-brain"
  "$CLAUDE_BRIDGE_HOME/mcp-servers"
  "$CLAUDE_BRIDGE_HOME/skills/obsidian-sync"
  "$CLAUDE_BRIDGE_HOME/skills"
  "$CLAUDE_BRIDGE_HOME/scripts"
  "$CLAUDE_BRIDGE_HOME/daemons/reconciliation"
  "$CLAUDE_BRIDGE_HOME/daemons/compaction"
  "$CLAUDE_BRIDGE_HOME/daemons/truenas-sync"
  "$CLAUDE_BRIDGE_HOME/daemons"
  "$CLAUDE_BRIDGE_HOME/sqlite-backend"
  "$CLAUDE_BRIDGE_HOME/sync-spool"
  "$CLAUDE_BRIDGE_HOME/sync-active"
  "$CLAUDE_BRIDGE_HOME/sync-state"
)

_files=(
  "$_env_file"
  "$CLAUDE_BRIDGE_HOME/vault-topic-map.yaml"
)

# ---- Banner ----
echo
info "claude-infinite-memory uninstaller"
if [[ $DRY_RUN == 1 ]]; then
  echo "  Mode: ${C_CYAN}dry-run${C_RESET} (pass --confirm to actually remove)"
else
  echo "  Mode: ${C_RED}CONFIRM — files will be deleted${C_RESET}"
fi
echo

# ---- LaunchAgents section ----
info "LaunchAgents ($LA_DIR)"
_found_agents=0
for _plist in "${_launchagents[@]}"; do
  if [[ -f "$_plist" ]]; then
    _found_agents=1
    _label="$(basename "$_plist" .plist)"
    if [[ $DRY_RUN == 1 ]]; then
      dry "$_plist  (would also bootout gui/\$UID/$_label)"
    else
      doing "bootout gui/$(id -u)/$_label"
      launchctl bootout "gui/$(id -u)/$_label" 2>/dev/null || true
      doing "$_plist"
      rm -f "$_plist"
      ok "removed $_plist"
    fi
  fi
done
if [[ $_found_agents == 0 ]]; then
  echo "  (no LaunchAgent plists found for prefix: $CLAUDE_BRIDGE_LABEL_PREFIX)"
fi

# ---- Directories section ----
echo
info "Installed directories"
for _dir in "${_dirs[@]}"; do
  if [[ -d "$_dir" ]]; then
    if [[ $DRY_RUN == 1 ]]; then
      dry "$_dir/"
    else
      doing "$_dir/"
      rm -rf "$_dir"
      ok "removed $_dir"
    fi
  fi
done

# ---- Files section ----
echo
info "Config and data files"
for _f in "${_files[@]}"; do
  if [[ -f "$_f" ]]; then
    if [[ $DRY_RUN == 1 ]]; then
      dry "$_f"
    else
      doing "$_f"
      rm -f "$_f"
      ok "removed $_f"
    fi
  fi
done

# ---- Logs (optional) ----
echo
info "Log directory"
if [[ -d "$CLAUDE_BRIDGE_HOME/logs" ]]; then
  if [[ $DRY_RUN == 1 ]]; then
    dry "$CLAUDE_BRIDGE_HOME/logs/ ($(find "$CLAUDE_BRIDGE_HOME/logs" -type f 2>/dev/null | wc -l | tr -d ' ') log files)"
  else
    doing "$CLAUDE_BRIDGE_HOME/logs/"
    rm -rf "$CLAUDE_BRIDGE_HOME/logs"
    ok "removed logs"
  fi
else
  echo "  (logs directory not found)"
fi

# ---- Projects dir (if empty) ----
if [[ -d "$CLAUDE_BRIDGE_HOME/projects" ]]; then
  _proj_count=$(find "$CLAUDE_BRIDGE_HOME/projects" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
  if [[ $_proj_count == 0 ]]; then
    if [[ $DRY_RUN == 1 ]]; then
      dry "$CLAUDE_BRIDGE_HOME/projects/ (empty)"
    else
      rm -rf "$CLAUDE_BRIDGE_HOME/projects"
      ok "removed empty projects dir"
    fi
  else
    warn "Skipping $CLAUDE_BRIDGE_HOME/projects/ — not empty ($_proj_count items). Remove manually if desired."
  fi
fi

# ---- settings.json — manual step ----
echo
info "~/.claude/settings.json — NOT auto-modified"
echo "  This uninstaller does not touch settings.json to avoid corrupting"
echo "  unrelated Claude Code configuration."
echo
echo "  To finish the cleanup, manually remove these entries from"
echo "  ~/.claude/settings.json:"
echo
echo "  1. Under \"hooks.SessionStart\": remove the entry whose \"command\""
echo "     contains \"session-start-vault-context.sh\""
echo "  2. Under \"hooks.SessionEnd\": remove the entry whose \"command\""
echo "     contains \"session-end-vault-sync.sh\""
echo "  3. Under \"mcpServers\": remove the \"obsidian-brain\" key"
echo

# ---- Final message ----
echo
printf '%0.s═' {1..60}; echo
echo
if [[ $DRY_RUN == 1 ]]; then
  echo "Dry-run complete. No files were changed."
  echo "To actually uninstall, run:  $0 --confirm"
else
  ok "Uninstall complete."
fi
echo
if [[ -n "$CLAUDE_BRIDGE_VAULT" ]]; then
  echo "  Obsidian vault at ${C_BOLD}$CLAUDE_BRIDGE_VAULT${C_RESET} — untouched."
fi
echo "  ~/.claude-bridge-backups/ — preserved (remove manually when satisfied)."
echo
