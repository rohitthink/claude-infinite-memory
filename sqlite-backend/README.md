# SQLite Staging Backend (Optional)

**Status: OPTIONAL. Not active by default.**

This directory holds an alternative write path for the Obsidian vault bridge. The default flow is for the `obsidian-sync` skill + `session-end-vault-sync.sh` hook to append markdown directly to the vault files. That works, but the mkdir-lockfile only mitigates  not eliminates  concurrent-write races (partial writes if the process is killed mid-append, interleaving if the lock is ever bypassed, etc).

The SQLite backend fixes those by **staging** writes into a local DB in WAL mode. Concurrent sessions all write to the DB safely (SQLite+WAL serializes them atomically with no partial-write risk). A separate exporter drains the DB into the markdown files under the same global lock the existing hook uses, so the two write paths never race.

**The markdown files remain the source of truth for the user.** SQLite is a buffer, not a replacement.

## Files

| File | Purpose |
|------|---------|
| `schema.sql` | DDL: `sessions`, `session_log_entries`, `technical_learnings` tables + indexes + WAL pragma |
| `ingest.sh` | stdin -> SQLite INSERT. Called once per write from the skill/hook |
| `export-to-vault.sh` | SQLite -> markdown. Appends pending rows to vault, flips `exported_to_markdown=1`. Cron-safe, idempotent |
| `test-concurrent-writes.sh` | Forks 5 concurrent `ingest.sh` calls, verifies all 5 rows land |
| `vault-staging.db` | The DB itself (created on first `ingest.sh` run) |

## Installation (one-time)

The DB is auto-created on the first `ingest.sh` call, but you can preinitialize:

```bash
/usr/bin/sqlite3 "$CLAUDE_BRIDGE_HOME/sqlite-backend/vault-staging.db" \
  < "$CLAUDE_BRIDGE_HOME/sqlite-backend/schema.sql"
```

Verify WAL is on:

```bash
/usr/bin/sqlite3 "$CLAUDE_BRIDGE_HOME/sqlite-backend/vault-staging.db" \
  "PRAGMA journal_mode;"
# wal
```

## Enabling the backend

To flip the feature on, two pieces need to be wired (NOT YET DONE by default, so the existing flow stays untouched):

### 1. Write path: have the `obsidian-sync` skill call `ingest.sh` instead of writing markdown directly

In `~/.claude/skills/obsidian-sync/SKILL.md`, replace the existing "append to `Session Log.md`" instruction with something like:

> Emit one JSON object per fact to `$CLAUDE_BRIDGE_HOME/sqlite-backend/ingest.sh` via stdin, e.g.:
>
> ```bash
> jq -n --arg sid "$SESSION_ID" --arg title "..." --arg goal "..." --arg outcome "..." \
>   '{session_id:$sid, type:"session_log", title:$title, goal:$goal, outcome:$outcome}' \
>   | "$CLAUDE_BRIDGE_HOME/sqlite-backend/ingest.sh"
> ```

For technical learnings:

```bash
jq -n --arg sid "$SESSION_ID" --arg title "..." --arg problem "..." --arg solution "..." --arg applies "..." \
  '{session_id:$sid, type:"technical_learning", title:$title, problem:$problem, solution:$solution, applies_to:$applies}' \
  | "$CLAUDE_BRIDGE_HOME/sqlite-backend/ingest.sh"
```

The skill stops writing markdown directly. The SessionEnd hook does NOT need to change  it still invokes the skill; the skill's implementation is what moves to SQLite.

### 2. Export path: schedule `export-to-vault.sh` on cron (or launchd)

Cron example (every 15 minutes):

```cron
*/15 * * * * "$CLAUDE_BRIDGE_HOME/sqlite-backend/export-to-vault.sh"
```

Or as a launchd agent (macOS-native, survives reboot cleanly). A 5-minute interval is also reasonable  the exporter exits immediately when the DB has no pending rows, so frequent runs are cheap.

## Payload schema for `ingest.sh`

Single JSON object on stdin:

```json
{
  "session_id":      "<required>",
  "hostname":        "<optional; defaults to `hostname`>",
  "type":            "session_log | technical_learning",
  "started_at":      "<optional ISO8601>",
  "ended_at":        "<optional ISO8601>",
  "reason":          "<optional; SessionEnd reason field>",
  "transcript_path": "<optional>",

  // For type=session_log:
  "entry_date":    "YYYY-MM-DD (defaults to today)",
  "title":         "...",
  "goal":          "...",
  "outcome":       "...",
  "key_decisions": "...",
  "learnings":     "...",
  "links":         "...",

  // For type=technical_learning:
  "number":     123,
  "problem":    "...",
  "solution":   "...",
  "applies_to": "..."
}
```

## Operational notes

- **Concurrency**: WAL mode lets many readers/writers work simultaneously. Only one writer at a time inside SQLite, but SQLite queues them atomically. Proven by `test-concurrent-writes.sh`.
- **Injection safety**: `ingest.sh` uses SQL literal quote-doubling (the only escape SQLite recognizes in string literals) for every user-controlled value. No backslash, hex, or Unicode escapes to worry about.
- **Exporter + hook coexistence**: `export-to-vault.sh` grabs `$CLAUDE_BRIDGE_HOME/sync-active/vault-sync.lock`  the exact same mkdir-lock the SessionEnd hook uses. If you enable the SQLite path while the direct-write path is still active, they'll serialize correctly, but you'll get duplicate markdown entries. Pick one or the other per fact type.
- **Failure modes**:
  - DB corruption: WAL means this is unlikely; if it happens, `vault-staging.db-wal` and `-shm` are safe to delete (loses only in-flight writes)
  - Vault unmounted mid-export: exporter aborts cleanly, lock released, rows remain `exported_to_markdown=0` and retry next cron tick
  - Partial markdown write if process killed: the `UPDATE ... SET exported_to_markdown=1` happens AFTER the append. If the append succeeds but the update is killed, next run duplicates those rows. Acceptable for an append-only log; improvable later with a `BEGIN IMMEDIATE` transaction around both steps if it becomes a real problem.
- **Log file**: `$CLAUDE_BRIDGE_HOME/logs/sqlite-backend.log`

## Testing

```bash
# One-shot ingest smoke test
echo '{"session_id":"smoke-'$(date +%s)'","type":"session_log","title":"test","goal":"g","outcome":"o"}' \
  | "$CLAUDE_BRIDGE_HOME/sqlite-backend/ingest.sh"

# Drain to vault
"$CLAUDE_BRIDGE_HOME/sqlite-backend/export-to-vault.sh"

# Concurrent write stress test (5 parallel ingests)
"$CLAUDE_BRIDGE_HOME/sqlite-backend/test-concurrent-writes.sh"
```

## Rollback

If the SQLite path causes any trouble, rolling back is trivial: revert the `obsidian-sync` skill to its markdown-direct-append implementation and remove the cron entry. The `vault-staging.db` file is self-contained and can be inspected, archived, or deleted without affecting the vault.
