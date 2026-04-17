# Backup Safety Guards

Three independent security audits (Gemini, Grok, Perplexity) converged on the same critical finding:
`rsync --delete` with no source-sanity guard can destroy the backup dataset if the vault is
transiently empty (unmounted drive, in-flight rename, filesystem hiccup).

`obsidian-truenas-sync.sh` implements three layered guards that run **before every rsync call**
in both `--once` and `--watch` modes.

---

## Guards

### 1. File-count floor (`md_count_floor`)

```
find "$VAULT" -type f -name '*.md' | wc -l  <  MIN_MD_FILES
```

Aborts if the vault has fewer `.md` files than the configured minimum.

| Env var | Default | Override example |
|---------|---------|------------------|
| `MIN_MD_FILES` | `50` | `MIN_MD_FILES=30 ./obsidian-truenas-sync.sh --once` |

### 2. Byte-size floor (`bytes_floor`)

Aborts if the total on-disk size of all vault files falls below the configured threshold.
Catches a scenario where many files exist but are all zero-byte (filesystem corruption).

| Env var | Default | Override example |
|---------|---------|------------------|
| `MIN_VAULT_BYTES` | `100000` (≈ 100 KB) | `MIN_VAULT_BYTES=50000 ./obsidian-truenas-sync.sh --once` |

### 3. Deletion-percent guard (`delete_pct_floor`)

A **two-pass scheme**: a dry-run `rsync -n --stats` is executed first. The script parses
`Number of deleted files` from the stats output, divides by the current remote file count
(also parsed from the same dry-run output — no interactive SSH channel needed), and aborts
if the ratio exceeds the threshold.

| Env var | Default | Override example |
|---------|---------|------------------|
| `MAX_DELETE_PCT` | `20` (%) | `MAX_DELETE_PCT=5 ./obsidian-truenas-sync.sh --once` |

> **Initial seed**: if the remote directory is empty (`remote_count == 0`) the ratio check is
> skipped — first-time population always proceeds.

---

## Abort behaviour

On any guard trip the script:

1. Logs a structured abort line to `$LOG` **and** `stderr` (so launchd/systemd stderr captures it):

   ```
   YYYY-MM-DD HH:MM:SS [truenas-sync] ABORT: source sanity check failed (reason=<guard>) md_count=N bytes=B would_delete=D%
   ```

   `reason` is one of: `empty_vault`, `md_count_floor`, `bytes_floor`, `delete_pct_floor`.

2. Writes a run-summary line (also to `$LOG`):

   ```
   YYYY-MM-DD HH:MM:SS [truenas-sync] mode=once duration=0s exit=5 bytes-xferred=0 md_count=N total_bytes=B would_delete=NA
   ```

3. Exits non-zero (`5` = source-sanity guard; `6` = deletion-threshold guard).

The destination is **never touched** on an aborted run.

---

## Override flags

### `--force-delete`

Bypasses **all** guards and runs rsync normally. Logs a loud warning:

```
WARNING: --force-delete flag set; source-sanity guards BYPASSED
```

Use only for intentional wipes (vault rename, bulk delete, fresh seed).

### `--no-delete`

Runs rsync **without** `--delete` entirely (accumulator / versioned mode). The destination
may accumulate stale files but nothing is ever removed. No guard is needed because no
deletion can occur.

---

## Public-repo env vars

The public-repo twin (`daemons/truenas-sync/obsidian-truenas-sync.sh`) uses env vars
instead of hardcoded paths:

| Env var | Purpose |
|---------|---------|
| `CLAUDE_BRIDGE_VAULT` | Local vault path |
| `CLAUDE_BRIDGE_TRUENAS_HOST` | SSH host alias |
| `CLAUDE_BRIDGE_TRUENAS_PATH` | Remote destination path |
| `CLAUDE_BRIDGE_HOME` | Base dir for logs/lock (default `~/.claude`) |

Guard env vars (`MIN_MD_FILES`, `MIN_VAULT_BYTES`, `MAX_DELETE_PCT`) work identically in
both scripts.
