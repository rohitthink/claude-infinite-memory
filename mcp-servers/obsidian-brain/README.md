# obsidian-brain MCP server

Local MCP server that gives Claude Code semantic search over your Obsidian
vault. L3 of the 4-layer "learning brain" architecture.

## What it does

Exposes four MCP tools over stdio:

| Tool | What it returns |
|---|---|
| `search_vault(query, limit=5)` | Top-N chunks (file path, nearest heading, excerpt, cosine similarity) matching a natural-language query. |
| `get_file(path)` | A single vault-relative markdown file. `realpath`-validated against the vault root; refuses paths outside the vault and anything inside `05 - Personal/`. |
| `list_topics()` | Distinct tags collected from frontmatter `tags:` lists and inline `#tags`. |
| `recent_entries(category, limit=10)` | Last N `##`-level entries in a canonical category file (`session_log`, `technical_learnings`, `skills_tools`, `automation_stack`, `workflow_patterns`, `sync_log`, `user_profile`). |

All returned content is passed through a 17-pattern regex redactor that
mirrors `hooks/session-end-vault-sync.sh`. If the vault is ever
compromised, this server will not be a usable secret-exfil channel.

## Architecture

```
Your Obsidian Vault
        |
        |  (walk + chunk at heading boundaries, ~500 words/chunk)
        v
indexer.py ---> Ollama nomic-embed-text (768-dim, CLAUDE_BRIDGE_OLLAMA_HOST)
        |       (falls back to a deterministic hash pseudo-embedder if
        |        Ollama is unreachable, so the pipeline never blocks)
        v
index.db (SQLite, WAL) --------------> server.py (MCP stdio)
        ^                                    |
        |                                    v
launchd: indexer-daemon               Claude Code
         (every 5 min)
```

The index DB is **local and disposable**. It is not in the vault, not in
any cloud sync, not in backups. Rebuild at any time with
`python3 indexer.py --full-rebuild`.

## Files

- `server.py`  MCP server, stdio transport.
- `indexer.py`  standalone indexer, idempotent + incremental.
- `schema.sql`  SQLite DDL (files, chunks, tags).
- `indexer-daemon.sh`  launchd wrapper: vault-mount check, mkdir lock,
  fast-path skip if no `.md` newer than the DB.
- `test-server.sh`  end-to-end smoke test (indexer + tool-level + MCP stdio).
- `settings-snippet.example.json`  snippet to merge into Claude Code's
  `settings.json` to register this MCP server.

## Install

### 1. Install the mcp SDK

The MCP SDK requires Python >= 3.10. On macOS the system `/usr/bin/python3`
is 3.9, so you'll typically need Homebrew's `/opt/homebrew/bin/python3`:

```bash
/opt/homebrew/bin/python3 -m pip install --break-system-packages mcp
```

Or use a venv:

```bash
/opt/homebrew/bin/python3 -m venv ~/.claude/mcp-servers/obsidian-brain/.venv
source ~/.claude/mcp-servers/obsidian-brain/.venv/bin/activate
pip install mcp
# Then update settings.json below to point at the venv python.
```

### 2. Make sure Ollama has the embedding model

```bash
ollama pull nomic-embed-text
```

The indexer auto-detects Ollama at `$CLAUDE_BRIDGE_OLLAMA_HOST` first, then
`http://localhost:11434`. Override by setting `CLAUDE_BRIDGE_OLLAMA_HOST` in
the environment. If Ollama is unreachable, the indexer falls back to a
hash-based pseudo-embedder and logs a warning  the pipeline will not block.

### 3. Build the initial index

```bash
export CLAUDE_BRIDGE_VAULT="$HOME/Documents/Obsidian/MyVault"
/opt/homebrew/bin/python3 "$CLAUDE_BRIDGE_HOME/mcp-servers/obsidian-brain/indexer.py" --full-rebuild
```

### 4. Register the server with Claude Code

This repo does **not** automatically modify `~/.claude/settings.json`. Copy
`settings-snippet.example.json`, adjust paths, and merge into your
`settings.json` by hand:

```json
{
  "mcpServers": {
    "obsidian-brain": {
      "command": "/opt/homebrew/bin/python3",
      "args": [
        "/Users/YOUR_USER/.claude/mcp-servers/obsidian-brain/server.py"
      ],
      "env": {
        "CLAUDE_BRIDGE_HOME": "/Users/YOUR_USER/.claude",
        "CLAUDE_BRIDGE_VAULT": "/Users/YOUR_USER/Documents/Obsidian/MyVault",
        "CLAUDE_BRIDGE_OLLAMA_HOST": "http://localhost:11434"
      }
    }
  }
}
```

Restart Claude Code after editing settings.json. The tools
`search_vault`, `get_file`, `list_topics`, `recent_entries` will appear
under the `obsidian-brain` server.

### 5. Bootstrap the background indexer

The launchd plist lives on the boot drive (external-volume plists fail
`launchctl bootstrap` with Error 5  see docs/macos-specific.md):

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<LABEL_PREFIX>.obsidian-brain-indexer.plist
```

Verify:

```bash
launchctl print gui/$(id -u)/<LABEL_PREFIX>.obsidian-brain-indexer | head -10
```

The daemon runs every 5 minutes. Most ticks are no-ops: the wrapper
checks whether any `.md` file is newer than `index.db` with `find -newer`
and exits fast if not.

## Operate

Logs:

- `~/.claude/logs/obsidian-brain-indexer.log`  indexer + daemon activity.
- `~/.claude/logs/obsidian-brain-server.log`  MCP server activity.

Force a full rebuild:

```bash
/opt/homebrew/bin/python3 ~/.claude/mcp-servers/obsidian-brain/indexer.py --full-rebuild
```

Run the test suite:

```bash
CLAUDE_BRIDGE_VAULT=~/Documents/Obsidian/MyVault \
  ~/.claude/mcp-servers/obsidian-brain/test-server.sh
```

Inspect the index:

```bash
sqlite3 ~/.claude/mcp-servers/obsidian-brain/index.db \
  "SELECT file_path, chunk_count FROM files ORDER BY chunk_count DESC LIMIT 10"
```

## Security model

1. **Path containment.** `get_file` resolves the argument to an absolute path
   via `Path.resolve()` and then calls `.relative_to(VAULT_ROOT)`  any
   escape (`..`, symlinks, absolute paths) returns None and is rejected.
2. **Blocked folders.** `05 - Personal/` is never indexed and is also
   rejected at read time, even if a rogue symlink pointed there.
3. **Shell-injection filter.** `search_vault` rejects queries containing
   backticks, `$(...)`, obvious `rm -rf`, or `;;`/`&&`/`||` chains. The
   server never shells out on a query, but logging + rejection is easier
   to reason about than "it happens to be safe."
4. **Redaction on response.** Every string the server returns passes
   through the same 17-category regex redactor as the session-sync hook.
5. **Query-only DB.** The server opens the SQLite index with
   `PRAGMA query_only=ON`. It has no write path to the index.
6. **Disposable cache.** The index DB is local-only, outside the vault,
   not synced. A compromise of the backup graph doesn't leak index data.

## Known quirks

- First run after `ollama pull nomic-embed-text` may be slower as the model
  loads into memory; subsequent runs are much faster.
- `recent_entries` is naive  it returns the last N `##` headings in the
  file. Canonical category files are append-only, so tail = newest, but a
  cross-link "Related" block at the bottom can be the "newest" entry.
  Caller is responsible for filtering.
- The hash-fallback embedder produces a 256-dim vector; the Ollama embedder
  produces 768. Mixing them within one DB will make search fail because the
  dim check drops mismatched chunks. If you rebuild under a different
  backend, pass `--full-rebuild` so the whole index moves together.
