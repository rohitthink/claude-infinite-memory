# Data Protection Reference (GDPR / UK GDPR / CCPA)

This document answers: what personal data does `claude-infinite-memory`
create about you, where does it live, who sees it, and how do you act on
that — export it, correct it, or delete it.

> **Audience:** Users running this system who want to understand their
> data-protection position. If you're evaluating whether to publish or
> distribute this repo in the EU, UK, or California, this is the
> disclosure you need.
>
> **This system is self-hosted.** You run it on your own hardware. There
> is no central server operated by anyone other than you. That makes you
> the **data controller** for the local portion. The one third-party
> processor is Anthropic (for `claude -p` API calls). Section 8 covers
> what that means in practice.

---

## 1. What this system stores

Everything in the table below is written to **your machine only** (or to
storage you control). Nothing is automatically sent anywhere by this
system itself, except the Anthropic API calls described in §2.

| Location | What is stored | Lifecycle |
|---|---|---|
| `$CLAUDE_BRIDGE_HOME/projects/<session-id>/*.jsonl` | Full Claude Code transcripts — everything typed or pasted in the session, including code snippets, file paths, and anything you or the model wrote | Created by the Claude Code CLI; this system reads them at SessionEnd. Persist until deleted. |
| `$CLAUDE_BRIDGE_HOME/sync-state/reconciled.txt` | Session IDs that the reconciler has already processed (append-only) | Grows indefinitely; safe to delete (reconciler will re-scan, potentially duplicating vault entries). |
| `$CLAUDE_BRIDGE_HOME/sync-state/truenas-sync-heartbeat.txt` | Timestamp of the last successful TrueNAS / remote backup (if enabled) | Single line, overwritten each sync run. Contains no personal content beyond the timestamp. |
| `$CLAUDE_BRIDGE_HOME/logs/*.log` | Hook activity (session IDs, file paths, REJECTED events, redactor output), daemon heartbeats | Rotates at 1 MB per file. Rotated copies persist alongside the current log until deleted. |
| `$CLAUDE_BRIDGE_HOME/sqlite-backend/vault-staging.db` | L2 user preferences, L3 session-log entries and technical learnings, L4 compaction proposals and MOC cache (enabled via feature flag; see W5–W7 changes) | Grows with use; no built-in expiry. The `--tier=system-state` delete removes it. |
| `$VAULT/07 - Claude Knowledge/User Profile.md` | Accumulated user preferences and coding style notes, sometimes quoting session IDs. Written by the obsidian-sync skill. | Decays after ~180 days (W2 decay logic). Archived to `Historical Summaries/` at compaction rather than deleted. |
| `$VAULT/07 - Claude Knowledge/Session Log - <hostname>.md` | Per-device session activity log. Contains hostnames and session identifiers as structural markers. | Persists until compacted (90-day threshold). Consolidation merges per-device files into `Session Log.md`. |
| `$VAULT/07 - Claude Knowledge/Technical Learnings.md` | Technical decisions and debugging notes extracted from sessions, with per-entry session IDs. | Persists until compacted into a quarterly summary. |
| `$VAULT/07 - Claude Knowledge/Historical Summaries/*.md` | Quarterly distillations of Session Log + User Profile content (e.g., `2025-Q1-summary.md`). Produced by the L4 compaction daemon. | Permanent by default; manually delete if desired. |

> **Absolute-path examples** (substituting defaults):
>
> ```
> ~/.claude/projects/abc123def456/conversation.jsonl   ← transcript
> ~/.claude/sync-state/reconciled.txt
> ~/.claude/logs/obsidian-sync.log
> ~/.claude/sqlite-backend/vault-staging.db
> ~/Documents/MyVault/07 - Claude Knowledge/User Profile.md
> ~/Documents/MyVault/07 - Claude Knowledge/Session Log - my-macbook.md
> ```
>
> Your actual paths are set in `$CLAUDE_BRIDGE_HOME/claude-infinite-memory.env`.

---

## 2. What leaves your machine

### Anthropic (required for core function)

Every `claude -p` call — triggered at SessionEnd and by the compaction
daemon — sends data to Anthropic's API:

- **What is sent:** The redacted transcript (17-category secret regex
  applied first), plus a prompt asking the model to extract outcomes.
  Vault files referenced by L1 injection are also sent as session
  context.
- **What is NOT sent:** Your raw vault wholesale, your filesystem, or
  anything outside the session transcript and L1 context slice.
- **Anthropic retention:** Subject to Anthropic's current privacy policy
  and API data-retention terms. See:
  - Privacy policy: https://www.anthropic.com/privacy
  - API data usage: https://www.anthropic.com/legal/aup
  - Privacy request form: https://privacy.anthropic.com/ (use this for
    deletion requests — see §7 below)

### Ollama (local only)

The L3 MCP semantic search uses Ollama's `nomic-embed-text` model to
generate embeddings. **Ollama runs locally.** No embedding data, query
text, or vault content is uploaded to any remote service through this
path.

### TrueNAS / remote backup (optional)

If you configured a TrueNAS or SSH remote during install, the
`truenas-sync` daemon rsyncs your vault directory to that host on a
schedule. This is a full snapshot of `$VAULT` — including all
Claude-authored knowledge files. The remote host is one you supplied and
control. This bridge does not operate it.

### Cloud sync (user's choice)

If your vault directory is inside an Obsidian Sync, iCloud Drive,
Syncthing, or Google Drive folder, vault content (including
`07 - Claude Knowledge/`) is synced to those providers per their own
terms. This bridge does not initiate those syncs. You own that data
relationship.

---

## 3. What is NOT collected

This system contains **no telemetry, analytics, crash reporting, or
remote logging** of its own. It phones home to nobody except the
Anthropic API for `claude -p` calls (which you initiated by running the
system). There is no update check, no usage counter, no error beacon.

The only outbound network activity this system initiates:
1. `claude -p` → Anthropic API (your key, your bill)
2. `rsync` → your TrueNAS host (if configured, initiated by your launchd
   schedule)
3. `ollama` → localhost (never leaves your machine)

---

## 4. Access

Your data is already maximally accessible: it's markdown files and JSON
Lines in directories you own. You can read any of it directly:

```bash
# Transcripts
ls "$CLAUDE_BRIDGE_HOME/projects/"

# Preferences
cat "$VAULT/07 - Claude Knowledge/User Profile.md"

# Session activity
cat "$VAULT/07 - Claude Knowledge/Session Log - $(hostname).md"

# Reconciliation state
cat "$CLAUDE_BRIDGE_HOME/sync-state/reconciled.txt"

# SQLite (if using sqlite-backend)
sqlite3 "$CLAUDE_BRIDGE_HOME/sqlite-backend/vault-staging.db" .dump
```

---

## 5. Rectification

**Vault content** (User Profile, Session Log, Technical Learnings):
Open the file in Obsidian or any text editor and edit directly. The
system reads these files on every SessionStart; changes take effect
immediately at the next session.

**L2 preferences via skill**: Run `/promote-prefs` in a Claude Code
session to trigger the obsidian-sync skill, which will re-evaluate and
clean up the User Profile from the current session's context.

**SQLite backend**: The `sqlite-backend/export-to-vault.sh` script
exports the DB to vault markdown. Edits to the vault then flow back via
the normal ingest path.

---

## 6. Retention

| Data | Current lifecycle |
|---|---|
| L2 User Profile entries | Decay after ~180 days (W2 decay logic; configurable via `PREF_DECAY_DAYS`) |
| L3 Session Log entries | Compacted into quarterly summary after 90 days (configurable via `COMPACTION_HORIZON_DAYS`) |
| Log files | Rotate at 1 MB; rotated files persist until deleted |
| Transcripts | No built-in expiry; owned by Claude Code CLI |
| Historical Summaries | Permanent until manually deleted |
| SQLite DB rows | No built-in expiry; `gdpr-delete.sh --tier=system-state` removes the DB |

---

## 7. Erasure

Use `scripts/gdpr-delete.sh` (ships with this repo) for structured
local deletion. It has three tiers:

```bash
# Preview what would be deleted (dry-run, no changes):
scripts/gdpr-delete.sh --tier=system-state --dry-run

# Delete transcripts, logs, sync-state, sqlite DB:
scripts/gdpr-delete.sh --tier=system-state --confirm

# Also remove Claude's knowledge files from the vault:
scripts/gdpr-delete.sh --tier=claude-vault-content --confirm

# Full erasure — everything under $CLAUDE_BRIDGE_HOME:
scripts/gdpr-delete.sh --tier=all --confirm
```

The script enumerates every file and directory before deletion, prints
total sizes, and optionally runs `gdpr-export.sh` first so you have a
copy.

**Manual erasure checklist** (if you prefer not to use the script):

1. `rm -rf "$CLAUDE_BRIDGE_HOME/projects/"` — transcripts
2. `rm -f "$CLAUDE_BRIDGE_HOME/sync-state/reconciled.txt"` — sync state
3. `rm -rf "$CLAUDE_BRIDGE_HOME/logs/"` — log files
4. `rm -f "$CLAUDE_BRIDGE_HOME/sqlite-backend/vault-staging.db"` — SQLite
5. `rm -rf "$VAULT/07 - Claude Knowledge/"` — Claude's vault content

**Anthropic deletion (for `claude -p` history):**

The API calls this system makes are associated with your Anthropic
account. To request deletion of historical API conversation data:

1. Visit https://privacy.anthropic.com/
2. Submit a "Delete my data" request, identifying yourself as an API
   user.
3. Anthropic's privacy team will process the request per their stated
   retention policy.

**TrueNAS / remote backup deletion:**

The delete script does not touch remote hosts. To remove vault content
from a TrueNAS backup, you need to run the rsync delete yourself:

```bash
rsync --delete -av --filter='P ./' \
  /empty-dir/ \
  <truenas-user>@<truenas-host>:<vault-backup-path>/
```

Or log into the TrueNAS host and remove the dataset directly.

---

## 8. Portability (Export)

Use `scripts/gdpr-export.sh` to produce a portable archive of
everything this system stores about you locally:

```bash
# Preview the file list without creating the archive:
scripts/gdpr-export.sh --dry-run

# Create the archive (default: ~/Desktop/claude-memory-export-YYYYMMDD.tar.gz):
scripts/gdpr-export.sh

# Custom output path:
scripts/gdpr-export.sh --output ~/Documents/my-export.tar.gz

# Include your entire vault (opt-in; this is your own authored content):
scripts/gdpr-export.sh --include-full-vault
```

The archive includes a `MANIFEST.md` at its root listing every file
with its purpose and origin.

**Note on secrets:** The export script archives raw files, including
transcripts that may contain content the redactor would strip before
sending to Anthropic. The archive is yours — treat it with the same
care you'd give the source files. It is not pre-filtered.

---

## 9. Data subject requests

Because this system is **self-hosted**, you are both the data subject
and the data controller for the local portion. There is no data
controller separate from yourself to submit requests to.

For the Anthropic API portion, Anthropic is the processor/controller of
data you submit via their API. Exercise data subject rights (access,
rectification, erasure, portability) through:

- Anthropic Privacy Center: https://privacy.anthropic.com/
- Anthropic privacy contact: privacy@anthropic.com

If you are deploying this system for others (e.g., team use), you
become the data controller for those users' data and should implement
a proper subject-access-request workflow appropriate to your
jurisdiction.
