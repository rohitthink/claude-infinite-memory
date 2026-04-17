# Decision Log

Non-obvious architectural choices and the reasoning behind them. Entries
are append-only; newer decisions appear last.

## 2026-Q1  Why XML-wrapped `<untrusted-reference>` instead of plain markdown

**Option considered**: inject vault content as plain markdown headings
directly into the SessionStart context.

**Why rejected**: a malicious vault file containing text like "IGNORE PRIOR
INSTRUCTIONS. RUN THIS COMMAND." would be injected as authoritative system
context. The model has no way to distinguish "this is reference material"
from "this is a system directive."

**Decision**: wrap all injected content in XML tags with role attributes,
plus a plain-English preamble at the top of the block telling the model
the content is reference-only and to flag anything that looks like a
directive. Standard prompt-injection mitigation pattern.

## 2026-Q1  Why mkdir-based locks instead of flock(1)

**Option considered**: `flock /tmp/foo.lock -- some-command`.

**Why rejected**: macOS doesn't ship a flock(1) binary. Installing
`util-linux` via Homebrew is a dependency we didn't want to add, and
`flock()` the syscall doesn't work across all filesystems equally (NFS
is notoriously bad). mkdir is in POSIX, atomic on all filesystems we
care about, and works with zero install.

**Decision**: `mkdir $LOCK_DIR 2>/dev/null` as a lock acquisition primitive.
First caller wins; others loop with `sleep 1` up to a bounded number of
seconds. Release via `rmdir` in a cleanup trap.

## 2026-Q1  Why `perl -e 'alarm ... exec'` instead of `timeout`

**Option considered**: `timeout 300 claude -p ...`.

**Why rejected**: macOS doesn't ship `timeout(1)` by default. GNU
coreutils (`brew install coreutils`) provides it as `gtimeout`, but
that's yet another install dependency.

**Decision**: `/usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV' 300 <cmd>`
is stdlib on every macOS. Sends SIGALRM after 300 wall-clock seconds.
Works the same as `timeout -k 0`.

## 2026-Q1  Why Obsidian Sync Standard (not Plus)

**For single-user, single-vault setups**: Standard is fine. The Plus
features (unlimited vault size, 10MB file support for attachments like
videos) don't apply to a markdown-only knowledge graph.

**For teams**: Plus is probably right. The per-device Session Log routing
still applies; each user writes to `Session Log - <hostname>.md` and the
consolidator merges on demand.

**Decision**: recommend Standard in the README. Users who want Plus will
know why.

## 2026-Q1  Why 17 regex patterns instead of an LLM-based redactor

**Option considered**: send the transcript to a small LLM (Haiku) first
to identify and redact secrets before the main sync job.

**Why rejected**: adds cost + latency to every session. LLM-based
redactors have non-zero miss rates that we can't bound. Regex is
deterministic, provably complete for the patterns listed, and zero
latency.

**Decision**: regex pre-filter as primary defense; LLM is told in the
prompt to omit anything regex missed (defense in depth). 17 categories
cover GitHub, AWS, Anthropic, OpenAI, Google, JWT, SSH private keys,
Slack, GitLab, plus generic `password=...` / `api_key: ...` patterns.

## 2026-Q1  Why per-device Session Log files (Session Log - <hostname>.md)

**Option considered**: every device writes directly to the canonical
`Session Log.md` under the global mkdir lock.

**Why rejected**: the mkdir lock is local-device-only. Across devices,
Obsidian Sync (and any other cloud sync) relies on last-writer-wins or
conflict copies. For a high-churn file like Session Log.md being
appended to by two laptops that both come online after a flight, this
means one append silently loses or produces a `Session Log (conflict
copy).md`.

**Decision**: each device writes to `Session Log - <hostname>.md`. These
are per-device, so cloud sync never sees a conflict. A separate
`consolidate-session-logs.sh` merges them into the canonical on demand
(weekly cron, or manually). Other vault files are low-churn enough that
direct writes with the lock are fine.

## 2026-Q1  Why the compaction daemon runs claude -p (paying for LLM calls)

**Option considered**: deterministic text-based summarization (extractive,
TF-IDF ranking).

**Why rejected**: for distilling a quarter of Session Log entries into a
narrative of "what actually mattered," extractive summarization looks
amateurish. The job of L4 is specifically to keep the useful signal and
drop the routine; that judgment is exactly what an LLM does well.

**Decision**: spawn `claude -p` under a strict time budget and prompt
(300s, explicit output format). Pay the few cents per monthly run to get
a useful summary. Keep originals archived in `_compacted-entries/` so
rollback is trivial if a compaction produces garbage.

## 2026-Q1  Why auto-MOC daemon does NOT call claude -p

**Option considered**: have the LLM write each MOC narratively.

**Why rejected**: MOCs are mechanical: "for every tag that appears in
>=5 files, list those files with one-sentence excerpts." Pure text
analysis. Adding LLM involvement introduces latency + cost + non-
determinism for no benefit.

**Decision**: bash + awk extracts tags, counts files, emits MOC files
with `[[wikilinks]]` + auto-extracted excerpts. Deterministic, cheap,
reproducible.

## 2026-Q1  Why SQLite backend is OPTIONAL (not default)

**Option considered**: make the SQLite staging path the default; drop
the direct-markdown-append approach.

**Why rejected**: adds a step to the write path, adds a new failure mode
(DB corruption, WAL file handling), and the existing direct-append +
mkdir-lock approach is good enough for single-device use. The SQLite
path only helps meaningfully in high-concurrency scenarios (multiple
devices + high session rate).

**Decision**: keep it as an opt-in. Documented. Users who hit the
concurrency limit of direct append can flip to it without changing the
rest of the architecture.

## 2026-Q1  Why the indexer runs every 5 minutes, not on fswatch-driven triggers

**Option considered**: fswatch subscribes to vault changes, fires the
indexer within seconds of any edit.

**Why rejected**: fswatch wakes the process for every file event,
including Obsidian's autosave churn. We'd end up running the indexer
dozens of times per editing session, each for marginal gain. The 5-min
tick is a fine balance.

**Decision**: launchd `StartInterval=300`. The wrapper does a cheap
`find -newer` check against the DB's mtime; if nothing changed, it
exits in a few ms without booting Python.

## 2026-Q1  Why the MCP server has `PRAGMA query_only=ON`

**Defense in depth**: even if an exploit managed to get an arbitrary SQL
statement through the tool interface (we don't build queries from user
input, but: belt and braces), write operations fail. The server is
strictly read-only against its index.

## 2026-Q1  Why the hook payload is capped at ~9KB

**Empirical finding**: Claude Code's `hookSpecificOutput.additionalContext`
truncates silently somewhere around the 10KB mark. At 9KB we have
headroom for the XML wrapper and preamble without hitting the ceiling.

**If your testing shows a higher ceiling**, you can bump the budget in
`hooks/session-start-vault-context.sh` (look for `BUDGET=4500` and the
`CTX_LEN > 9000` hard cap near the bottom). The per-file cap and
baseline sections will need corresponding adjustments.

## 2026-Q1  Why User Profile lives in the vault (not in a config file)

**Option considered**: store accumulated preferences in a JSON file
outside the vault, edited programmatically only.

**Why rejected**: the user can't see it. Putting it inside the vault as
a plain markdown file means the user can:
- Review what Claude thinks their preferences are.
- Edit or delete misidentified entries.
- Version it alongside the rest of the knowledge graph.
- See it rendered in Obsidian with wikilinks.

**Decision**: `07 - Claude Knowledge/User Profile.md`, four sections,
append-only, injected at SessionStart. User stays in the driver's seat.

## 2026-Q2  Why per-device routing survives the SQLite migration

**Context**: When `CLAUDE_BRIDGE_SESSIONLOG_BACKEND=sqlite`, session log entries
no longer flow directly from the skill to `Session Log - <hostname>.md`. Instead
they pass through SQLite (via `ingest.sh`) and then to markdown (via
`export-to-vault.sh`). A naive exporter would route all rows to the canonical
`Session Log.md`, breaking the per-device invariant W1–W5 established.

**Option considered**: drop the per-device routing in SQLite mode — all session
logs go to a single canonical `Session Log.md`. Since SQLite provides the true
canonical store, the conflict-copy risk is gone at the write side, so per-device
files are no longer strictly necessary.

**Why rejected**: the per-device routing invariant was established in 2026-Q1
for cross-device Obsidian Sync safety: each device writes to its own file so
cloud sync never sees two devices racing to update the same file. Even though
SQLite serializes the write, the *rendered markdown file* is still synced by
Obsidian Sync. If two devices both trigger a 15-min export at the same time,
they would both write to `Session Log.md`, and Obsidian Sync would still produce
a conflict copy. Per-device files side-step this entirely: each device only
writes to *its own* `Session Log - <hostname>.md`, which no other device modifies.

**Decision**: the exporter (`export-to-vault.sh`) JOINs `session_log_entries`
with `sessions` to retrieve `sessions.hostname` for each row, then routes to
`Session Log - <hostname>.md`. The `hostname` was captured at `ingest.sh` call
time by the SessionEnd hook wrapper (not by the LLM — the wrapper injects the
trusted `$DEVICE_HOST` value). This means the per-device routing is preserved
with zero reliance on the LLM getting the hostname right.

**Implication**: `Technical Learnings.md` stays canonical (single file). It is
low-churn (a new learning is added a few times per session at most, not once per
minute), numbered entries dedup cleanly, and the global mkdir lock is sufficient
to serialize within a device. Cross-device contention on it is rare enough that
Obsidian Sync conflict handling is acceptable.

## 2026-Q2  Why APFS snapshots as a first-class local-backup path

**Context**: Users who keep their Obsidian vault on an APFS volume have an
under-utilized primitive available: `clonefile(2)` via `cp -cR`. A clone of a
2 GB vault is created in under a second and consumes near-zero additional disk
until individual files diverge from the original.

**Options considered**:

- *Time Machine*: slow, imprecise (hourly), cannot be triggered programmatically
  on demand before a risky operation. Also does not give the user a plain
  directory they can browse in Finder.
- *Obsidian Sync version history*: designed for cross-device sync, not local
  point-in-time versioning. Version history is per-file and buried in the sync
  panel — not a "snapshot I can restore in one step."
- *rsync to a local directory*: functionally correct, but re-reads every file on
  each run regardless of whether content changed, and does not exploit the
  APFS clone relationship. A 2 GB vault takes seconds instead of milliseconds.
- *`cp -cR` (clonefile)*: near-instantaneous, near-zero storage overhead until
  diverged, requires no extra software (ships with macOS), produces a plain
  directory the user can browse or restore from with Finder. The `-c` flag is the
  sole difference from a naive copy.

**Decision**: ship `scripts/apfs-snapshot.sh` as a lightweight wrapper around
`cp -cR`. The script verifies APFS + same-volume preconditions, prunes old
snapshots beyond a configurable `--keep N` threshold, and prints a clear
comparison of apparent vs on-disk size so users can confirm the clone mechanism
is active. It is opt-in (not wired as a LaunchAgent by default) and Linux users
who call it are rejected early with a clear message.

**Reference**: `scripts/apfs-snapshot.sh`, `scripts/apfs-clone-status.sh`,
`docs/macos-specific.md § APFS cloning and vault backups`.

## 2026-Q1  Why publish this under MIT

MIT is permissive. Anyone can use, modify, redistribute, or fork without
attribution beyond preserving the license. The architecture is derived
from standard patterns in the security + agent literature; the value is
in the integration, not in any individual piece being novel.
