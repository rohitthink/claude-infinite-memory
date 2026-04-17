[![tests](https://github.com/rohitthink/claude-infinite-memory/actions/workflows/test.yml/badge.svg)](https://github.com/rohitthink/claude-infinite-memory/actions/workflows/test.yml)

CI runs on Ubuntu; macOS-specific suites (APFS, mds, Spotlight, install-flow)
auto-skip. See `tests/run-all-tests.sh --list` for the full per-suite
platform gating.

# claude-infinite-memory

<!-- CI badge added by W18 -->

Turn your Obsidian vault into Claude Code's permanent, bidirectional
memory. Cross-session continuity, hardened against prompt injection and
secret leakage, multi-device ready.

## Status

v0.2.0 (2026-04-17) — Tier 1 hardening + Tier 2 feature batch + Gemini
Tier-2 remediation merged. See [CHANGELOG.md](CHANGELOG.md) for the full
release arc.

Stable: L1–L4 layers, hooks, MCP server, 27-category redaction, GDPR tooling,
macOS integrations, fswatch watchdog.  
Maturing: SQLite backend (markdown is the default; SQLite is per-component
opt-in).  
Known tradeoff: L3 semantic search requires Ollama running locally; a
hash-fallback exists but returns poor ranking.

## What's in the tree today

- **L1 topic-aware injection** — SessionStart hook reads cwd, matches a rule
  in `vault-topic-map.yaml`, and injects ~9 KB of relevant vault content
  wrapped in `<untrusted-reference>` XML so the model treats it as reference,
  not instructions. A topic-map rule simulator lets you preview matches
  without starting a session.
- **L2 user-profile accumulation** — SessionEnd distills preferences into
  `User Profile.md`. Pending/promote/decay lifecycle with 180-day expiry;
  27-category secret redaction applied before any LLM sees the transcript.
- **L3 semantic search** — Python MCP server over Ollama `nomic-embed-text`
  embeddings; file-type-aware per-file chunk caps so consolidated Historical
  Summaries and MOCs surface coherent multi-chunk matches.
- **L4 compaction + auto-MOC** — monthly 90-day distillation, weekly
  Maps-of-Content synthesis. Proposals are sandboxed under
  `$CLAUDE_BRIDGE_HOME/compaction-sandbox/` with post-hoc path validation.
- **Feature-flagged SQLite backend** — per-component opt-in via
  `CLAUDE_BRIDGE_PREFS_BACKEND=sqlite`, `CLAUDE_BRIDGE_SESSIONLOG_BACKEND=sqlite`,
  `CLAUDE_BRIDGE_TECHLEARN_BACKEND=sqlite`, `CLAUDE_BRIDGE_COMPACTION_CACHE=sqlite`,
  `CLAUDE_BRIDGE_MOC_CACHE=sqlite`. Markdown remains source-of-truth unless
  overridden. The export-to-vault loop re-materialises markdown after every
  staged write so Obsidian stays coherent.
- **GDPR** — `scripts/gdpr-export.sh` produces a tarball; `scripts/gdpr-delete.sh`
  is a tiered erasure tool. See [docs/gdpr.md](docs/gdpr.md).
- **macOS-native** — APFS clone-aware vault snapshots, Spotlight `mds`-watchdog,
  vault-exclusion opt-in. See [docs/macos-specific.md](docs/macos-specific.md).

## Architecture

```
                    +-------------------------------------+
                    |         Your Obsidian Vault         |
                    +------------------+------------------+
                                       |
              read (XML-wrapped)       |       write (XML-ignored)
                                       |
+--------------+          SessionStart |       SessionEnd         +---------------+
|  L1 topic-   | <--- hook injects ----+---- hook spawns -------> |  obsidian-    |
|  aware inj.  |    vault-topic-map.yaml   `claude -p` child      |  sync skill   |
+--------------+                                                  +-------+-------+
                                                                          |
                                                                          v
                                                           +------------------------------+
                                                           |  L2 User Profile             |
                                                           |  pending/promote/decay 180d  |
                                                           +------------------------------+

                            +---------- L3 semantic search ----------+
                            |  indexer -> embeddings -> MCP server    |
                            |  Ollama nomic-embed-text, launchd       |
                            +-----------------------------------------+

                            +---------- L4 compaction ----------+
                            |  monthly: 90-day distillation     |
                            |  weekly:  Maps of Content (MOCs)  |
                            |  sandbox: compaction-sandbox/      |
                            +-----------------------------------+

        +------- feature-flagged SQLite (opt-in) -------+
        |  L2/L3/L4 write to vault-staging.db (WAL)     |
        |  export-to-vault.sh re-materialises markdown   |
        |  Markdown stays source-of-truth by default     |
        +------------------------------------------------+

                 +-------- reconciliation --------+
                 |  orphan transcripts (SIGKILL,  |
                 |  crash, API 500) caught here   |
                 +--------------------------------+
```

See [docs/architecture.md](docs/architecture.md) for the component walkthrough.

## Quick start

```bash
export CLAUDE_BRIDGE_VAULT="$HOME/Obsidian/MyVault"   # adjust to your vault
CLAUDE_BRIDGE_VAULT="$CLAUDE_BRIDGE_VAULT" ./install.sh --yes
# LaunchAgents are installed but NOT bootstrapped — to enable daemons:
#   launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.example.*.plist
```

For a full walkthrough — vault structure, SQLite backend, MCP chunk-cap tuning,
and install verification — see **[docs/quickstart.md](docs/quickstart.md)**.

## Testing

5 test suites live in `tests/`:

```bash
python3 tests/test-mcp-chunk-cap.py
python3 tests/test-mcp-path-resolution.py
python3 tests/test-mcp-xml-wrap.py
bash   tests/test-compaction-sandbox.sh
bash   tests/test-topic-map-containment.sh
```

## Running tests

```bash
tests/run-all-tests.sh           # run everything applicable to your OS
tests/run-all-tests.sh --list    # show what would run + skip reasons
tests/run-all-tests.sh --verbose # stream each suite's output live
tests/run-all-tests.sh --only tests/test-mcp-xml-wrap.py  # run one suite
tests/run-all-tests.sh --skip-macos  # simulate CI (skip macOS-only suites)
```

Exit code is the count of failed suites (0 = all pass). Skipped suites do
not contribute to the exit code.

Covers 7 suites: five in `tests/`, plus `sqlite-backend/test-concurrent-writes.sh`
and `mcp-servers/obsidian-brain/test-server.sh`. New `tests/test-*.sh` and
`tests/test-*.py` files are auto-discovered on the next run.

CI runs the same suites on Ubuntu via `.github/workflows/test.yml` (added by W18).

See [CHANGELOG.md](CHANGELOG.md) for release history.

## Docs

- [docs/quickstart.md](docs/quickstart.md) — fresh-install walkthrough
- [docs/architecture.md](docs/architecture.md) — component-level design
- [docs/threat-model.md](docs/threat-model.md) — threat surface + mitigations
- [docs/gdpr.md](docs/gdpr.md) — personal data disclosure + erasure
- [docs/macos-specific.md](docs/macos-specific.md) — APFS, Spotlight, launchd
- [docs/faq.md](docs/faq.md) — frequently asked questions
- [docs/decision-log.md](docs/decision-log.md) — why we chose what we chose
- [docs/installation.md](docs/installation.md) — advanced install options
- [docs/backup-safety.md](docs/backup-safety.md) — rsync safety rails
- [docs/WORKER_FINDINGS.md](docs/WORKER_FINDINGS.md) — audit-finding index
- [CHANGELOG.md](CHANGELOG.md) — release history

## Security

v0.2.0 merged five Gemini-audit remediations: compaction Write/Edit sandboxing,
topic-map rule simulation, per-request MCP nonce, split read/write MCP path
resolver, and file-type-aware chunk cap. The system also ships 27-category
secret redaction, XML-wrapped untrusted content, realpath path validation,
mkdir-based atomic locks, and `PRAGMA query_only=ON` on the search index.

Full threat surface documented in [docs/threat-model.md](docs/threat-model.md).
For what's stored and how to erase it, see [docs/gdpr.md](docs/gdpr.md).

## License

MIT. See [LICENSE](LICENSE).

---

Built by [rohitthink](https://github.com/rohitthink).
