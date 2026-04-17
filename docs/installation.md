# Installation

Step-by-step install for a new machine. macOS is the primary target.

## Prerequisites

1. **Claude Code CLI v2.1.53+**. Install via Homebrew: `brew install anthropic/claude/claude` (or via the Anthropic download). Verify: `claude --version`.
2. **Obsidian** with a vault. Any layout works, but the hooks assume the
   folder structure shown in `vault-template/`  copy the template into an
   empty vault to get the canonical layout.
3. **jq**, **perl**, and **sqlite3**. All three ship with macOS.
4. **Python 3.10+** with the `mcp` SDK (only needed if you want L3
   semantic search). On macOS: `brew install python3` then
   `/opt/homebrew/bin/python3 -m pip install --break-system-packages mcp`.
5. **Ollama** (only for L3): `brew install ollama` then
   `ollama pull nomic-embed-text`. Optional  L3 falls back to a hash
   pseudo-embedder if Ollama is unreachable.
6. **fswatch** (only for the remote backup daemon): `brew install fswatch`.

## 1. Clone the repo

```bash
git clone https://github.com/rohitthink/claude-infinite-memory.git
cd claude-infinite-memory
```

## 2. Configure

Copy the config template and edit it with your paths:

```bash
cp config.template.sh ~/.claude/claude-infinite-memory.env
$EDITOR ~/.claude/claude-infinite-memory.env
```

At minimum, set:

- `CLAUDE_BRIDGE_VAULT`  absolute path to your Obsidian vault
- `CLAUDE_BRIDGE_LABEL_PREFIX`  a reverse-DNS prefix for your LaunchAgents
  (e.g. `com.github.yourhandle`)

Source it so the rest of this session uses the values:

```bash
source ~/.claude/claude-infinite-memory.env
```

## 3. Run the installer

```bash
./install.sh
```

The script will:
- Run pre-flight safety checks (existing install, Claude CLI presence, path safety, admin warning)
- Validate your vault path exists
- Back up any existing config/hooks to `~/.claude-bridge-backups/<timestamp>/` before overwriting
- Copy hooks, scripts, skills, and the MCP server into `$CLAUDE_BRIDGE_HOME`
- Apply macOS exclusions (Spotlight, Time Machine)
- Initialize the SQLite backend (optional; empty DB)
- Run a smoke test of the SessionStart hook
- Install LaunchAgent plists to `~/Library/LaunchAgents/` (NOT bootstrapped by default)
- Merge hook entries into `~/.claude/settings.json`
- Print a summary with next steps

You can safely re-run `install.sh`; it detects existing installs and prompts for
`overwrite / skip / abort` before touching files.

### Installer flags

| Flag | Effect |
|------|--------|
| `--bootstrap` | Also run `launchctl bootstrap` after installing plists |
| `--yes` | Suppress the admin/root confirmation prompt |

### Enabling LaunchAgents (opt-in)

By default the installer only writes plist files; it does **not** register them
with launchd. This prevents silently starting background processes on machines
where you have not consented. To enable the daemons, run the commands printed at
the end of the installer, or re-run with `--bootstrap`:

```bash
./install.sh --bootstrap
```

Or manually:

```bash
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.example.obsidian-reconciliation.plist
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.example.vault-compaction.plist
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.example.vault-auto-moc.plist
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.example.obsidian-brain-indexer.plist
```

(Replace `com.example` with your `CLAUDE_BRIDGE_LABEL_PREFIX`.)

### Backups

Before any file is overwritten, a copy is saved to:

```
~/.claude-bridge-backups/<YYYYMMDD-HHMMSS>/
```

The installer prints the backup path at the end. To restore a file:

```bash
cp ~/.claude-bridge-backups/<timestamp>/<filename> <original-path>
```

To discard the backup once you are satisfied:

```bash
rm -rf ~/.claude-bridge-backups/<timestamp>
```

## 4. Wire up Claude Code settings

### Hooks

Add these entries to `~/.claude/settings.json` (merge into the existing
`hooks` block):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "command": "/Users/YOUR_USER/.claude/hooks/session-start-vault-context.sh"
      }
    ],
    "SessionEnd": [
      {
        "command": "/Users/YOUR_USER/.claude/hooks/session-end-vault-sync.sh"
      }
    ]
  }
}
```

### MCP server (optional, for L3)

Merge the snippet from `mcp-servers/obsidian-brain/settings-snippet.example.json`
into `~/.claude/settings.json`.

Restart Claude Code.

## 5. Copy the vault template (if starting fresh)

```bash
cp -R vault-template/* "$CLAUDE_BRIDGE_VAULT/"
```

Skip this step if you already have an Obsidian vault you want to use.

## 6. Build the initial semantic index (optional, for L3)

```bash
/opt/homebrew/bin/python3 "$CLAUDE_BRIDGE_HOME/mcp-servers/obsidian-brain/indexer.py" --full-rebuild
```

Expect a few seconds for a small vault. The launchd daemon keeps it fresh
every 5 minutes thereafter.

## 7. Verify

Run the smoke test:

```bash
bash -n "$CLAUDE_BRIDGE_HOME/hooks/session-start-vault-context.sh"
echo '{}' | "$CLAUDE_BRIDGE_HOME/hooks/session-start-vault-context.sh" | jq .
```

You should see a JSON payload with `hookSpecificOutput.additionalContext`
containing your vault reference context.

Start a new Claude Code session and ask: "What's in the Obsidian Vault
Reference Context I was given?" The model should describe the injected
content.

## 8. Configure multi-device sync (optional)

If you use Claude Code on multiple machines:

- Install the repo on each device.
- Use Obsidian Sync (recommended), Syncthing, or iCloud  see
  `README.md#multi-device-sync` for tradeoffs.
- Per-device Session Logs are automatic (each device writes to
  `Session Log - <hostname>.md`). Run
  `scripts/consolidate-session-logs.sh` weekly to merge them.

## 9. Harden the remote-backup SSH key (recommended)

If you use the `truenas-sync` daemon, the Mac-mini (or whichever host
runs the sync) pushes via `ssh` with `rsync --delete`. If that key can
also run arbitrary shell commands, a compromise of the source host turns
into a root compromise of your NAS. Wrap the key with a forced command
so it can *only* drive the rsync protocol to the specific backup dataset.

### Option A — `rrsync` helper (rsync 3 on server, rsync 3 client)

If BOTH sides run rsync 3.x, the canonical approach is the `rrsync`
helper that ships with rsync. On the server (e.g. TrueNAS SCALE) as
root, check that `/usr/bin/rrsync` exists, then in
`/root/.ssh/authorized_keys` wrap the sync key's line:

```
command="/usr/bin/rrsync -wo /mnt/Storage/obsidian-backups/vault",no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc ssh-ed25519 AAAA... comment
```

`-wo` means write-only (allows `--delete` within the dir). After this,
`ssh host true` or `ssh host any-other-cmd` will fail with `rrsync error:
SSH_ORIGINAL_COMMAND does not run rsync`, but the `truenas-sync` daemon's
rsync pushes continue to work.

### Option B — Fixed rsync option-string (openrsync client / mismatched rsync versions)

Heads-up: **macOS ships openrsync, not GNU rsync 3.** openrsync's server
protocol sends extra long options (notably `--dirs`) that older `rrsync`
versions (rsync ≤ 3.2.7) do not include in their allow-list, so the
`rrsync` approach above will reject the Mac-mini's connection with
`rrsync error: invalid rsync-command syntax or options`.

For the openrsync → rsync 3 case, use an explicit option-string forced
command instead. First, capture exactly what options *your* client sends
(run this on the client):

```bash
rsync -n -a --delete --stats \
  -e 'ssh -v -o BatchMode=yes' \
  /path/to/source/ host:/path/to/dest/ 2>&1 \
  | grep 'Sending command:'
```

You'll see a line like:

```
debug1: Sending command: rsync --server --delete-before -g -l -n -o -p -D -r -t --dirs . /mnt/Storage/obsidian-backups/vault/
```

Drop the `-n` (dry-run-only) from that string, then write the forced
command so it accepts exactly that invocation:

```
command="rsync --server --delete-before -g -l -n -o -p -D -r -t --dirs . /mnt/Storage/obsidian-backups/vault/",no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc ssh-ed25519 AAAA... comment
```

This is more brittle than `rrsync` (any change to the client's rsync
flags requires updating the forced command), but it correctly admits
openrsync's option set.

### Recovery

**Always keep the SSH session alive while testing** and keep a timestamped
backup of `authorized_keys` in the same directory
(`/root/.ssh/authorized_keys.bak-YYYYMMDD`). If the forced command
breaks, the only recovery paths are:

1. An already-open SSH session (from before the change) that has shell
   access — run `cp authorized_keys.bak-YYYYMMDD authorized_keys`.
2. The NAS's admin web UI shell / IPMI / physical console.

The forced command intercepts scp, sftp, and all interactive access, so
you cannot revert through the sync key once the change is deployed.

## Troubleshooting

- **SessionStart hook exits silently**: run it with `set -x` prepended and
  a mock payload. Common causes: `CLAUDE_BRIDGE_VAULT` not set in the env
  Claude Code sees, or the vault directory is unmounted.
- **SessionEnd hook spawns child that immediately dies**: check
  `$CLAUDE_BRIDGE_HOME/logs/obsidian-sync.log`. Most failures log there.
- **launchd Error 5 on bootstrap**: the plist must live on the boot drive,
  NOT an external volume. See `docs/macos-specific.md`.
- **MCP server can't find the index**: confirm `indexer.py --full-rebuild`
  ran and check `$CLAUDE_BRIDGE_HOME/logs/obsidian-brain-indexer.log`.
- **`rrsync error: invalid rsync-command syntax or options`**: your
  client is sending options the server-side `rrsync` does not allow
  (commonly `--dirs` from openrsync). See §9 Option B above for the
  fixed-option-string forced-command pattern.
- **`truenas-sync.log` shows `ABORT: source sanity check failed`**: the
  guard rightfully refused to proceed. Causes: vault unmounted, vault
  emptied by mistake, or a pending rename. Investigate before re-running.
  For intentional wipes, pass `--force-delete`. Env vars
  `MIN_MD_FILES`, `MIN_VAULT_BYTES`, `MAX_DELETE_PCT` tune the thresholds.
