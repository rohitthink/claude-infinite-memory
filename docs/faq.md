# FAQ

### 1. Is my vault content sent to Anthropic?

Only when the SessionEnd hook's `claude -p` child runs  that child sends
the redacted transcript (not the whole vault) plus a prompt asking the
model to extract outcomes. The model then writes back to the vault via
tool calls. The vault itself is never uploaded wholesale.

The L1 SessionStart injection is sent to Anthropic as part of every
session's system context. If you consider your dashboard/project notes
sensitive, note what goes in them.

### 2. Does this work on Linux / Windows?

The hooks and scripts are POSIX bash. Most of the logic is portable; the
LaunchAgent plists are macOS-specific. For Linux, replace LaunchAgents
with systemd user units:

```ini
# ~/.config/systemd/user/obsidian-reconciliation.service
[Unit]
Description=Obsidian reconciliation daemon
After=default.target

[Service]
Type=simple
ExecStart=/home/you/.claude/daemons/reconciliation/obsidian-reconciliation-daemon.sh
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
```

Windows is untested; WSL2 would be the path of least resistance.

### 3. Can I use this without Obsidian?

Yes. The "vault" is just a directory of markdown files. Any editor works.
Obsidian's features you'll miss: wikilinks rendered as navigable, MOCs as
graphs, local search, plugins. The bridge itself doesn't care.

### 4. What about iCloud Drive vs Obsidian Sync vs Syncthing?

- **Obsidian Sync (Standard)**: $5/mo. The recommended option. Encrypted,
  conflict resolution built in, version history. The per-device Session
  Log routing is designed specifically to minimize conflict copies under
  OS-3.
- **iCloud Drive**: free but prone to eviction + hidden `.evicted`
  files. File opens can block on network. Avoid for high-churn vaults.
- **Syncthing**: free + local-first + encrypted. Good for power users
  who don't mind running a sync daemon. Conflict resolution is less
  graceful than Obsidian Sync.
- **Google Drive**: conflict copies multiply fast under the sync model
  bridge uses. Tested briefly; not recommended.

### 5. How much does this cost to run?

The SessionEnd hook spawns `claude -p` per session. Each call sends the
redacted transcript + prompt to the model. For typical sessions this is
on the order of $0.01 to $0.10 depending on transcript size.

L4 compaction runs once a month and costs a few cents per run.

If you want to bound cost, you can:
- Set a smaller `--allowedTools` list in the hooks to discourage long
  tool-use chains in the sync job.
- Use a cheaper model (e.g., Haiku) for the sync job by setting
  `ANTHROPIC_MODEL` in the wrapper env.

### 6. Why not just dump the whole vault into `additionalContext` every session?

Two reasons:
1. **Context budget**: a 57-file vault can easily exceed 100KB. Claude
   Code truncates `additionalContext` silently around ~10KB.
2. **Cost**: every session would pay to read the whole vault. L1 picks
   only what's relevant to the current `cwd`.

L3 (MCP semantic search) fills the gap: if the model needs something not
in the L1 slice, it searches.

### 7. What if I delete a vault file? Does the bridge break?

No. Every read-side component handles missing files gracefully:
- L1 hook skips missing files listed in the topic map.
- MCP server returns an error for missing files (but doesn't crash).
- Indexer garbage-collects DB rows for files that no longer exist.
- Compaction daemon skips if no Session Log.md.

### 8. The MCP server says "Ollama unreachable." Does that matter?

L3 still works but poorly: the indexer falls back to a hash-based pseudo-
embedder (256-dim, deterministic, not semantic). Similarity scores become
"do these files share lots of tokens" rather than "are these
semantically related." Start Ollama and rebuild with `--full-rebuild`
to restore real semantic search.

### 9. How do I turn off L3 if I don't want semantic search?

Don't register the MCP server in `settings.json`. L1, L2, and L4 don't
depend on L3. Just skip step 6 of the install.

### 10. My Session Log is getting polluted by trivial sessions. What do?

Two knobs:
- **MIN_LINES** in the reconciliation daemon (default 8). Bump higher
  (e.g., 30) to ignore short sessions.
- **skill prompt**: the hook's prompt tells the model "be concise; if
  the session was trivial, write nothing." Tune that prompt in
  `hooks/session-end-vault-sync.sh` if the default threshold is too low.

### 11. How do I inspect what's been reconciled?

```bash
cat $CLAUDE_BRIDGE_HOME/sync-state/reconciled.txt
```

That file is an append-only list of session IDs that have been synced.
Safe to delete if you want the daemon to rescan older transcripts on the
next tick (they'll be re-synced, potentially duplicating entries  so
use with care).

### 12. Can I audit every write to the vault?

```bash
tail -f $CLAUDE_BRIDGE_HOME/logs/obsidian-sync.log
```

Every sync logs start/end with session_id, reason, and RC. `REJECTED`
entries show path-traversal attempts or recursion guards tripped.

### 13. What happens if two devices sync the SAME session simultaneously?

They can't: `$CLAUDE_BRIDGE_HOME` is local to each device, so session
transcripts are distinct per device. The global mkdir lock only
serializes writes WITHIN a single device. Between devices, Obsidian Sync
handles conflict resolution on the canonical file (Technical Learnings
etc.), and the per-device Session Log routing avoids that whole class of
race for the high-churn file.

### 14. How do I extend this to a new file type in the vault?

Two steps:
1. Add the file to `config/vault-topic-map.yaml` under the appropriate
   rule so it's injected at SessionStart when relevant.
2. Update `skills/obsidian-sync/SKILL.md` to tell the model when to
   write to the new file type.

### 15. Is there a dry-run mode for the whole pipeline?

Not end-to-end, but each component has one:
- Compaction: `compaction-daemon.sh --dry-run`
- Auto-MOC: `auto-moc-daemon.sh --dry-run`
- Reconciliation: `obsidian-reconciliation-daemon.sh --test-mode`
- Consolidate logs: `consolidate-session-logs.sh --dry-run`
