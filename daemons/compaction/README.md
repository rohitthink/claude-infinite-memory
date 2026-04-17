# L4 Compaction Daemons

Two jobs keep the vault lean and navigable:

| Daemon | Schedule | What it does |
|--------|----------|--------------|
| `compaction-daemon.sh` | Monthly (1st, 03:00) | Distills 90-day-old Session Log entries into quarterly summaries |
| `auto-moc-daemon.sh` | Weekly (Sunday, 04:00) | Generates Maps of Content for tags with ≥5 references |

Both are **human-in-the-loop**: the compaction daemon writes a `.proposed.md` staging file and requires explicit `--apply` to commit. The MOC daemon is stateless text analysis — no LLM involved.

---

## SQLite cache paths

Both daemons can optionally store state in the shared SQLite DB at `$CLAUDE_BRIDGE_HOME/claude-bridge.db`.

### Compaction cache — `CLAUDE_BRIDGE_COMPACTION_CACHE`

| Value | Behaviour |
|-------|-----------|
| `file` (default) | Legacy disk-glob behaviour. Proposals tracked only as `.proposed.md` files on disk. |
| `sqlite` | Every proposal is tracked from inception to apply/discard. Enables sha256 tamper-detection on `--apply`, orphan detection at startup, and structured `--list-pending` output. |

**Schema table**: `compaction_proposals` (see `sqlite-backend/schema.sql`).

**Lifecycle** (sqlite mode):

```
compaction-daemon.sh (default run)
  ├─ INSERTs row with status='staged' + proposal_sha256='_pending'
  ├─ Invokes claude -p
  └─ UPDATEs proposal_sha256 after file is written

compaction-daemon.sh --apply
  ├─ Verifies current sha256 matches stored (tamper-check)
  ├─ Merges proposal into canonical summary
  └─ UPDATEs row to status='applied', applied_at, applied_by

compaction-daemon.sh --discard YYYY-Qn
  ├─ Removes .proposed.md from vault
  └─ UPDATEs row to status='discarded'

On startup (any mode)
  └─ db_orphan_sweep(): rows with status='staged' and missing file → 'orphaned'
```

**Flags added for sqlite mode**:
- `--list-pending` — queries DB instead of globbing disk
- `--discard YYYY-Qn` — structured discard with DB audit trail
- `--force-apply-modified` — override sha256 mismatch (emergency use only)

### MOC cache — `CLAUDE_BRIDGE_MOC_CACHE`

| Value | Behaviour |
|-------|-----------|
| `scan` (default) | Full O(vault) scan on every run. |
| `sqlite` | Incremental: only re-parses files whose mtime > cached value. Second run on an unchanged vault is ≥10× faster. |

**Schema table**: `moc_file_tags` (see `sqlite-backend/schema.sql`).

**How it works** (sqlite mode):
1. For each candidate file, compare `stat mtime` to `MAX(file_mtime)` in the cache.
2. If newer: `DELETE` old rows for that file, re-parse tags, `INSERT` new rows.
3. If unchanged: read tags directly from DB (no file I/O).
4. After scan: detect deleted files via `SELECT DISTINCT file_path` and prune stale rows.

**Flags added for sqlite mode**:
- `--invalidate` — truncates `moc_file_tags` and forces a full rebuild (escape hatch)

Also: the `MIN_REFERENCES` constant (line 53) is now overridable via the `MOC_MIN_FILES` env var (default 5).

---

## Getting started with SQLite mode

```bash
# 1. Seed the DB from existing vault state (idempotent)
sqlite-backend/migrate-l4-cache.sh

# 2. Enable compaction tracking
export CLAUDE_BRIDGE_COMPACTION_CACHE=sqlite

# 3. Enable incremental MOC cache
export CLAUDE_BRIDGE_MOC_CACHE=sqlite

# 4. Check state at any time
sqlite-backend/compaction-report.sh
```

Add both exports to your `claude-infinite-memory.env` file to make them permanent.

---

## Reporting tool

`sqlite-backend/compaction-report.sh` — a read-only CLI that prints:
- Staged proposals (pending `--apply`)
- Recently applied proposals (last 12 months)
- Orphaned proposals (file missing; need investigation)
- MOC cache freshness stats

Use this instead of digging through `--list-pending` or log files.

```bash
# Example:
CLAUDE_BRIDGE_HOME=~/.claude sqlite-backend/compaction-report.sh
```

---

## Migration from file-only mode

Run `sqlite-backend/migrate-l4-cache.sh` once after enabling SQLite mode. It:
- Walks `Historical Summaries/*.proposed.md` → inserts `status='staged'` rows
- Walks `Historical Summaries/*.md` (applied) → inserts `status='applied'` rows
- Full vault scan → seeds `moc_file_tags`

The script is idempotent (safe to re-run).

---

## Rollback

Set the env vars back to their defaults (`file` / `scan`). The daemon reverts to disk-glob behaviour with no DB access. The SQLite tables are left intact and can be re-enabled at any time.
