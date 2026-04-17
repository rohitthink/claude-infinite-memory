# Quickstart

A 10-minute walkthrough from a fresh clone to your first session with
memory enabled.

## Prerequisites

- macOS 13+ recommended. Linux is supported for a subset of features;
  see [docs/macos-specific.md](macos-specific.md) for what's macOS-only.
- Claude Code CLI installed (`command -v claude` returns a path).
  Install via: `brew install anthropic/claude/claude`
- An Obsidian vault you don't mind the system writing to. A fresh vault
  works; so does an existing one — the system writes only into
  `07 - Claude Knowledge/` and leaves everything else untouched.
- **Optional for L3 semantic search:** Ollama running locally.
  `brew install ollama && ollama pull nomic-embed-text`
- Python 3.10+ for the MCP server (`/usr/bin/python3` on macOS, or
  `brew install python`).
- `jq` and `sqlite3` (both ship with macOS; `brew install jq` if absent).

## 1. Clone + install

```bash
git clone https://github.com/rohitthink/claude-infinite-memory.git
cd claude-infinite-memory

export CLAUDE_BRIDGE_VAULT="$HOME/Obsidian/MyVault"   # adjust to yours
CLAUDE_BRIDGE_VAULT="$CLAUDE_BRIDGE_VAULT" ./install.sh --yes
```

The installer:
- Backs up any existing hook/MCP config to `~/.claude-bridge-backups/<timestamp>/`
- Writes `~/.claude-bridge/config.sh` from `config.template.sh`
- Installs LaunchAgent plist templates into `~/Library/LaunchAgents/`
- Wires session-start + session-end hooks into `~/.claude/settings.json`

LaunchAgents are installed but **not bootstrapped** — explicit opt-in below.

## 2. Verify the install

```bash
ls ~/.claude/hooks/               # expect session-start + session-end scripts
ls ~/Library/LaunchAgents/        # expect com.example.*.plist files (not loaded)
python3 tests/test-mcp-xml-wrap.py       # spot-check MCP security layer
python3 tests/test-mcp-path-resolution.py
bash   tests/test-compaction-sandbox.sh
```

All five suites should exit 0 on a clean install. Full suite list:
`tests/test-mcp-chunk-cap.py`, `test-mcp-path-resolution.py`,
`test-mcp-xml-wrap.py`, `test-compaction-sandbox.sh`,
`test-topic-map-containment.sh`.

## 3. Enable the daemons (optional but recommended)

```bash
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.example.*.plist
launchctl list | grep example     # confirm they're loaded
```

Daemons installed: compaction, auto-MOC, semantic-search indexer,
truenas-sync (if configured), mds-watchdog (macOS Spotlight guard).

## 4. Start your first session

Open Claude Code in any project directory. The SessionStart hook matches
your cwd against `vault-topic-map.yaml` and injects relevant vault
content. Work normally. On SessionEnd, outcomes are distilled back into
the vault under `07 - Claude Knowledge/`.

After the session, inspect what landed:

```bash
ls "$CLAUDE_BRIDGE_VAULT/07 - Claude Knowledge/"
# Expected files:
#   User Profile.md                  (L2 preferences, pending/promote/decay)
#   Session Log - <hostname>.md      (L3 session-by-session log)
#   Technical Learnings.md           (L3 deduped gotchas)
#   MOCs/<topic>.md                  (L4 auto-synthesised Maps of Content)
#   Historical Summaries/YYYY-Qn.md  (L4 quarterly distillations)
```

## 5. Opt into the SQLite backend (advanced)

Markdown is the default source-of-truth. To opt into the SQLite WAL backend
for atomic multi-writer safety, run the one-time migration for each component
you want to switch:

```bash
# L2 User Profile
./sqlite-backend/migrate-from-markdown.sh

# L3 Session Log + Technical Learnings
./sqlite-backend/migrate-meta-project.sh

# L4 compaction proposals + MOC cache
./sqlite-backend/migrate-l4-cache.sh
```

Then export the runtime flags in `~/.claude-bridge/config.sh` (or your shell
profile):

```bash
export CLAUDE_BRIDGE_PREFS_BACKEND=sqlite          # L2
export CLAUDE_BRIDGE_SESSIONLOG_BACKEND=sqlite     # L3 session log
export CLAUDE_BRIDGE_TECHLEARN_BACKEND=sqlite      # L3 technical learnings
export CLAUDE_BRIDGE_COMPACTION_CACHE=sqlite       # L4 compaction proposals
export CLAUDE_BRIDGE_MOC_CACHE=sqlite              # L4 MOC cache
```

`sqlite-backend/export-to-vault.sh` re-materialises markdown after every
staged write so your Obsidian view stays coherent. See
`sqlite-backend/README.md` for details.

## 6. Tune (optional)

Common knobs (set in `~/.claude-bridge/config.sh`):

| Variable | Default | Effect |
|---|---|---|
| `CLAUDE_BRIDGE_MAX_CHUNKS_HISTORICAL` | 8 | Historical Summaries chunks in search |
| `CLAUDE_BRIDGE_MAX_CHUNKS_MOC` | 6 | MOC chunks in search |
| `CLAUDE_BRIDGE_RSYNC_FLAGS_EXTRA` | (empty) | Extra flags appended to every rsync invocation |
| `CLAUDE_BRIDGE_OLLAMA_HOST` | `http://localhost:11434` | Ollama endpoint for embeddings |

See `config.template.sh` for the full env-var surface.

## 7. Uninstall (reversible)

```bash
./uninstall.sh             # dry-run by default — shows what would go
./uninstall.sh --confirm   # actually remove
```

Your Obsidian vault is left untouched. System-generated files under
`~/.claude-bridge/` are removed. To also purge the vault's
`07 - Claude Knowledge/` content, see `scripts/gdpr-delete.sh` for
tiered erasure.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Install fails: "claude CLI not found" | Install Claude Code first: `brew install anthropic/claude/claude` |
| Hooks don't fire | Check `~/.claude/settings.json` has `hooks.session-start` + `hooks.session-end` entries |
| MCP server not responding | Run `python3 mcp-servers/obsidian-brain/server.py --probe` and check `~/.claude-bridge/logs/obsidian-brain.log` |
| L3 search returns no results | Confirm Ollama is running: `ollama list \| grep nomic-embed-text` |
| Tests fail on Ubuntu | Expected if failure is a macOS-only suite (APFS, Spotlight, launchd). |

For anything else, see [docs/faq.md](faq.md) or open an issue.
