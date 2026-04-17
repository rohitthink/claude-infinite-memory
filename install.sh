#!/bin/bash
# install.sh  Bootstrap claude-infinite-memory into a user's machine.
#
# This script is idempotent: safe to re-run. It:
#   1. Prompts for CLAUDE_BRIDGE_VAULT (required) and other settings
#   2. Writes $CLAUDE_BRIDGE_HOME/claude-infinite-memory.env (sourced by all scripts)
#   3. Copies hooks, scripts, skills, and MCP server into $CLAUDE_BRIDGE_HOME
#   4. Applies macOS-specific exclusions (Spotlight, Time Machine)
#   5. Initializes the optional SQLite staging DB
#   6. Runs a smoke test on the SessionStart hook
#   7. Offers to bootstrap LaunchAgents (reconciliation, indexer, compaction, auto-MOC, truenas)
#   8. Prints a summary with next steps
#
# Usage:
#   ./install.sh          # interactive
#   UNATTENDED=1 \\
#     CLAUDE_BRIDGE_VAULT=/path/to/vault \\
#     CLAUDE_BRIDGE_LABEL_PREFIX=com.github.yourhandle \\
#     ./install.sh        # non-interactive

set -uo pipefail

# ---- Colors (stripped on non-tty) ----
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_BOLD=$'\033[1m'
else
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""
fi

info() { echo "${C_BOLD}==>${C_RESET} $*"; }
ok()   { echo "${C_GREEN}OK${C_RESET}  $*"; }
warn() { echo "${C_YELLOW}WARN${C_RESET}  $*" >&2; }
fail() { echo "${C_RED}FAIL${C_RESET}  $*" >&2; exit 1; }

prompt() {
  # $1: prompt text, $2: default, $3: var name
  local label="$1"
  local default="$2"
  local varname="$3"
  if [[ -n "${UNATTENDED:-}" ]]; then
    # In unattended mode, expect the var to already be set in env; fall back to default.
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

# ---- Preflight ----
info "claude-infinite-memory installer"
echo "Platform: $(uname -s) $(uname -r)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  warn "This installer is tuned for macOS. Proceeding anyway  LaunchAgent bootstrap will be skipped."
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
info "Source: $REPO_DIR"

# ---- Gather config ----
CLAUDE_BRIDGE_HOME_DEFAULT="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
prompt "Claude Code home directory" "$CLAUDE_BRIDGE_HOME_DEFAULT" CLAUDE_BRIDGE_HOME
CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME/#\~/$HOME}"

prompt "Path to your Obsidian vault (REQUIRED)" "${CLAUDE_BRIDGE_VAULT:-}" CLAUDE_BRIDGE_VAULT
CLAUDE_BRIDGE_VAULT="${CLAUDE_BRIDGE_VAULT/#\~/$HOME}"

if [[ -z "$CLAUDE_BRIDGE_VAULT" ]]; then
  fail "CLAUDE_BRIDGE_VAULT is required"
fi
if [[ ! -d "$CLAUDE_BRIDGE_VAULT" ]]; then
  warn "Vault path doesn't exist yet: $CLAUDE_BRIDGE_VAULT"
  if ask_yn "Create it now?" N; then
    mkdir -p "$CLAUDE_BRIDGE_VAULT"
    ok "created $CLAUDE_BRIDGE_VAULT"
    if ask_yn "Copy the vault template into it?" Y; then
      cp -R "$REPO_DIR/vault-template/"* "$CLAUDE_BRIDGE_VAULT/"
      # Also copy hidden files (.gitkeep) if any
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

# ---- Create target directories ----
info "Creating directory structure under $CLAUDE_BRIDGE_HOME"
mkdir -p "$CLAUDE_BRIDGE_HOME"/{hooks,scripts,skills,mcp-servers/obsidian-brain,sqlite-backend,daemons/{reconciliation,compaction,truenas-sync},logs,sync-spool,sync-active,sync-state,projects}

# ---- Write config file ----
CONFIG_FILE="$CLAUDE_BRIDGE_HOME/claude-infinite-memory.env"
info "Writing $CONFIG_FILE"
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
info "Installing hooks"
for f in "$REPO_DIR"/hooks/*.sh; do
  cp "$f" "$CLAUDE_BRIDGE_HOME/hooks/"
  chmod +x "$CLAUDE_BRIDGE_HOME/hooks/$(basename "$f")"
done
ok "hooks: $(ls "$CLAUDE_BRIDGE_HOME/hooks" | wc -l | tr -d ' ') files"

# ---- Copy skill ----
info "Installing obsidian-sync skill"
mkdir -p "$CLAUDE_BRIDGE_HOME/skills/obsidian-sync"
cp "$REPO_DIR/skills/obsidian-sync/SKILL.md" "$CLAUDE_BRIDGE_HOME/skills/obsidian-sync/"
ok "skill installed"

# ---- Copy scripts ----
info "Installing utility scripts"
for f in "$REPO_DIR"/scripts/*.sh; do
  cp "$f" "$CLAUDE_BRIDGE_HOME/scripts/"
  chmod +x "$CLAUDE_BRIDGE_HOME/scripts/$(basename "$f")"
done
ok "scripts: $(ls "$CLAUDE_BRIDGE_HOME/scripts" | wc -l | tr -d ' ') files"

# ---- Copy daemons ----
info "Installing daemons"
for sub in reconciliation compaction truenas-sync; do
  mkdir -p "$CLAUDE_BRIDGE_HOME/daemons/$sub"
  for f in "$REPO_DIR"/daemons/"$sub"/*.sh; do
    [[ -f "$f" ]] || continue
    cp "$f" "$CLAUDE_BRIDGE_HOME/daemons/$sub/"
    chmod +x "$CLAUDE_BRIDGE_HOME/daemons/$sub/$(basename "$f")"
  done
done
ok "daemons copied"

# ---- Copy topic map if not already present ----
if [[ ! -f "$CLAUDE_BRIDGE_HOME/vault-topic-map.yaml" ]]; then
  info "Installing topic map"
  cp "$REPO_DIR/config/vault-topic-map.example.yaml" "$CLAUDE_BRIDGE_HOME/vault-topic-map.yaml"
  ok "topic map copied to $CLAUDE_BRIDGE_HOME/vault-topic-map.yaml (edit to match your projects)"
else
  warn "topic map already exists at $CLAUDE_BRIDGE_HOME/vault-topic-map.yaml  keeping your version"
fi

# ---- Copy MCP server ----
if [[ -n "$CLAUDE_BRIDGE_PYTHON" ]]; then
  info "Installing MCP server (L3)"
  for f in "$REPO_DIR"/mcp-servers/obsidian-brain/*; do
    [[ -f "$f" ]] || continue
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
if bash -n "$CLAUDE_BRIDGE_HOME/hooks/session-start-vault-context.sh"; then
  ok "session-start hook passes syntax check"
else
  warn "session-start hook syntax check failed"
fi
if bash -n "$CLAUDE_BRIDGE_HOME/hooks/session-end-vault-sync.sh"; then
  ok "session-end hook passes syntax check"
else
  warn "session-end hook syntax check failed"
fi

# Invoke SessionStart with a mock payload to verify JSON output shape
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
if [[ "$(uname -s)" == "Darwin" ]] && ask_yn "Bootstrap macOS LaunchAgents now?" Y; then
  info "Bootstrapping LaunchAgents"
  LA_DIR="$HOME/Library/LaunchAgents"
  mkdir -p "$LA_DIR"

  # Function: substitute placeholders in a plist template + load it
  install_plist() {
    local template="$1"
    local out_label="$2"
    local out_path="$LA_DIR/${out_label}.plist"

    sed \
      -e "s|{{LABEL_PREFIX}}|${CLAUDE_BRIDGE_LABEL_PREFIX}|g" \
      -e "s|{{CLAUDE_BRIDGE_HOME}}|${CLAUDE_BRIDGE_HOME}|g" \
      -e "s|{{CLAUDE_BRIDGE_VAULT}}|${CLAUDE_BRIDGE_VAULT}|g" \
      -e "s|{{CLAUDE_BIN}}|${CLAUDE_BRIDGE_CLAUDE_BIN}|g" \
      -e "s|{{TRUENAS_HOST}}|${CLAUDE_BRIDGE_TRUENAS_HOST}|g" \
      -e "s|{{TRUENAS_PATH}}|${CLAUDE_BRIDGE_TRUENAS_PATH:-}|g" \
      -e "s|{{DAEMON_PATH}}|$3|g" \
      "$template" > "$out_path"

    # Validate with plutil
    if /usr/bin/plutil -lint "$out_path" >/dev/null 2>&1; then
      ok "plist valid: $out_path"
    else
      warn "plist lint failed: $out_path"
      return 1
    fi

    # Unload any stale instance, then bootstrap
    launchctl bootout gui/$(id -u)/"${out_label}" 2>/dev/null || true
    if launchctl bootstrap gui/$(id -u) "$out_path" 2>/dev/null; then
      ok "bootstrapped: ${out_label}"
    else
      warn "bootstrap failed for ${out_label} (may need Full Disk Access for Terminal)"
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
    # MCP indexer plist is structurally similar; generate it inline.
    cat > "$LA_DIR/${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-brain-indexer.plist" <<EOF
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
EOF
    if /usr/bin/plutil -lint "$LA_DIR/${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-brain-indexer.plist" >/dev/null 2>&1; then
      launchctl bootout gui/$(id -u)/"${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-brain-indexer" 2>/dev/null || true
      launchctl bootstrap gui/$(id -u) "$LA_DIR/${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-brain-indexer.plist" 2>/dev/null && \
        ok "bootstrapped: ${CLAUDE_BRIDGE_LABEL_PREFIX}.obsidian-brain-indexer" || \
        warn "indexer bootstrap failed"
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
fi

# ---- Summary ----
echo
info "${C_BOLD}Installation complete${C_RESET}"
cat <<EOF

Next steps:

  1. Add hook entries to ~/.claude/settings.json (see docs/installation.md step 4)
  2. Restart Claude Code so the hooks register.
  3. If using L3 semantic search:
       a. Install Ollama + pull nomic-embed-text:
            ollama pull nomic-embed-text
       b. Install MCP SDK:
            $CLAUDE_BRIDGE_PYTHON -m pip install --break-system-packages mcp
       c. Build initial index:
            $CLAUDE_BRIDGE_PYTHON $CLAUDE_BRIDGE_HOME/mcp-servers/obsidian-brain/indexer.py --full-rebuild
       d. Add MCP server snippet to settings.json (see mcp-servers/obsidian-brain/README.md)
  4. Edit $CLAUDE_BRIDGE_HOME/vault-topic-map.yaml to match your projects.
  5. Source the env in your shell (optional):
       echo "source $CONFIG_FILE" >> ~/.zshrc

Logs live at:       $CLAUDE_BRIDGE_HOME/logs/
Config file:        $CONFIG_FILE
Vault path:         $CLAUDE_BRIDGE_VAULT

Docs:
  - README.md                    pitch + quickstart
  - docs/architecture.md         how it all fits
  - docs/installation.md         deeper install guide
  - docs/threat-model.md         security posture
  - docs/faq.md                  common questions

EOF
