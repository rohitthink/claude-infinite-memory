#!/bin/bash
# install.sh  Bootstrap claude-infinite-memory into a user's machine.
#
# This script is idempotent: safe to re-run. It:
#   1. Pre-flight safety checks (existing install, Claude CLI, path safety, admin warn)
#   2. Prompts for CLAUDE_BRIDGE_VAULT (required) and other settings
#   3. Backs up any existing config/hooks before overwriting
#   4. Writes $CLAUDE_BRIDGE_HOME/claude-infinite-memory.env (sourced by all scripts)
#   5. Copies hooks, scripts, skills, and MCP server into $CLAUDE_BRIDGE_HOME
#   6. Applies macOS-specific exclusions (Spotlight, Time Machine)
#   7. Initializes the optional SQLite staging DB
#   8. Runs a smoke test on the SessionStart hook
#   9. Installs LaunchAgent plists (NOT bootstrapped by default; use --bootstrap to opt-in)
#  10. Prints a summary with next steps
#
# Usage:
#   ./install.sh                  # interactive
#   ./install.sh --bootstrap      # also run launchctl bootstrap after plist install
#   ./install.sh --yes            # suppress admin/root confirmation prompt
#   UNATTENDED=1 \
#     CLAUDE_BRIDGE_VAULT=/path/to/vault \
#     CLAUDE_BRIDGE_LABEL_PREFIX=com.github.yourhandle \
#     ./install.sh                # non-interactive

set -uo pipefail

# ---- Parse flags ----
FLAG_BOOTSTRAP=0
FLAG_YES=0
for arg in "${@:-}"; do
  case "$arg" in
    --bootstrap) FLAG_BOOTSTRAP=1 ;;
    --yes)       FLAG_YES=1 ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# //'
      exit 0
      ;;
  esac
done

# ---- Colors (stripped on non-tty) ----
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

info()  { echo "${C_BOLD}==>${C_RESET} $*"; }
ok()    { echo "${C_GREEN}OK${C_RESET}  $*"; }
warn()  { echo "${C_YELLOW}WARN${C_RESET}  $*" >&2; }
fail()  { echo "${C_RED}FAIL${C_RESET}  $*" >&2; exit 1; }
step()  { echo "${C_CYAN}----${C_RESET} $*"; }

prompt() {
  # $1: prompt text, $2: default, $3: var name
  local label="$1"
  local default="$2"
  local varname="$3"
  if [[ -n "${UNATTENDED:-}" ]]; then
    local existing="${!varname:-}"
    eval "$varname=\${existing:-\$default}"
    echo "  (unattended) $varname=${!varname}"
    return
  fi
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$label" "$default"
  else
    printf '%s: ' "$label"
  fi
  local answer
  IFS= read -r answer
  if [[ -z "$answer" ]]; then
    eval "$varname=\$default"
  else
    eval "$varname=\$answer"
  fi
}

ask_yn() {
  local label="$1"
  local default="${2:-N}"
  if [[ -n "${UNATTENDED:-}" ]]; then
    echo "  (unattended) $label  $default"
    [[ "$default" == "Y" || "$default" == "y" ]]
    return
  fi
  printf '%s [y/N]: ' "$label"
  local answer
  IFS= read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# Prompt user: overwrite / skip / abort. Returns 0=overwrite, 1=skip, 2=abort.
ask_overwrite() {
  local label="$1"
  if [[ -n "${UNATTENDED:-}" ]]; then
    echo "  (unattended) $label  overwrite"
    return 0
  fi
  printf '%s  [overwrite/skip/abort]: ' "$label"
  local answer
  IFS= read -r answer
  case "${answer,,}" in
    overwrite|o) return 0 ;;
    skip|s)      return 1 ;;
    abort|a|*)   return 2 ;;
  esac
}

# ---- Unsafe path guard ----
# Rejects paths containing newlines, literal quotes, or control characters.
assert_safe_path() {
  local name="$1"
  local value="$2"
  # newline or carriage-return
  if printf '%s' "$value" | grep -qP '[\n\r]'; then
    fail "$name contains newline/carriage-return characters — unsafe path rejected."
  fi
  # single or double quotes
  if printf '%s' "$value" | grep -q "['\"]"; then
    fail "$name contains quote characters — unsafe path rejected."
  fi
  # ASCII control characters (0x00-0x1F except 0x0A/0x0D already caught above)
  if printf '%s' "$value" | LC_ALL=C grep -qP '[\x00-\x08\x0B\x0C\x0E-\x1F]'; then
    fail "$name contains control characters — unsafe path rejected."
  fi
}

# ---- Banner ----
echo
info "claude-infinite-memory installer"
echo "Platform: $(uname -s) $(uname -r)"
echo

if [[ "$(uname -s)" != "Darwin" ]]; then
  warn "This installer is tuned for macOS. Proceeding anyway — LaunchAgent bootstrap will be skipped."
fi

# ---- Admin / root check ----
step "Checking privileges"
_is_admin=0
if [[ "${EUID:-$(id -u)}" == "0" ]]; then
  _is_admin=1
elif id -Gn 2>/dev/null | grep -qw admin; then
  _is_admin=1
fi
if [[ $_is_admin == 1 ]]; then
  warn "You are running as an administrator (admin group or root)."
  warn "Admin processes inherit broader Full Disk Access on macOS."
  warn "Recommendation: run this installer as a dedicated non-admin user."
  if [[ $FLAG_YES == 0 ]]; then
    printf 'Continue anyway? Pass --yes to suppress this prompt. [y/N]: '
    _adm_ans=""
    IFS= read -r _adm_ans
    if [[ "${_adm_ans,,}" != "y" ]]; then
      fail "Aborted. Re-run as a non-admin user, or pass --yes to override."
    fi
  else
    warn "--yes flag set; proceeding despite admin privileges."
  fi
fi
ok "privilege check done"

# ---- Claude CLI check ----
step "Checking for Claude CLI"
if ! command -v claude >/dev/null 2>&1; then
  fail "Claude CLI not found in PATH. Install it first:
    brew install anthropic/claude/claude
  or download from https://claude.ai/download
  Then re-run this installer."
fi
ok "claude CLI found: $(command -v claude)"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
info "Source: $REPO_DIR"

# ---- Gather config ----
echo
info "Configuration"
CLAUDE_BRIDGE_HOME_DEFAULT="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
prompt "Claude Code home directory" "$CLAUDE_BRIDGE_HOME_DEFAULT" CLAUDE_BRIDGE_HOME
CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME/#\~/$HOME}"

prompt "Path to your Obsidian vault (REQUIRED)" "${CLAUDE_BRIDGE_VAULT:-}" CLAUDE_BRIDGE_VAULT
CLAUDE_BRIDGE_VAULT="${CLAUDE_BRIDGE_VAULT/#\~/$HOME}"

# ---- Vault path validation ----
step "Validating paths"
if [[ -z "$CLAUDE_BRIDGE_VAULT" ]]; then
  fail "CLAUDE_BRIDGE_VAULT is required"
fi

assert_safe_path "CLAUDE_BRIDGE_HOME" "$CLAUDE_BRIDGE_HOME"
assert_safe_path "CLAUDE_BRIDGE_VAULT" "$CLAUDE_BRIDGE_VAULT"

if [[ ! -d "$CLAUDE_BRIDGE_VAULT" ]]; then
  warn "Vault path doesn't exist yet: $CLAUDE_BRIDGE_VAULT"
  if ask_yn "Create it now?" N; then
    mkdir -p "$CLAUDE_BRIDGE_VAULT"
    ok "created $CLAUDE_BRIDGE_VAULT"
    if ask_yn "Copy the vault template into it?" Y; then
      cp -R "$REPO_DIR/vault-template/"* "$CLAUDE_BRIDGE_VAULT/"
      find "$REPO_DIR/vault-template/" -name '.gitkeep' | while read -r kp; do
        rel="${kp#$REPO_DIR/vault-template/}"
        mkdir -p "$(dirname "$CLAUDE_BRIDGE_VAULT/$rel")"
      done
      ok "vault template copied"
    fi
  else
    fail "cannot proceed without a vault directory"
  fi
fi
ok "vault path valid: $CLAUDE_BRIDGE_VAULT"

prompt "LaunchAgent label prefix (reverse-DNS)" "${CLAUDE_BRIDGE_LABEL_PREFIX:-com.example}" CLAUDE_BRIDGE_LABEL_PREFIX
prompt "Path to claude CLI binary" "${CLAUDE_BRIDGE_CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo /opt/homebrew/bin/claude)}" CLAUDE_BRIDGE_CLAUDE_BIN
prompt "Path to Python 3.10+ (for MCP server; empty to skip L3)" "${CLAUDE_BRIDGE_PYTHON:-/opt/homebrew/bin/python3}" CLAUDE_BRIDGE_PYTHON

# TrueNAS / remote backup (optional)
echo
info "Remote backup daemon (optional)"
prompt "SSH host for remote vault backup (empty to skip)" "${CLAUDE_BRIDGE_TRUENAS_HOST:-}" CLAUDE_BRIDGE_TRUENAS_HOST
if [[ -n "$CLAUDE_BRIDGE_TRUENAS_HOST" ]]; then
  prompt "Remote path on that host" "${CLAUDE_BRIDGE_TRUENAS_PATH:-}" CLAUDE_BRIDGE_TRUENAS_PATH
fi

# ---- Already-installed check ----
echo
step "Checking for existing installation"
HOOK_MARKER="$CLAUDE_BRIDGE_HOME/hooks/session-start-vault-context.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"
_already_installed=0

if [[ -f "$HOOK_MARKER" ]]; then
  _already_installed=1
fi
if [[ -f "$SETTINGS_FILE" ]] && \
   command -v python3 >/dev/null 2>&1 && \
   python3 -c "import json,sys; d=json.load(open('$SETTINGS_FILE')); sys.exit(0 if 'obsidian-brain' in d.get('mcpServers',{}) else 1)" 2>/dev/null; then
  _already_installed=1
fi

OVERWRITE_DECISION="overwrite"
if [[ $_already_installed == 1 ]]; then
  warn "Existing claude-infinite-memory installation detected."
  echo
  echo "  Existing hook: $HOOK_MARKER"
  echo "  Existing settings: $SETTINGS_FILE"
  echo
  if [[ -f "$HOOK_MARKER" && -f "$REPO_DIR/hooks/session-start-vault-context.sh" ]]; then
    echo "${C_BOLD}Diff (existing vs. new session-start hook):${C_RESET}"
    diff --color=always "$HOOK_MARKER" "$REPO_DIR/hooks/session-start-vault-context.sh" || true
    echo
  fi
  ask_overwrite "Existing install found. How to proceed?" || {
    rc=$?
    if [[ $rc == 1 ]]; then
      warn "Skipping file installation (settings merge will still run)."
      OVERWRITE_DECISION="skip"
    else
      fail "Aborted by user."
    fi
  }
  if [[ $? == 0 ]]; then
    OVERWRITE_DECISION="overwrite"
  fi
fi
ok "install check done (decision: $OVERWRITE_DECISION)"

# ---- Backup helper ----
BACKUP_DIR="$HOME/.claude-bridge-backups/$(date +%Y%m%d-%H%M%S)"
_backed_up=()

backup_file() {
  local src="$1"
  if [[ -f "$src" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp -v "$src" "$BACKUP_DIR/" 2>&1 | sed 's/^/  /' || true
    _backed_up+=("$src")
  fi
}

# ---- Create target directories ----
echo
info "Creating directory structure under $CLAUDE_BRIDGE_HOME"
mkdir -p "$CLAUDE_BRIDGE_HOME"/{hooks,scripts,skills,mcp-servers/obsidian-brain,sqlite-backend,daemons/{reconciliation,compaction,truenas-sync},logs,sync-spool,sync-active,sync-state,projects}

# ---- Write config file ----
CONFIG_FILE="$CLAUDE_BRIDGE_HOME/claude-infinite-memory.env"
info "Writing $CONFIG_FILE"
backup_file "$CONFIG_FILE"
cat > "$CONFIG_FILE" <<EOF
#!/bin/bash
# Auto-generated by install.sh on $(date)
export CLAUDE_BRIDGE_HOME="$CLAUDE_BRIDGE_HOME"
export CLAUDE_BRIDGE_VAULT="$CLAUDE_BRIDGE_VAULT"
export CLAUDE_BRIDGE_CLAUDE_BIN="$CLAUDE_BRIDGE_CLAUDE_BIN"
export CLAUDE_BRIDGE_PYTHON="$CLAUDE_BRIDGE_PYTHON"
export CLAUDE_BRIDGE_OLLAMA_HOST="${CLAUDE_BRIDGE_OLLAMA_HOST:-http://localhost:11434}"
export CLAUDE_BRIDGE_TRUENAS_HOST="$CLAUDE_BRIDGE_TRUENAS_HOST"
export CLAUDE_BRIDGE_TRUENAS_PATH="${CLAUDE_BRIDGE_TRUENAS_PATH:-}"
export CLAUDE_BRIDGE_LABEL_PREFIX="$CLAUDE_BRIDGE_LABEL_PREFIX"
EOF
chmod 600 "$CONFIG_FILE"
ok "config written"

# ---- Copy hooks ----
if [[ "$OVERWRITE_DECISION" == "overwrite" ]]; then
  info "Installing hooks"
  for f in "$REPO_DIR"/hooks/*.sh; do
    dest="$CLAUDE_BRIDGE_HOME/hooks/$(basename "$f")"
    backup_file "$dest"
    cp "$f" "$dest"
    chmod +x "$dest"
  done
  ok "hooks: $(ls "$CLAUDE_BRIDGE_HOME/hooks" | wc -l | tr -d ' ') files"
else
  warn "Skipping hook install (skip mode)"
fi

# ---- Copy skill ----
if [[ "$OVERWRITE_DECISION" == "overwrite" ]]; then
  info "Installing obsidian-sync skill"
  mkdir -p "$CLAUDE_BRIDGE_HOME/skills/obsidian-sync"
  backup_file "$CLAUDE_BRIDGE_HOME/skills/obsidian-sync/SKILL.md"
  cp "$REPO_DIR/skills/obsidian-sync/SKILL.md" "$CLAUDE_BRIDGE_HOME/skills/obsidian-sync/"
  ok "skill installed"
fi

# ---- Copy scripts ----
if [[ "$OVERWRITE_DECISION" == "overwrite" ]]; then
  info "Installing utility scripts"
  for f in "$REPO_DIR"/scripts/*.sh; do
    dest="$CLAUDE_BRIDGE_HOME/scripts/$(basename "$f")"
    backup_file "$dest"
    cp "$f" "$dest"
    chmod +x "$dest"
  done
  ok "scripts: $(ls "$CLAUDE_BRIDGE_HOME/scripts" | wc -l | tr -d ' ') files"
fi

# ---- Copy daemons ----
if [[ "$OVERWRITE_DECISION" == "overwrite" ]]; then
  info "Installing daemons"
  for sub in reconciliation compaction truenas-sync; do
    mkdir -p "$CLAUDE_BRIDGE_HOME/daemons/$sub"
    for f in "$REPO_DIR"/daemons/"$sub"/*.sh; do
      [[ -f "$f" ]] || continue
      dest="$CLAUDE_BRIDGE_HOME/daemons/$sub/$(basename "$f")"
      backup_file "$dest"
      cp "$f" "$dest"
      chmod +x "$dest"
    done
  done
  ok "daemons copied"
fi

# ---- Copy topic map if not already present ----
if [[ ! -f "$CLAUDE_BRIDGE_HOME/vault-topic-map.yaml" ]]; then
  info "Installing topic map"
  cp "$REPO_DIR/config/vault-topic-map.example.yaml" "$CLAUDE_BRIDGE_HOME/vault-topic-map.yaml"
  ok "topic map copied to $CLAUDE_BRIDGE_HOME/vault-topic-map.yaml (edit to match your projects)"
else
  warn "topic map already exists at $CLAUDE_BRIDGE_HOME/vault-topic-map.yaml  keeping your version"
fi

# ---- Copy MCP server ----
if [[ -n "$CLAUDE_BRIDGE_PYTHON" && "$OVERWRITE_DECISION" == "overwrite" ]]; then
  info "Installing MCP server (L3)"
  for f in "$REPO_DIR"/mcp-servers/obsidian-brain/*; do
    [[ -f "$f" ]] || continue
    backup_file "$CLAUDE_BRIDGE_HOME/mcp-servers/obsidian-brain/$(basename "$f")"
    cp "$f" "$CLAUDE_BRIDGE_HOME/mcp-servers/obsidian-brain/"
  done
  chmod +x "$CLAUDE_BRIDGE_HOME/mcp-servers/obsidian-brain/indexer-daemon.sh"
  chmod +x "$CLAUDE_BRIDGE_HOME/mcp-servers/obsidian-brain/test-server.sh"
  ok "MCP server installed"
fi

# ---- Copy SQLite backend ----
info "Installing SQLite staging backend (optional, not wired in by default)"
for f in "$REPO_DIR"/sqlite-backend/*; do
  [[ -f "$f" ]] || continue
  backup_file "$CLAUDE_BRIDGE_HOME/sqlite-backend/$(basename "$f")"
  cp "$f" "$CLAUDE_BRIDGE_HOME/sqlite-backend/"
done
chmod +x "$CLAUDE_BRIDGE_HOME/sqlite-backend/"*.sh
ok "sqlite-backend files in place"

# ---- macOS exclusions ----
if [[ "$(uname -s)" == "Darwin" ]]; then
  info "Applying macOS exclusions"
  CLAUDE_BRIDGE_HOME="$CLAUDE_BRIDGE_HOME" bash "$CLAUDE_BRIDGE_HOME/scripts/macos-exclusions-setup.sh" || warn "exclusions had issues (see above)"
fi

# ---- Initialize SQLite backend DB ----
if [[ -x /usr/bin/sqlite3 ]]; then
  info "Initializing SQLite staging DB (empty)"
  /usr/bin/sqlite3 "$CLAUDE_BRIDGE_HOME/sqlite-backend/vault-staging.db" \
    < "$CLAUDE_BRIDGE_HOME/sqlite-backend/schema.sql" 2>/dev/null || \
    warn "SQLite init failed (not critical; backend is optional)"
fi

# ---- Smoke test ----
info "Running SessionStart hook smoke test"
if bash -n "$CLAUDE_BRIDGE_HOME/hooks/session-start-vault-context.sh" 2>/dev/null; then
  ok "session-start hook passes syntax check"
else
  warn "session-start hook syntax check failed"
fi
if bash -n "$CLAUDE_BRIDGE_HOME/hooks/session-end-vault-sync.sh" 2>/dev/null; then
  ok "session-end hook passes syntax check"
else
  warn "session-end hook syntax check failed"
fi

SMOKE_OUT=$(CLAUDE_BRIDGE_HOME="$CLAUDE_BRIDGE_HOME" \
            CLAUDE_BRIDGE_VAULT="$CLAUDE_BRIDGE_VAULT" \
            echo '{"source":"startup","cwd":"/tmp"}' | \
            "$CLAUDE_BRIDGE_HOME/hooks/session-start-vault-context.sh" 2>&1)
if echo "$SMOKE_OUT" | /usr/bin/jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
  ok "session-start hook returns valid JSON with additionalContext"
else
  warn "session-start hook smoke test: no valid JSON output (may be OK if vault has no files yet)"
  warn "  output head: $(echo "$SMOKE_OUT" | head -c 200)"
fi

# ---- fswatch version check ----
if [[ -n "$CLAUDE_BRIDGE_TRUENAS_HOST" ]]; then
  _fswatch_bin="${FSWATCH_BIN:-/opt/homebrew/bin/fswatch}"
  if [[ ! -x "$_fswatch_bin" ]]; then
    _fswatch_bin="$(command -v fswatch 2>/dev/null || echo "")"
  fi
  if [[ -n "$_fswatch_bin" && -x "$_fswatch_bin" ]]; then
    _fswatch_ver=$("$_fswatch_bin" --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    _fswatch_major="${_fswatch_ver%%.*}"
    _fswatch_rest="${_fswatch_ver#*.}"
    _fswatch_minor="${_fswatch_rest%%.*}"
    if [[ -n "$_fswatch_major" && -n "$_fswatch_minor" ]] && \
       (( _fswatch_major < 1 || ( _fswatch_major == 1 && _fswatch_minor < 17 ) )); then
      warn "fswatch ${_fswatch_ver} is older than 1.17 — upgrade for better macOS directory-reparenting behavior"
      warn "  Run: brew upgrade fswatch"
    else
      ok "fswatch version: ${_fswatch_ver:-unknown}"
    fi
  else
    warn "fswatch not found — required for --watch mode (brew install fswatch)"
  fi
fi

# ---- LaunchAgents ----
if [[ "$(uname -s)" == "Darwin" ]]; then
  echo
  info "Installing LaunchAgent plists"
  LA_DIR="$HOME/Library/LaunchAgents"
  mkdir -p "$LA_DIR"

  install_plist() {
    local template="$1"
    local out_label="$2"
    local out_path="$LA_DIR/${out_label}.plist"
    local daemon_path="${3:-}"

    backup_file "$out_path"

    sed \
      -e "s|{{LABEL_PREFIX}}|${CLAUDE_BRIDGE_LABEL_PREFIX}|g" \
      -e "s|{{CLAUDE_BRIDGE_HOME}}|${CLAUDE_BRIDGE_HOME}|g" \
      -e "s|{{CLAUDE_BRIDGE_VAULT}}|${CLAUDE_BRIDGE_VAULT}|g" \
      -e "s|{{CLAUDE_BIN}}|${CLAUDE_BRIDGE_CLAUDE_BIN}|g" \
      -e "s|{{TRUENAS_HOST}}|${CLAUDE_BRIDGE_TRUENAS_HOST}|g" \
      -e "s|{{TRUENAS_PATH}}|${CLAUDE_BRIDGE_TRUENAS_PATH:-}|g" \
      -e "s|{{DAEMON_PATH}}|${daemon_path}|g" \
      "$template" > "$out_path"

    if /usr/bin/plutil -lint "$out_path" >/dev/null 2>&1; then
      ok "plist valid: $out_path"
    else
      warn "plist lint failed: $out_path"
      return 1
    fi

    if [[ $FLAG_BOOTSTRAP == 1 ]]; then
      launchctl bootout "gui/$(id -u)/${out_label}" 2>/dev/null || true
      if launchctl bootstrap "gui/$(id -u)" "$out_path" 2>/dev/null; then
        ok "bootstrapped: ${out_label}"
      else
        warn "bootstrap failed for ${out_label} (may need Full Disk Access for Terminal)"
      fi
    fi
  }

  install_plist \
    "$REPO_DIR/daemons/reconciliation/com.example.obsidian-reconciliation.plist.template" \
    "${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-reconciliation" \
    "$CLAUDE_BRIDGE_HOME/daemons/reconciliation/obsidian-reconciliation-daemon.sh"

  install_plist \
    "$REPO_DIR/daemons/compaction/com.example.vault-compaction.plist.template" \
    "${CLAUDE_BRIDGE_LABEL_PREFIX}.vault-compaction" \
    "$CLAUDE_BRIDGE_HOME/daemons/compaction/compaction-daemon.sh"

  install_plist \
    "$REPO_DIR/daemons/compaction/com.example.vault-auto-moc.plist.template" \
    "${CLAUDE_BRIDGE_LABEL_PREFIX}.vault-auto-moc" \
    "$CLAUDE_BRIDGE_HOME/daemons/compaction/auto-moc-daemon.sh"

  if [[ -n "$CLAUDE_BRIDGE_PYTHON" ]]; then
    _indexer_plist="$LA_DIR/${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-brain-indexer.plist"
    backup_file "$_indexer_plist"
    cat > "$_indexer_plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-brain-indexer</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CLAUDE_BRIDGE_HOME}/mcp-servers/obsidian-brain/indexer-daemon.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${CLAUDE_BRIDGE_HOME}/logs/obsidian-brain-indexer-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${CLAUDE_BRIDGE_HOME}/logs/obsidian-brain-indexer-stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>CLAUDE_BRIDGE_HOME</key>
        <string>${CLAUDE_BRIDGE_HOME}</string>
        <key>CLAUDE_BRIDGE_VAULT</key>
        <string>${CLAUDE_BRIDGE_VAULT}</string>
        <key>CLAUDE_BRIDGE_PYTHON</key>
        <string>${CLAUDE_BRIDGE_PYTHON}</string>
        <key>CLAUDE_BRIDGE_OLLAMA_HOST</key>
        <string>${CLAUDE_BRIDGE_OLLAMA_HOST:-http://localhost:11434}</string>
    </dict>
    <key>ThrottleInterval</key>
    <integer>60</integer>
</dict>
</plist>
PLISTEOF
    if /usr/bin/plutil -lint "$_indexer_plist" >/dev/null 2>&1; then
      ok "plist valid: $_indexer_plist"
      if [[ $FLAG_BOOTSTRAP == 1 ]]; then
        launchctl bootout "gui/$(id -u)/${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-brain-indexer" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$_indexer_plist" 2>/dev/null && \
          ok "bootstrapped: ${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-brain-indexer" || \
          warn "indexer bootstrap failed"
      fi
    fi
  fi

  if [[ -n "$CLAUDE_BRIDGE_TRUENAS_HOST" ]]; then
    install_plist \
      "$REPO_DIR/daemons/truenas-sync/com.example.obsidian-truenas-sync.plist.template" \
      "${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-truenas-sync" \
      "$CLAUDE_BRIDGE_HOME/daemons/truenas-sync/obsidian-truenas-sync.sh"

    # Also install the watchdog that alerts when backups go stale.
    # install_plist uses $3 as {{DAEMON_PATH}}; reuse that slot for {{WATCHDOG_PATH}}.
    sed \
      -e "s|{{LABEL_PREFIX}}|${CLAUDE_BRIDGE_LABEL_PREFIX}|g" \
      -e "s|{{CLAUDE_BRIDGE_HOME}}|${CLAUDE_BRIDGE_HOME}|g" \
      -e "s|{{CLAUDE_BRIDGE_VAULT}}|${CLAUDE_BRIDGE_VAULT}|g" \
      -e "s|{{WATCHDOG_PATH}}|$CLAUDE_BRIDGE_HOME/scripts/truenas-sync-watchdog.sh|g" \
      "$REPO_DIR/daemons/truenas-sync/com.example.truenas-sync-watchdog.plist.template" \
      > "$LA_DIR/${CLAUDE_BRIDGE_LABEL_PREFIX}.truenas-sync-watchdog.plist"
    if /usr/bin/plutil -lint "$LA_DIR/${CLAUDE_BRIDGE_LABEL_PREFIX}.truenas-sync-watchdog.plist" >/dev/null 2>&1; then
      ok "plist valid: ${CLAUDE_BRIDGE_LABEL_PREFIX}.truenas-sync-watchdog.plist"
      launchctl bootout gui/$(id -u)/"${CLAUDE_BRIDGE_LABEL_PREFIX}.truenas-sync-watchdog" 2>/dev/null || true
      launchctl bootstrap gui/$(id -u) "$LA_DIR/${CLAUDE_BRIDGE_LABEL_PREFIX}.truenas-sync-watchdog.plist" 2>/dev/null && \
        ok "bootstrapped: ${CLAUDE_BRIDGE_LABEL_PREFIX}.truenas-sync-watchdog" || \
        warn "watchdog bootstrap failed (may need Full Disk Access for Terminal)"
    else
      warn "plist lint failed: ${CLAUDE_BRIDGE_LABEL_PREFIX}.truenas-sync-watchdog.plist"
    fi
  fi

  if [[ $FLAG_BOOTSTRAP == 0 ]]; then
    echo
    info "LaunchAgents installed to $LA_DIR (NOT bootstrapped)"
    echo "  To enable daemons, run the following commands:"
    echo
    for _plist in \
        "${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-reconciliation" \
        "${CLAUDE_BRIDGE_LABEL_PREFIX}.vault-compaction" \
        "${CLAUDE_BRIDGE_LABEL_PREFIX}.vault-auto-moc" \
        "${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-brain-indexer"; do
      _f="$LA_DIR/${_plist}.plist"
      [[ -f "$_f" ]] && echo "    launchctl bootstrap gui/\$UID $_f"
    done
    if [[ -n "$CLAUDE_BRIDGE_TRUENAS_HOST" ]]; then
      _f="$LA_DIR/${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-truenas-sync.plist"
      [[ -f "$_f" ]] && echo "    launchctl bootstrap gui/\$UID $_f"
    fi
    echo
    echo "  Or re-run the installer with --bootstrap to have it done automatically."
  fi
fi

# ---- Merge settings.json ----
echo
info "Merging ~/.claude/settings.json"
_settings="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
backup_file "$_settings"

if [[ ! -f "$_settings" ]]; then
  echo '{}' > "$_settings"
fi

# Use python3 to merge hook entries safely without clobbering unrelated keys.
if command -v python3 >/dev/null 2>&1; then
python3 - "$_settings" "$CLAUDE_BRIDGE_HOME" <<'PYEOF'
import json, sys, os

settings_path = sys.argv[1]
bridge_home   = sys.argv[2]

with open(settings_path) as f:
    cfg = json.load(f)

hooks = cfg.setdefault("hooks", {})

def ensure_hook(event, cmd):
    entries = hooks.setdefault(event, [])
    for e in entries:
        if isinstance(e, dict) and e.get("command") == cmd:
            return  # already present
    entries.append({"command": cmd})

ensure_hook("SessionStart", f"{bridge_home}/hooks/session-start-vault-context.sh")
ensure_hook("SessionEnd",   f"{bridge_home}/hooks/session-end-vault-sync.sh")

with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print(f"  hooks merged into {settings_path}")
PYEOF
  ok "settings.json updated"
else
  warn "python3 not found; please manually add hook entries to ~/.claude/settings.json (see docs/installation.md step 4)"
fi

# ---- Print backup summary ----
if [[ ${#_backed_up[@]} -gt 0 ]]; then
  echo
  info "Backups created at: $BACKUP_DIR"
  for f in "${_backed_up[@]}"; do
    echo "  $f"
  done
  echo "  To restore: cp $BACKUP_DIR/<file> <original-path>"
  echo "  To discard: rm -rf $BACKUP_DIR"
fi

# ---- Summary ----
echo
printf '%0.s═' {1..60}; echo " installed"
echo
printf "  %-16s %s\n" "Hooks:"        "$CLAUDE_BRIDGE_HOME/hooks/{session-start,session-end}-vault-*.sh"
printf "  %-16s %s\n" "MCP server:"   "$CLAUDE_BRIDGE_HOME/mcp-servers/obsidian-brain/"
printf "  %-16s %s\n" "Skills:"       "$CLAUDE_BRIDGE_HOME/skills/obsidian-sync/"
printf "  %-16s %s\n" "LaunchAgents:" "installed to ~/Library/LaunchAgents/ ($([ $FLAG_BOOTSTRAP -eq 1 ] && echo 'bootstrapped' || echo 'NOT bootstrapped — opt-in'))"
printf "  %-16s %s\n" "Settings:"     "merged into ~/.claude/settings.json"
if [[ ${#_backed_up[@]} -gt 0 ]]; then
  printf "  %-16s %s\n" "Backup:" "$BACKUP_DIR"
fi
echo
echo "Next steps:"
echo "  1. Restart Claude Code so the hooks register."
if [[ $FLAG_BOOTSTRAP == 0 && "$(uname -s)" == "Darwin" ]]; then
  echo "  2. Bootstrap LaunchAgents (see instructions above, or re-run with --bootstrap)"
fi
echo "  3. Subscribe to Obsidian Sync if multi-device needed."
echo "  4. Run Python indexer: python3 $CLAUDE_BRIDGE_HOME/mcp-servers/obsidian-brain/indexer.py"
echo
echo "To uninstall: $REPO_DIR/uninstall.sh --dry-run"
echo
