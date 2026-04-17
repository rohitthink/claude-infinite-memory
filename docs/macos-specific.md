# macOS-specific notes

Several components have macOS-specific quirks worth knowing about.

## LaunchAgent plists must live on the boot drive

**Symptom**: `launchctl bootstrap gui/$(id -u) /Volumes/ExternalDisk/path/to/foo.plist` returns `Input/output error` or `Error 5`.

**Root cause**: macOS `launchctl` refuses to bootstrap an agent whose plist lives on a non-boot volume. The program the plist points at can be anywhere (external drive is fine), but the plist file itself must be in `~/Library/LaunchAgents/` on the boot drive.

**Fix**: Copy or symlink plists into `~/Library/LaunchAgents/`. The `install.sh` script handles this automatically.

**Why it matters for this project**: If you keep your `$CLAUDE_BRIDGE_HOME` on an external drive (the reference setup does), the plist templates still need to be installed on the boot drive. The install script detects this and does the right thing.

## Spotlight indexing Claude Code transcripts

**Symptom**: `mdworker_shared` spikes CPU during heavy Claude Code sessions. Finder searches slow to a crawl.

**Root cause**: Claude Code writes transcripts to `~/.claude/projects/<id>/*.jsonl`. Spotlight tries to index every one. For a session with tens of thousands of tool calls, this is expensive and pointless.

**Fix**: Place a `.metadata_never_index` empty file in `$CLAUDE_BRIDGE_HOME`. Spotlight will skip the whole tree. `scripts/macos-exclusions-setup.sh` does this automatically.

### When mds gets stuck

On large Obsidian vaults (10k+ files) or after bulk imports, `mds` / `mds_stores` / `mdworker_shared` can behave pathologically beyond normal transcript indexing.

**Three symptoms to watch for**:

1. **CPU spike** — `mds` or `mds_stores` shows 90–100% CPU in Activity Monitor for more than a few minutes. A short burst after a big import is normal; sustained high CPU on a quiescent vault is not.
2. **Finder slowness** — file opens, search, and Quick Look noticeably lag. This often co-occurs with mds CPU contention.
3. **Disk churn** — `iotop` or Disk Diag shows continuous high write I/O from `mdworker_shared`. Combined with high CPU, this usually indicates mds is reprocessing the same files in a loop, often triggered by a malformed file (corrupt EXIF, damaged PDF, bad UTF-8) that mdworker can't finish indexing.

**How `scripts/mds-watchdog.sh` catches each**:

The watchdog runs every 15 minutes via its LaunchAgent. It:

- Reads `ps -eo pid,pcpu,etime,comm` and filters for mds processes. If CPU exceeds the threshold (default 90%) **and** the process has been running long enough (default 5 min), it fires a macOS notification and logs a warning to `$CLAUDE_BRIDGE_HOME/logs/mds-watchdog.log`.
- Checks that `.metadata_never_index` still exists in `$CLAUDE_BRIDGE_HOME`. If the flag was removed (Finder cleanup, sync peer "organize" operation, Time Machine restore), the watchdog recreates it immediately and logs the event.
- Estimates the Spotlight metadata cache size under `/var/folders/.../com.apple.metadata/`. If the cache exceeds 10 GB **and** mds CPU is high, it fires an additional notification suggesting `mdutil -E`.
- Writes a heartbeat timestamp to `$CLAUDE_BRIDGE_HOME/sync-state/mds-watchdog-heartbeat.txt` each run, following the same pattern as the TrueNAS sync watchdog (W3).

**Manual recovery sequence**:

1. **Identify the offending vault** (if you have multiple):

   ```bash
   sudo fs_usage -w mds_stores 2>&1 | head -50
   ```

   Look for files being opened repeatedly in a short loop.

2. **Erase and rebuild the Spotlight index for the vault** (usually sufficient):

   ```bash
   sudo mdutil -E "$CLAUDE_BRIDGE_VAULT"
   ```

   This wipes the index for that volume and rebuilds from scratch. mds CPU will spike briefly while it reindexes, then settle. This is the right first step.

3. **Restart mds entirely** (last resort — invalidates ALL indexes system-wide):

   ```bash
   sudo launchctl kickstart -k system/com.apple.metadata.mds
   ```

   Or via the watchdog script:

   ```bash
   scripts/mds-watchdog.sh --restart-mds
   ```

   **Warning**: this triggers a full Spotlight reindex across your entire system. On a large vault it can take hours and will cause sustained high CPU. Only use this if `mdutil -E` doesn't help.

4. **Exclude the vault from Spotlight** (if you don't need Finder search on vault files):

   ```bash
   scripts/macos-exclusions-setup.sh --exclude-vault
   ```

   Or to disable indexing at the volume level:

   ```bash
   sudo mdutil -i off "$CLAUDE_BRIDGE_VAULT"
   ```

**When to ignore vs. when to act**:

- A brief mds CPU spike (< 5 min) right after a large vault import, plugin install, or `git clone` into the vault: **normal — ignore it**.
- Sustained high CPU (> 15 min) on a quiescent vault where nothing has changed: **act — run `sudo mdutil -E "$CLAUDE_BRIDGE_VAULT"`**.
- Finder and Quick Look both broken for > 5 min with mds pegged: **act — reindex or restart mds**.
- The watchdog fires the same notification multiple times over several hours with no improvement: **escalate — consider `--exclude-vault` or `mdutil -i off`**.

## Time Machine backing up ephemeral state

**Symptom**: Time Machine is slow; backups take longer than expected.

**Root cause**: `sync-spool/`, `sync-active/`, `logs/`, `sync-state/` all churn frequently  each Claude Code session touches them. Backing up these ephemeral state directories every hour is wasted I/O.

**Fix**: `tmutil addexclusion -p <path>` on each. `scripts/macos-exclusions-setup.sh` does this automatically (requires Full Disk Access on Terminal.app in System Settings > Privacy & Security; if the script reports failures, grant FDA and re-run).

**What NOT to exclude**: `$CLAUDE_BRIDGE_HOME/projects/` contains session transcripts. You probably want those in backups if you value session history.

## `/usr/bin/perl` path is stable; homebrew paths change

The hooks call `/usr/bin/perl` directly (not `$(command -v perl)`). This is intentional: `/usr/bin/perl` has been at that path on every macOS since at least 10.4. Homebrew's binary paths can move (`/usr/local/bin/` on Intel, `/opt/homebrew/bin/` on Apple Silicon, and Homebrew periodically reorganizes).

If you're on a non-standard macOS where `/usr/bin/perl` isn't present, adjust the hook to use whichever perl is on PATH.

## `claude` binary location

Homebrew on Apple Silicon installs to `/opt/homebrew/bin/claude`. On Intel macOS it's `/usr/local/bin/claude`. Non-homebrew installs (e.g., via npm) end up somewhere else entirely.

The hooks and daemons read `$CLAUDE_BRIDGE_CLAUDE_BIN` from the environment (set via the config template). The install script tries to auto-detect via `command -v claude` and writes the right value into the generated plists.

## System `python3` is 3.9; the MCP SDK needs 3.10+

`/usr/bin/python3` on macOS is 3.9 even on recent macOS versions. The `mcp` SDK requires 3.10 or newer. You need Homebrew python (`/opt/homebrew/bin/python3`) or a venv.

If you use `pyenv` or conda, point `CLAUDE_BRIDGE_PYTHON` at the right binary.

## Full Disk Access on Terminal.app

Some operations (especially `tmutil addexclusion` and reading files outside the user's library) require Full Disk Access for the parent process. If you run `install.sh` from Terminal.app and it complains about permission denied, grant Terminal.app FDA in System Settings > Privacy & Security, close Terminal completely (Cmd+Q), reopen, and re-run.

## Apple sandbox restrictions on LaunchAgents

Some PATH entries Claude Code needs may not be available to the launchd agent. The plist templates set an explicit `EnvironmentVariables.PATH` with homebrew + system locations, which covers the common case.

If you get "command not found" errors in daemon logs, inspect:

```bash
launchctl print gui/$(id -u)/<your.label.here> | grep -A3 EnvironmentVariables
```

And add missing paths to the plist before reloading.

## External-volume detachment

If your `$CLAUDE_BRIDGE_VAULT` is on an external drive, disconnecting the drive while a sync is in progress causes:
- The sync child's preflight check catches it and logs `ABORT: vault volume not mounted`.
- The lockfile is released via trap.
- No vault corruption (the write just doesn't happen).

The reconciliation daemon will retry the affected session once the volume remounts and the next scan runs (up to 5 min later).

## fswatch crashes on directory reparenting / remount events

**Symptom**: `--watch` mode silently stops syncing after an external drive is unmounted and remounted, or after macOS directory reparenting (e.g., iCloud eviction, Spotlight reindex, Time Machine snapshot). The daemon process stays alive but rsync never fires again.

**Root cause**: `fswatch` uses the macOS `FSEvents` API. When a watched directory's underlying volume is remounted or its inode changes (reparenting event), `FSEvents` delivers a `kFSEventStreamEventFlagRootChanged` event — and older versions of fswatch (< 1.17) respond by shutting down their event stream entirely. The stream write end closes, the bash pipe reading it gets EOF, and the sync loop spins silently doing nothing.

**How the supervisor loop recovers**: Since version W3, `--watch` mode wraps the `fswatch` process substitution in an outer supervisor loop:

```
while true; do
  start fswatch
  run inner debounce loop until fswatch pipe closes (EOF detected by timing)
  log "fswatch exited; restarting after backoff"
  sleep (exponential backoff: 5s, 10s, 15s, 20s, 25s, then capped at 30s)
  check vault still mounted
done
```

The inner loop distinguishes "debounce timeout" (fswatch alive, no events for 10 s) from "pipe EOF" (fswatch died) by measuring how quickly `read -t` returns: a return well under `DEBOUNCE_SEC/2` indicates a closed pipe. On detection, it `break`s to the outer supervisor which restarts fswatch after backoff. The backoff counter resets if the session ran for more than 100 s, so a one-off remount event doesn't cause permanently long delays.

Upgrading fswatch to 1.17+ (via `brew upgrade fswatch`) greatly reduces the frequency of these crashes, but the supervisor makes the daemon resilient regardless of fswatch version.

**How the watchdog alerts when rsync stops**: After every successful rsync the daemon writes a Unix timestamp to `~/.claude/sync-state/truenas-sync-heartbeat.txt`. A separate watchdog script (`scripts/truenas-sync-watchdog.sh`) runs every 15 minutes via a dedicated LaunchAgent. It:

1. Reads the heartbeat timestamp.
2. Computes `age = now − last_heartbeat`.
3. If `age > 30 min` **and** the vault has files modified in the last 30 min (live activity), fires a macOS notification:
   > TrueNAS backup stale 35m (12 vault file(s) changed in last 30m)
4. Appends the alert to `logs/truenas-sync-watchdog-alerts.log` for persistent audit.

The two-condition gate (stale heartbeat **and** recent vault activity) avoids false alarms during legitimate quiet periods (overnight, when no Obsidian notes are being written).

## iCloud-synced vault caveats

If your vault is under `~/Library/Mobile Documents/`, iCloud may:
- Evict infrequently-accessed files to the cloud, making them slow to read on first touch.
- Stage changes in a hidden `.evicted` state that's invisible to `ls -la`.

For heavy use of this system, Obsidian Sync is recommended over iCloud. Syncthing is a good open-source alternative.
