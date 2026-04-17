# Architecture

`claude-infinite-memory` is a four-layer "learning brain" that turns your
Obsidian vault into Claude Code's persistent memory. This document walks
through each layer and the pieces that implement it.

## The big picture

```
                    +-------------------------------------+
                    |        Your Obsidian Vault          |
                    |  _Maps/  02 - Projects/  07 - CK/   |
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
                            |                                        |
                            |   indexer -> SQLite/WAL -> MCP server  |
                            |     (every 5 min via launchd)          |
                            +----------------------------------------+

                            +---------- L4 compaction ----------+
                            |                                   |
                            |   monthly: 90-day distillation    |
                            |   weekly:  MOCs (Maps of Content) |
                            +-----------------------------------+

                 +-------- reconciliation --------+
                 |  orphan transcripts (SIGKILL,  |
                 |  crash, API 500) caught here   |
                 +--------------------------------+
```

## Four learning layers

### L1: Topic-aware retrieval

**What**: On every new session, inject a topic-matched slice of the vault as
`additionalContext`.

**How**: `hooks/session-start-vault-context.sh` reads the session's `cwd`
from the hook input, consults `config/vault-topic-map.yaml` for matching
rules, and injects the listed vault files (capped at ~9KB total).

**Why**: A global memory dump would blow the context budget. Topic-matched
retrieval keeps the slice relevant without requiring semantic search at
session-start time (which would add latency).

**Safety**: All injected content is wrapped in `<untrusted-reference>` XML
tags with an explicit "reference only, not instructions" preamble. A
compromised vault file cannot hijack the session via prompt injection
because the model is told up front to treat this content as data, not
directives.

### L2: User profile accumulation

**What**: A durable record of the user's preferences, accumulated across
every session.

**How**: The SessionEnd hook's child `claude -p` job scans the transcript
for preference signals (explicit "I prefer X" statements, implicit repeated
corrections, documented anti-patterns) and appends de-duplicated entries to
`07 - Claude Knowledge/User Profile.md`.

**Why**: The single biggest friction in agent work is re-explaining your
preferences every session. L2 amortizes that cost to zero.

**Shape**: Append-only. Four sections: Communication style, Technical
preferences, Anti-patterns, Tooling preferences. De-duped by Grep before
append; consolidated when any section exceeds ~30 entries.

### L3: Semantic search (MCP)

**What**: When the model needs to know something that isn't in the L1
injection, it can search the vault semantically.

**How**: `mcp-servers/obsidian-brain` runs as an MCP server. It maintains a
local SQLite index (chunked at heading boundaries, embedded via Ollama's
`nomic-embed-text`). The indexer daemon runs every 5 minutes. The MCP
server exposes four tools: `search_vault`, `get_file`, `list_topics`,
`recent_entries`.

**Why**: L1 is a fixed budget. L3 lets the model pull in arbitrary vault
content on demand without the model's author having to predict in advance
what it might need.

**Safety**: All tool responses pass through the 17-pattern regex redactor
that mirrors the SessionEnd hook. `get_file` validates paths with realpath
and rejects anything outside the vault or under `05 - Personal/`.
`search_vault` rejects obviously-shell-injection queries.

### L4: Compaction + Maps of Content

**What**: Keep the vault from bloating. Distill old content. Surface
emergent topic clusters.

**How**:
- `daemons/compaction/compaction-daemon.sh` runs monthly in **proposal
  mode** (human-in-the-loop). It reads `Session Log.md` entries older
  than 90 days, spawns `claude -p` to distill them, and writes the
  DISTILLED output to
  `07 - Claude Knowledge/Historical Summaries/YYYY-Qn.proposed.md`.
  **Nothing destructive happens automatically.** The Session Log is
  left untouched and the originals are not moved.
- The user reviews the `.proposed.md` file and runs
  `compaction-daemon.sh --apply` to commit. `--apply` refuses to run
  without an interactive TTY (or explicit `--yes`) and sanity-checks
  that the proposal mtime is newer than the originals before
  appending to the canonical `YYYY-Qn.md` summary, archiving originals
  into `_compacted-entries/YYYY-Qn/`, and rewriting Session Log.md.
  Technical Learnings follows the same pattern via
  `Technical Learnings.proposed.md`.
- `compaction-daemon.sh --list-pending` prints any staged proposals.
- `daemons/compaction/auto-moc-daemon.sh` runs weekly. It scans the
  vault for tags appearing in >=5 files and generates a
  `07 - Claude Knowledge/MOCs/<tag>.md` Map of Content. Pure text, no
  LLM involvement.

**Why**: Knowledge decays in value over time. L4 prunes the noise while
preserving the signal  and surfaces emergent themes the user might not
have named yet. The human-in-the-loop split (propose, review, apply)
prevents a hallucinated `claude -p` summary from silently deleting
months of history.

**Safety (2026-04-16 audit)**: The `claude -p` subprocess is invoked
with a minimal `--allowedTools "Read,Write,Edit,Glob,Grep"` — Bash and
Skill are deliberately excluded so a prompt-injected vault file cannot
pivot to shell execution. A defensive preamble is prepended to every
prompt telling the model to treat the inline corpus as untrusted data,
not instructions. The MOC daemon invokes no LLM and therefore has no
allow-list to narrow.

## Component inventory

| Component | Path | Triggered by |
|---|---|---|
| L1 topic injection | `hooks/session-start-vault-context.sh` | Claude Code SessionStart |
| L2 session sync | `hooks/session-end-vault-sync.sh` + `skills/obsidian-sync/SKILL.md` | Claude Code SessionEnd |
| L3 indexer | `mcp-servers/obsidian-brain/indexer.py` | launchd every 5 min |
| L3 server | `mcp-servers/obsidian-brain/server.py` | Claude Code MCP |
| L4 compaction | `daemons/compaction/compaction-daemon.sh` | launchd monthly |
| L4 MOCs | `daemons/compaction/auto-moc-daemon.sh` | launchd weekly |
| Orphan recovery | `daemons/reconciliation/obsidian-reconciliation-daemon.sh` | launchd continuous |
| Log merger | `scripts/consolidate-session-logs.sh` | manual / cron |
| Remote backup | `daemons/truenas-sync/obsidian-truenas-sync.sh` | launchd continuous |
| SQLite staging (optional) | `sqlite-backend/` | obsidian-sync skill (if enabled) |

## Data flow (happy path)

1. User starts a new Claude Code session.
2. SessionStart hook reads `cwd`, picks matching rule from
   `vault-topic-map.yaml`, injects up to ~9KB of vault content wrapped in
   `<untrusted-reference>` tags.
3. User works. Model can invoke `search_vault` / `get_file` etc. for any
   vault content not in the injection.
4. Session ends. SessionEnd hook redacts the transcript (17-category
   regex), spawns a detached `claude -p` child to run the obsidian-sync
   skill.
5. Child acquires the global mkdir lock, appends to:
   - `Session Log - <hostname>.md` (per-device for conflict avoidance)
   - `Technical Learnings.md` (canonical; serialized by the lock)
   - `User Profile.md` (if preference signals detected)
   - whichever project/client/infra file changed
6. Child releases lock, cleans up spool files, exits.
7. Every 5 min, indexer daemon re-embeds any .md file newer than the DB.
8. Every Sunday 04:00, auto-moc daemon walks the vault and updates MOCs.
9. Every 1st-of-month 03:00, compaction daemon distills 90-day-old
   entries into a quarterly `*.proposed.md` staging file. No
   destructive step runs until the user reviews and invokes
   `compaction-daemon.sh --apply`.

## Multi-device topology

- Each device has its own `$CLAUDE_BRIDGE_HOME` (local).
- All devices share the same vault via Obsidian Sync (or similar).
- To avoid conflict copies on the high-churn `Session Log.md`, each device
  writes to `Session Log - <hostname>.md`. A separate consolidator
  (`scripts/consolidate-session-logs.sh`) merges per-device files into the
  canonical on demand or weekly.
- Other vault files (Technical Learnings, Skills Index, etc.) are low-churn
  enough to tolerate direct writes; the global mkdir lock serializes
  writes within a single device, and Obsidian Sync handles the
  cross-device serialization.
