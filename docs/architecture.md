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
corrections, documented anti-patterns) and writes them into a **Pending
review** gate in `07 - Claude Knowledge/User Profile.md`. The user runs
`/promote-prefs` to move entries into the authoritative sections. A monthly
`scripts/decay-prefs.sh` demotes preferences unseen for >180 days into an
Archive section (recoverable, not deleted).

**Why**: The single biggest friction in agent work is re-explaining your
preferences every session. L2 amortizes that cost to zero. The Pending gate
prevents a single misclassified signal from permanently polluting the
profile. The decay mechanism keeps the profile current over months.

**Shape**: Six sections in User Profile.md:

| Section | Writable by | Injected at SessionStart |
|---|---|---|
| Communication style | `/promote-prefs` only | Yes |
| Technical preferences | `/promote-prefs` only | Yes |
| Anti-patterns | `/promote-prefs` only | Yes |
| Tooling preferences | `/promote-prefs` only | Yes |
| Pending review | SessionEnd hook | No (unreviewed) |
| Archive (stale) | `decay-prefs.sh` only | No (stale) |

**L2 preference lifecycle**:

```
  SessionEnd hook detects signal
            │
            ▼
  ┌─────────────────────┐
  │   ## Pending review │  ← gated; NOT injected at SessionStart
  │   (timestamped,     │
  │    confidence level)│
  └──────────┬──────────┘
             │  user runs /promote-prefs
             │
    ┌────────┼──────────────┐
    │        │              │
    ▼        ▼              ▼
 Promote   Merge with   Discard
    │      existing        │
    │         │            └─ removed
    ▼         ▼
  ┌─────────────────────────────┐
  │  ## Communication style     │  ← authoritative; injected at SessionStart
  │  ## Technical preferences   │    entries carry last-reinforced: YYYY-MM-DD
  │  ## Anti-patterns           │
  │  ## Tooling preferences     │
  └────────────────┬────────────┘
                   │  decay-prefs.sh (monthly)
                   │  if last-reinforced > 180 days ago
                   ▼
  ┌─────────────────────────────┐
  │  ## Archive (stale)         │  ← recoverable; NOT injected at SessionStart
  │  (archived YYYY-MM-DD,      │
  │   was in: <section>)        │
  └─────────────────────────────┘
```

**Reinforcement**: Each time a promoted preference is re-observed in a
session, the SessionEnd hook increments its `(seen Nx)` counter and updates
`last-reinforced: YYYY-MM-DD`. This prevents the decay pass from archiving
actively-used preferences.

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

## Tier 3: SQLite WAL canonical storage (Session Log, Technical Learnings, User Profile)

Three independent audits (Gemini, Grok, Perplexity) converged on the same
meta-recommendation: machine-generated writes should use SQLite WAL as the
**canonical store** and markdown as a **derived view**.

Three vault surfaces are flag-gated to SQLite, each independently:

| Surface | Flag | Default | Export cadence |
|---------|------|---------|----------------|
| L2 User Profile | `CLAUDE_BRIDGE_PREFS_BACKEND` | `markdown` | Hourly |
| L3 Session Log | `CLAUDE_BRIDGE_SESSIONLOG_BACKEND` | `markdown` | 15-min |
| L3 Technical Learnings | `CLAUDE_BRIDGE_TECHLEARN_BACKEND` | `markdown` | 15-min |

All three default to `markdown` — existing behaviour is fully preserved unless
the user opts in by setting the relevant flag to `sqlite`.

### Design: L2 User Profile

```
SessionEnd hook
  │
  ├─ (CLAUDE_BRIDGE_PREFS_BACKEND=markdown, default)
  │     claude -p writes directly to User Profile.md
  │     [existing behaviour, unaffected]
  │
  └─ (CLAUDE_BRIDGE_PREFS_BACKEND=sqlite)
        claude -p outputs JSON preference block
              │
              ▼
        session-end wrapper
              │  extract ```json ... ``` block
              ▼
        ingest.sh  type=user_preference_batch
              │
              ▼
        SQLite WAL  user_preferences table
              │
              ▼  (hourly launchd / on-demand)
        export-to-vault.sh --section user-profile
              │
              ▼
        User Profile.md   (derived view; always fully regenerated)
```

### Design: L3 Session Log + Technical Learnings

```
SessionEnd hook
  │
  ├─ (CLAUDE_BRIDGE_SESSIONLOG_BACKEND=markdown, default)
  │     claude -p appends to Session Log - <hostname>.md directly
  │
  └─ (CLAUDE_BRIDGE_SESSIONLOG_BACKEND=sqlite)
        claude -p emits NDJSON lines (one JSON object per session milestone)
              │
              ▼
        session-end wrapper
              │  scan output lines where type=session_log
              │  inject session_id + hostname (trusted; LLM not trusted for these)
              ▼
        ingest.sh  type=session_log
              │
              ▼
        SQLite WAL  session_log_entries table (FK → sessions)
              │
              ▼  (15-min launchd / on-demand)
        export-to-vault.sh --section meta-project
              │
              ▼
        Session Log - <hostname>.md   (per-device; derived view)
        [per-device routing PRESERVED — sessions.hostname drives the file name]

  ├─ (CLAUDE_BRIDGE_TECHLEARN_BACKEND=markdown, default)
  │     claude -p appends to Technical Learnings.md directly
  │
  └─ (CLAUDE_BRIDGE_TECHLEARN_BACKEND=sqlite)
        claude -p emits NDJSON lines (one JSON object per new learning)
              │
              ▼
        session-end wrapper  →  ingest.sh  type=technical_learning
              │
              ▼
        SQLite WAL  technical_learnings table
              │
              ▼  (15-min launchd / on-demand)
        export-to-vault.sh --section meta-project
              │
              ▼
        Technical Learnings.md   (canonical single file; derived view)
```

### Key properties

- **Concurrency-safe**: WAL mode + FK constraints. Concurrent writers queue
  atomically; session_log_entries + technical_learnings use autoincrement PKs
  (no collision risk between writers).
- **Idempotent migration**: `migrate-meta-project.sh` reads existing Session Log
  and Technical Learnings markdown, synthesizes deterministic `session_id` values
  (sha1 of heading slug), inserts via `INSERT OR IGNORE`, renames originals to
  `.pre-sqlite-backup`. Reruns are safe.
- **Markdown is derived, not authoritative**: `export-to-vault.sh --full-rebuild`
  truncates destination files and regenerates from DB. Files can be deleted and
  rebuilt at any time with no data loss.
- **Feature flag default off**: all three flags default to `markdown`. Existing
  sessions are unaffected until the user opts in.
- **Per-device routing preserved in SQLite mode**: the exporter JOINs
  `session_log_entries` with `sessions` to get `hostname` for each row, then
  routes to `Session Log - <hostname>.md`. The canonical `Session Log.md` is
  never touched by the exporter.
- **Schema idempotency**: `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT
  EXISTS` mean running `schema.sql` on an existing DB is always a no-op.

### Files

| File | Role |
|------|------|
| `sqlite-backend/schema.sql` | `sessions`, `session_log_entries`, `technical_learnings`, `user_preferences` tables + indexes |
| `sqlite-backend/ingest.sh` | All four type dispatchers; `ingest_preference()` / `sqlq()` (sourceable) |
| `sqlite-backend/export-to-vault.sh` | `--section user-profile` (hourly), `--section meta-project` (15-min), `--full-rebuild` |
| `sqlite-backend/migrate-from-markdown.sh` | One-time User Profile markdown → SQLite migration |
| `sqlite-backend/migrate-meta-project.sh` | One-time Session Log + Technical Learnings markdown → SQLite migration |
| `sqlite-backend/com.example.sqlite-export.plist.template` | Hourly launchd export job (User Profile) |
| `sqlite-backend/com.example.sqlite-export-meta-project.plist.template` | 15-min launchd export job (Session Log + Technical Learnings) |
| `hooks/session-end-vault-sync.sh` | Feature-flag detection; NDJSON drain + ingest for all three sqlite backends |

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
