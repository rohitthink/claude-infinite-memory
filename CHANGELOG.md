# Changelog

All notable changes to claude-infinite-memory are documented here.
Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning 2.0.0](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-04-17

### Release tracks

This release bundles five tracks of work merged over a single day against
the initial public drop at `fdc7596`:

1. **Tier 1 hardening** — convergent audit fixes (secret redaction, L2 lifecycle,
   fswatch watchdog, install safety). Commit `176c40e` plus W1–W4.
2. **Tier 2 feature batch** — SQLite WAL backends (W5–W7, feature-flagged);
   GDPR tooling (W8); APFS snapshots + rsync hardening (W9);
   Spotlight watchdog (W10).
3. **Gemini remediation** — five targeted fixes for findings from a Gemini security
   audit of the Tier 2 batch (W11–W15).

No public interface changes (no removed files, no renamed CLI flags). This is
a purely additive + security-hardening release over the informal v0.1 drop.

### Added

- **SQLite WAL backend for L2 User Profile** (`sqlite-backend/`). Feature-flagged
  via `CLAUDE_BRIDGE_USE_SQLITE=1`; off by default; markdown remains the source
  of truth unless the flag is set. (W5; commits `95c69f7`, `6c9cf6d`)
- **SQLite WAL backend for L3 Meta-Project** (Session Log + Technical Learnings).
  Same `CLAUDE_BRIDGE_USE_SQLITE=1` gate. (W6; commits `c9ba7e0`, `7eb1a54`)
- **SQLite WAL backend for L4 Recall Cache** (compaction proposals + MOC cache).
  Same gate. (W7; commits `e83f245`, `9f127b2`)
- **GDPR disclosure and tooling**: `docs/gdpr.md` describes what is stored and
  retention windows; `scripts/gdpr-export.sh` produces a tarball export;
  `scripts/gdpr-delete.sh` performs tiered erasure. (W8; commits `bc23a46`,
  `208c594`)
- **APFS clone-aware vault snapshots**: `scripts/apfs-snapshot.sh` wraps
  `tmutil localsnapshot`; `scripts/apfs-clone-status.sh` shows clone-aware disk
  usage for the vault. (W9; commits `792f5f9`, `5574a1b`)
- **Spotlight `mds` watchdog daemon**: `scripts/mds-watchdog.sh` monitors vault
  indexing pressure and re-excludes the vault if macOS re-enables indexing.
  Includes a LaunchAgent plist template. (W10; commits `45860dd`, `c55a97c`)
- **`uninstall.sh`** at repo root. Dry-runs by default; pass `--confirm` to
  actually remove hooks, plists, and config. Cleans up LaunchAgents installed
  by `--bootstrap`. (W4; commits `ef6dbac`, `099ef1b`)
- **Compaction proposal sandbox**: each `claude -p` compaction run now executes
  inside a per-run sandbox dir at `$CLAUDE_BRIDGE_HOME/compaction-sandbox/<run-id>/`
  with post-hoc path validation to block prompt-injected writes outside the
  sandbox. (W11; commits `9a0111a`, `09bce99`)
- **Topic-map rule simulator** (`scripts/rule_simulate.py`): dry-runs proposed
  `vault-topic-map.yaml` changes against a representative corpus and diffs
  routing before/after, so authors can verify rules without touching the live
  vault. (W12; commits `f7da862`, `bc2f3db`)
- **Configurable MCP chunk caps** via `CLAUDE_BRIDGE_MAX_CHUNKS_*` env vars.
  File-type-aware defaults shipped: Historical Summaries → 8, MOCs → 6,
  `*.proposed.md` → 5, all others → 2. (W15; commits `6d798ca`, `2565fc1`)

### Changed

- **Secret-pattern redactor expanded from 10 to 27 categories.** New patterns
  cover BIP39 mnemonics (skipped in final cut), Stripe/SendGrid/Twilio keys,
  database DSNs, PEM blocks, and additional bearer-token forms. Applied to
  both transcript injection and MCP tool responses. (W1; commits `d6b70f7`,
  `e30558a`; also `176c40e`)
- **L2 User Profile now uses a pending/promote/decay lifecycle.** New preference
  signals enter a `pending/` gate; they are promoted to canonical only after a
  second confirmation. Entries older than 180 days with no re-confirmation are
  marked `[decayed]` rather than deleted outright. Replaces append-only
  accumulation. (W2; commits `1c23b5c`, `fbcb4e7`)
- **`fswatch` watcher now has a resilient restart loop and backup watchdog
  heartbeat.** The supervisor re-launches `fswatch` on crash with exponential
  backoff; a heartbeat file is touched every 60 s and the watchdog daemon alerts
  if the file goes stale. (W3; commits `f9df3ad`, `14ae132`; also `176c40e`)
- **`install.sh` safety checks.** Now backs up existing config to a timestamped
  file in `~/.claude-bridge-backups/` before overwriting; rejects paths
  containing unsafe characters (spaces, colons, `..`); adds `--bootstrap` flag
  to opt-in to LaunchAgent installation rather than auto-bootstrapping. (W4;
  commits `ef6dbac`, `099ef1b`)
- **`truenas-sync` rsync now uses `--inplace --fuzzy`** and reads
  `CLAUDE_BRIDGE_RSYNC_FLAGS_EXTRA` for per-site overrides; logs clone-stats at
  startup. `parse_would_delete` now fails closed when rsync `--stats` output
  doesn't match any known pattern; `probe_ssh`'s `ssh -G` call is wrapped in a
  5 s timeout with raw TCP fallback. (W9; Gemini findings #1a, #1b; commits
  `792f5f9`, `5574a1b`)
- **MCP path resolver now dispatches on `mode=read|write`.** Read mode enforces
  strict realpath-under-vault; write mode accepts new files with a basename
  charset whitelist (alphanumeric, `-`, `_`, `.`), checking parent-directory
  existence rather than file existence, so first-install new-file creation is no
  longer blocked. (W14; Gemini finding #6; commits `cfdf415`, `448a4d6`)
- **MCP per-file chunk cap is now file-type-aware.** Historical Summaries get 8
  chunks, MOCs get 6, `*.proposed.md` files get 5, everything else gets 2.
  Prevents consolidated master docs from being muted by the global cap. (W15;
  Gemini finding #7; commits `6d798ca`, `2565fc1`)
- **`macos-exclusions-setup.sh` gains `--exclude-vault` opt-in.** Vault
  exclusion from Spotlight and Time Machine is no longer automatic; a flag-file
  is written to make re-creation idempotent across re-runs. (W10; commits
  `45860dd`, `c55a97c`)

### Fixed

- **Compaction subprocess no longer has unconstrained Write/Edit access.**
  Sandboxing + post-hoc path validation now block prompt-injected staging of
  `.zshrc`, `.git/hooks`, or any path outside the per-run compaction sandbox.
  (W11; Gemini finding #2; commits `9a0111a`, `09bce99`)
- **Topic-map regex rules can no longer be silently misrouted.** `rule_simulate.py`
  lets authors diff proposed routing changes before they go live. (W12; Gemini
  finding #4; commits `f7da862`, `bc2f3db`)
- **MCP untrusted-reference XML wrap now uses a per-request nonce.** A unique
  nonce is generated per call and embedded in the closing tag, preventing a
  crafted document from injecting a closing `</untrusted-reference>` that
  escapes the wrapper across requests. (W13; Gemini finding #5; commits
  `ad50635`, `412c444`)
- **`secure_resolve_vault_path` no longer throws on non-existent files.** Split
  into read-strict and write-parent-strict paths; non-existent target under a
  valid parent no longer returns a security error. Unblocks first-install
  new-file creation. (W14; Gemini finding #6; commits `cfdf415`, `448a4d6`)
- **MCP per-file chunk cap no longer mutes consolidated master docs.** Historical
  Summaries and MOCs now surface their relevant chunks rather than being silently
  truncated to the global default. (W15; Gemini finding #7; commits `6d798ca`,
  `2565fc1`)
- **`parse_would_delete` now fails closed** when rsync `--stats` output doesn't
  match any known pattern, preventing accidental deletion if output format
  changes. (W9; Gemini finding #1a; commits `792f5f9`, `5574a1b`)
- **`probe_ssh` `ssh -G` now has a 5 s timeout** with raw TCP fallback, preventing
  hangs on unreachable hosts from blocking the sync daemon indefinitely. (W9;
  Gemini finding #1b; commits `792f5f9`, `5574a1b`)
- **Tier 1 convergent fixes** from Gemini + Grok + Perplexity audits: fswatch
  crash recovery, atomic lock improvements, transcript-path realpath hardening.
  (commit `176c40e`)

### Security

Summary of security-relevant changes for readers skimming for risk:

| Finding | Fix | Worker | Commits |
|---------|-----|--------|---------|
| Gemini #1a: `parse_would_delete` open-failure | Fails closed on unknown rsync output | W9 | `792f5f9` |
| Gemini #1b: `probe_ssh` hangs on unreachable host | 5 s timeout + TCP fallback | W9 | `792f5f9` |
| Gemini #2: compaction subprocess has unconstrained Write/Edit | Per-run sandbox + post-hoc path validation | W11 | `9a0111a` |
| Gemini #4: topic-map rules silently misrouted | `rule_simulate.py` dry-run | W12 | `f7da862` |
| Gemini #5: closing-tag injection across MCP requests | Per-request nonce in XML wrap | W13 | `ad50635` |
| Gemini #6: `secure_resolve_vault_path` throws on new files | Split read-strict / write-parent-strict | W14 | `cfdf415` |
| Gemini #7: chunk cap mutes consolidated master docs | File-type-aware cap with higher limits | W15 | `6d798ca` |
| Tier 1 audit: only 10 secret-pattern categories | Expanded to 27 categories | W1 | `d6b70f7` |

Cross-reference the full audit trail in `docs/WORKER_FINDINGS.md`.

### Docs

- `docs/gdpr.md` — data-protection disclosure: what is stored, retention windows,
  export and deletion procedures. (W8)
- `docs/macos-specific.md` — expanded with APFS snapshot workflow, Spotlight
  `mds` watchdog setup, and vault-exclusion opt-in procedure. (W9, W10)
- `docs/faq.md` — new entries for: mds indexing pressure, APFS clone-aware
  usage, GDPR export/delete flow, chunk-cap tuning via env vars. (W8–W10, W15)
- `docs/decision-log.md` — new entries for: APFS snapshot strategy, L2 decay
  window choice (180 d), SQLite feature-flag rationale. (W5–W7, W9)
- `docs/WORKER_FINDINGS.md` — cumulative audit-finding index; cross-references
  all Gemini findings #1–#7 and their resolutions. (W11–W15)

### Tests

- `tests/test-compaction-sandbox.sh` — verifies that compaction subprocess cannot
  write outside its sandbox dir. (W11; commit `9a0111a`)
- `tests/test-topic-map-containment.sh` — exercises `rule_simulate.py` against
  a known corpus and validates routing decisions. (W12; commit `f7da862`)
- `tests/test-mcp-xml-wrap.py` — checks that per-request nonces differ across
  calls and that injected closing tags are escaped. (W13; commit `ad50635`)
- `tests/test-mcp-path-resolution.py` — covers read-strict, write-parent-strict,
  and new-file creation paths. (W14; commit `cfdf415`)
- `tests/test-mcp-chunk-cap.py` — validates file-type-aware cap values and that
  Historical Summaries / MOCs exceed the global default. (W15; commit `6d798ca`)

### Migration notes

**Opting into the SQLite backend**

The SQLite WAL backends for L2, L3, and L4 are off by default. To enable:

```bash
export CLAUDE_BRIDGE_USE_SQLITE=1
# Then migrate existing markdown data (one-time):
bash sqlite-backend/migrate-from-markdown.sh   # L2 User Profile
bash sqlite-backend/migrate-l4-cache.sh        # L4 Recall Cache
bash sqlite-backend/migrate-meta-project.sh    # L3 Meta-Project
```

Markdown files remain the source of truth unless `CLAUDE_BRIDGE_USE_SQLITE=1`
is set. You can toggle back to markdown at any time by unsetting the variable.

**Re-running `install.sh`**

Existing installs will be prompted before any file is overwritten. A
timestamped backup lands in `~/.claude-bridge-backups/` before the overwrite
proceeds. The `--bootstrap` flag now controls LaunchAgent installation; it is
not applied by default.

**LaunchAgents**

LaunchAgents are not auto-bootstrapped by `install.sh`. Users with pre-Tier-1
installs may have bootstrapped plists manually. `uninstall.sh --confirm` can
remove them cleanly. To inspect what `uninstall.sh` would remove without
making changes, run it without `--confirm` (dry-run is the default).

**Right-to-erasure**

`scripts/gdpr-delete.sh --tier=all --confirm` performs a full wipe of all
stored personal data across L1–L4. See `docs/gdpr.md` for per-tier erasure
options and what each tier stores.

---

## [0.1.0] - 2026-04-16

Initial public release at commit `fdc7596`. L1–L4 learning tiers implemented
as markdown-only, with no SQLite backend, no security hardening beyond basic
XML wrapping and 10-category secret redaction, no uninstall path, and no
GDPR tooling. This tag is retrospectively applied; no annotated tag existed
at the time of the original push. The informal v0.1 drop is documented here
for changelog continuity only.

[Unreleased]: https://github.com/rohitthink/claude-infinite-memory/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/rohitthink/claude-infinite-memory/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rohitthink/claude-infinite-memory/releases/tag/v0.1.0
