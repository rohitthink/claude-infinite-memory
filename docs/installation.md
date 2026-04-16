# Installation

Step-by-step install for a new machine. macOS is the primary target.

## Prerequisites

1. **Claude Code CLI v2.1.53+**. Install via Homebrew: `brew install anthropic/claude/claude` (or via the Anthropic download). Verify: `claude --version`.
2. **Obsidian** with a vault. Any layout works, but the hooks assume the
   folder structure shown in `vault-template/`  copy the template into an
   empty vault to get the canonical layout.
3. **jq**, **perl**, and **sqlite3**. All three ship with macOS.
4. **Python 3.10+** with the `mcp` SDK (only needed if you want L3
   semantic search). On macOS: `brew install python3` then
   `/opt/homebrew/bin/python3 -m pip install --break-system-packages mcp`.
5. **Ollama** (only for L3): `brew install ollama` then
   `ollama pull nomic-embed-text`. Optional  L3 falls back to a hash
   pseudo-embedder if Ollama is unreachable.
6. **fswatch** (only for the remote backup daemon): `brew install fswatch`.

## 1. Clone the repo

```bash
git clone https://github.com/rohitthink/claude-infinite-memory.git
cd claude-infinite-memory
```

## 2. Configure

Copy the config template and edit it with your paths:

```bash
cp config.template.sh ~/.claude/claude-infinite-memory.env
$EDITOR ~/.claude/claude-infinite-memory.env
```

At minimum, set:

- `CLAUDE_BRIDGE_VAULT`  absolute path to your Obsidian vault
- `CLAUDE_BRIDGE_LABEL_PREFIX`  a reverse-DNS prefix for your LaunchAgents
  (e.g. `com.github.yourhandle`)

Source it so the rest of this session uses the values:

```bash
source ~/.claude/claude-infinite-memory.env
```

## 3. Run the installer

```bash
./install.sh
```

The script will:
- Validate your vault path exists
- Copy hooks, scripts, skills, and the MCP server into `$CLAUDE_BRIDGE_HOME`
- Apply macOS exclusions (Spotlight, Time Machine)
- Initialize the SQLite backend (optional; empty DB)
- Run a smoke test of the SessionStart hook
- Ask whether to bootstrap LaunchAgents (reconciliation, indexer,
  compaction, auto-MOC, and optionally the remote backup daemon)
- Print a summary

You can safely re-run `install.sh`; it's idempotent.

## 4. Wire up Claude Code settings

### Hooks

Add these entries to `~/.claude/settings.json` (merge into the existing
`hooks` block):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "command": "/Users/YOUR_USER/.claude/hooks/session-start-vault-context.sh"
      }
    ],
    "SessionEnd": [
      {
        "command": "/Users/YOUR_USER/.claude/hooks/session-end-vault-sync.sh"
      }
    ]
  }
}
```

### MCP server (optional, for L3)

Merge the snippet from `mcp-servers/obsidian-brain/settings-snippet.example.json`
into `~/.claude/settings.json`.

Restart Claude Code.

## 5. Copy the vault template (if starting fresh)

```bash
cp -R vault-template/* "$CLAUDE_BRIDGE_VAULT/"
```

Skip this step if you already have an Obsidian vault you want to use.

## 6. Build the initial semantic index (optional, for L3)

```bash
/opt/homebrew/bin/python3 "$CLAUDE_BRIDGE_HOME/mcp-servers/obsidian-brain/indexer.py" --full-rebuild
```

Expect a few seconds for a small vault. The launchd daemon keeps it fresh
every 5 minutes thereafter.

## 7. Verify

Run the smoke test:

```bash
bash -n "$CLAUDE_BRIDGE_HOME/hooks/session-start-vault-context.sh"
echo '{}' | "$CLAUDE_BRIDGE_HOME/hooks/session-start-vault-context.sh" | jq .
```

You should see a JSON payload with `hookSpecificOutput.additionalContext`
containing your vault reference context.

Start a new Claude Code session and ask: "What's in the Obsidian Vault
Reference Context I was given?" The model should describe the injected
content.

## 8. Configure multi-device sync (optional)

If you use Claude Code on multiple machines:

- Install the repo on each device.
- Use Obsidian Sync (recommended), Syncthing, or iCloud  see
  `README.md#multi-device-sync` for tradeoffs.
- Per-device Session Logs are automatic (each device writes to
  `Session Log - <hostname>.md`). Run
  `scripts/consolidate-session-logs.sh` weekly to merge them.

## Troubleshooting

- **SessionStart hook exits silently**: run it with `set -x` prepended and
  a mock payload. Common causes: `CLAUDE_BRIDGE_VAULT` not set in the env
  Claude Code sees, or the vault directory is unmounted.
- **SessionEnd hook spawns child that immediately dies**: check
  `$CLAUDE_BRIDGE_HOME/logs/obsidian-sync.log`. Most failures log there.
- **launchd Error 5 on bootstrap**: the plist must live on the boot drive,
  NOT an external volume. See `docs/macos-specific.md`.
- **MCP server can't find the index**: confirm `indexer.py --full-rebuild`
  ran and check `$CLAUDE_BRIDGE_HOME/logs/obsidian-brain-indexer.log`.
