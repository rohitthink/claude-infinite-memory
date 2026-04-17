# claude-infinite-memory

Turn your Obsidian vault into Claude Code's permanent, bidirectional
memory. Cross-session continuity, hardened against prompt injection and
secret leakage, multi-device ready.

## What this is

Claude Code forgets everything between sessions. That's fine for one-off
edits, but painful for long-running work: you re-explain your project
every morning, re-state your preferences every debugging session,
re-describe your architecture every time you touch a new file.

`claude-infinite-memory` fixes that by wiring Claude Code into an
Obsidian vault via a pair of shell hooks, a skill, a semantic-search MCP
server, and a small fleet of background daemons. At the start of every
session, relevant vault content is injected as context. At the end of
every session, outcomes are distilled and written back. Your vault
becomes a living knowledge graph that Claude reads, updates, and
searches  without you babysitting it.

## Why

The problem: **Claude forgets between sessions.** Every new session is
a blank slate. Long-running projects suffer. User preferences vanish.
Hard-won debugging learnings get re-derived.

The solution: **Obsidian as external brain.** Markdown files are easy
for humans to read, easy for Claude to write, easy to sync across
devices, and easy to version. The vault is the persistent layer; Claude
Code sessions are transient workers reading from and writing to it.

## Architecture

```
                    +-------------------------------------+
                    |         Your Obsidian Vault         |
                    +------------------+------------------+
                                       |
              read (XML-wrapped)       |       write (XML-ignored)
                                       |
+--------------+          SessionStart |       SessionEnd         +---------------+
|  L1 topic-   | <--- hook injects ----+---- hook spawns -------> |  obsidian-    |
|  aware inj.  |    vault-topic-map.yaml   `claude -p` child      |  sync skill   |
+--------------+                                                  +-------+-------+
                                                                          |
                                                                          v
                                                           +------------------------------+
                                                           |  L2 User Profile             |
                                                           |  append-only preferences     |
                                                           +------------------------------+

                            +---------- L3 semantic search ----------+
                            |  indexer -> SQLite/WAL -> MCP server    |
                            |  Ollama nomic-embed-text, launchd       |
                            +-----------------------------------------+

                            +---------- L4 compaction ----------+
                            |  monthly: 90-day distillation     |
                            |  weekly:  Maps of Content (MOCs)  |
                            +-----------------------------------+

                 +-------- reconciliation --------+
                 |  orphan transcripts (SIGKILL,  |
                 |  crash, API 500) caught here   |
                 +--------------------------------+
```

See [docs/architecture.md](docs/architecture.md) for the component walkthrough.

## Four learning layers

**L1  Topic-aware retrieval.** At SessionStart, the hook reads your
`cwd` and matches a rule in `vault-topic-map.yaml`. Only the relevant
project/client/infra files get injected, wrapped in XML so the model
treats them as reference material (not directives). Fits in ~9KB.

**L2  User profile accumulation.** At SessionEnd, the detached child
scans the redacted transcript for preference signals  explicit "I
prefer X" statements, repeated corrections, documented anti-patterns 
and appends de-duped entries to `User Profile.md`. The next session's
L1 injection includes this file. You stop re-explaining yourself.

**L3  Semantic search (MCP).** An indexer walks the vault every 5
minutes, chunks files at heading boundaries, embeds via Ollama's
`nomic-embed-text`, stores in a local SQLite index. The MCP server
exposes `search_vault`, `get_file`, `list_topics`, `recent_entries` 
Claude calls them on demand when L1 wasn't enough.

**L4  Compaction + Maps of Content.** Monthly: session log entries
older than 90 days get distilled into a quarterly summary by
`claude -p`. Weekly: topics appearing in 5+ files automatically
generate a `MOCs/<topic>.md` Map of Content with wikilinks and
excerpts. Your vault stays lean; emergent clusters surface
automatically.

## Security model

The vault is a multi-writer directory: the user writes, Claude writes,
sync peers write, plugins write. Hostile writes are a realistic threat
model, not a theoretical one.

- **XML-wrapped untrusted content.** All vault content injected into
  sessions is wrapped in `<untrusted-reference>` with a preamble
  instructing the model to treat it as reference, not directives.
- **17-category regex secret redaction.** GitHub PATs, AWS keys,
  Anthropic/OpenAI/Google keys, JWTs, SSH private keys, Slack, GitLab,
  generic `password=...` / `api_key: ...`. Applied before any LLM sees
  the transcript. Also applied to MCP tool responses so query can't
  leak.
- **Realpath-validated transcript paths.** Hook rejects anything
  outside `$CLAUDE_BRIDGE_HOME/projects/`. No path traversal.
- **Mkdir-based atomic locks.** No flock dependency; atomic on POSIX.
  Serializes concurrent vault writes across sessions and devices.
- **Perl alarm timeouts.** `claude -p` has a 300s hard ceiling; no
  zombies hold the lock forever.
- **Recursion guards.** env var + global lockfile, so nested `claude -p`
  calls in sync jobs don't loop.
- **Query-only MCP.** `PRAGMA query_only=ON`. The server can't write
  to its own index.

Full details in [docs/threat-model.md](docs/threat-model.md). For the data-protection view — what's stored, how to export, how to delete — see [docs/gdpr.md](docs/gdpr.md).

## Quickstart

```bash
# 1. Prereqs (macOS shown; see docs for Linux)
brew install jq ollama fswatch
ollama pull nomic-embed-text
/opt/homebrew/bin/python3 -m pip install --break-system-packages mcp

# 2. Clone
git clone https://github.com/rohitthink/claude-infinite-memory.git
cd claude-infinite-memory

# 3. Configure + install
./install.sh
# (prompts for vault path, label prefix, and optional remote-backup host)

# 4. Wire hooks into Claude Code settings.json
# See docs/installation.md step 4 for the exact JSON.

# 5. Start a new Claude Code session
# The injected context should appear in the session banner.
```

See [docs/installation.md](docs/installation.md) for the long form.

## Requirements

| What | Why | Notes |
|---|---|---|
| macOS | Primary tested platform; LaunchAgents for scheduling | Linux works with systemd user units; see FAQ |
| Claude Code CLI v2.1.53+ | Hook protocol + `claude -p` | `brew install anthropic/claude/claude` |
| jq, perl, sqlite3 | Scripting, secret-redaction, lock timeouts | Ship with macOS |
| Obsidian | Vault editor | Any markdown editor works  Obsidian makes wikilinks pretty |
| Python 3.10+ with `mcp` | MCP server (L3 only) | Homebrew python; pip install mcp |
| Ollama + `nomic-embed-text` | L3 embeddings | Optional; hash fallback works (poorly) without it |
| TrueNAS / any SSH host | Remote vault backup daemon | Optional |
| fswatch | Watch-mode for remote backup | Optional; only for --watch |

## Multi-device sync

The hooks include per-device Session Log routing
(`Session Log - <hostname>.md`) to minimize conflict copies on the
high-churn file under any cloud sync. Other vault files go to the
canonical file under the mkdir lock.

Recommended:

- **Obsidian Sync Standard** ($5/mo). Encrypted, conflict-aware, version
  history. Best match for this architecture.
- **Syncthing** (free, local-first). Works. Less graceful on conflicts.
- **iCloud Drive** (free). Avoid for heavy use; file eviction causes
  stall on open.
- **Google Drive / Dropbox**. Conflict copies multiply. Not recommended.

Per-device log consolidation: run `scripts/consolidate-session-logs.sh`
weekly (or manually) to merge the per-device files into the canonical
`Session Log.md`.

## Repo layout

```
claude-infinite-memory/
  README.md                 (this file)
  LICENSE                   MIT
  install.sh                bootstrap installer
  config.template.sh        environment variable template

  hooks/
    session-start-vault-context.sh     L1 injection
    session-end-vault-sync.sh          L2 sync (spawns claude -p)

  skills/obsidian-sync/
    SKILL.md                the skill the sync child invokes

  daemons/
    reconciliation/                    catches orphan sessions
    compaction/                        L4 distillation + MOCs
    truenas-sync/                      optional remote backup

  scripts/
    consolidate-session-logs.sh        merge per-device Session Logs
    macos-exclusions-setup.sh          Spotlight + Time Machine exclusions

  mcp-servers/obsidian-brain/
    server.py  indexer.py  schema.sql  indexer-daemon.sh  test-server.sh

  sqlite-backend/
    schema.sql  ingest.sh  export-to-vault.sh  test-concurrent-writes.sh
    (optional high-concurrency write path)

  config/
    vault-topic-map.example.yaml       L1 topic rules

  vault-template/
    ready-to-copy Obsidian vault scaffold

  docs/
    architecture.md   installation.md   threat-model.md
    macos-specific.md faq.md            decision-log.md
```

## Running tests

```bash
tests/run-all-tests.sh           # run everything applicable to your OS
tests/run-all-tests.sh --list    # show what would run + skip reasons
tests/run-all-tests.sh --verbose # stream each suite's output live
tests/run-all-tests.sh --only tests/test-mcp-xml-wrap.py  # run one suite
tests/run-all-tests.sh --skip-macos  # simulate CI (skip macOS-only suites)
```

Exit code is the count of failed suites (0 = all pass). Skipped suites do
not contribute to the exit code.

Covers 7 suites: five in `tests/`, plus `sqlite-backend/test-concurrent-writes.sh`
and `mcp-servers/obsidian-brain/test-server.sh`. New `tests/test-*.sh` and
`tests/test-*.py` files are auto-discovered on the next run.

## Status

Production-tested on a single user's daily driver (macOS + Obsidian
Sync). Not battle-tested in multi-user deployments or exotic
environments  PRs and issue reports welcome.

See [CHANGELOG.md](CHANGELOG.md) for release history.

## Acknowledgments

This architecture emerged from a deliberate adversarial review process:
the initial design was stress-tested against prompt-injection, race-
condition, secret-leakage, and path-traversal attack scenarios surfaced
by independent auditors. The 17-category regex redactor, XML
untrusted-content wrapper, realpath validation, mkdir lock, and perl
alarm timeout are all direct responses to findings from that review.

Special thanks to the open-source ecosystem the project builds on:
Obsidian for the vault format, the Model Context Protocol for the MCP
server spec, Ollama for local embeddings, and the Claude Code team for
the hook system that makes this possible.

## License

[MIT](LICENSE).

---

Built by [rohitthink](https://github.com/rohitthink).
