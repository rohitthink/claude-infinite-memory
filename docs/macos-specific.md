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
