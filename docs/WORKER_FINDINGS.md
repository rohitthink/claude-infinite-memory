# W12 Findings: Topic-Map Rule Simulation

**Worker:** W12  
**Date:** 2026-04-17  
**Task:** Verify that the 5-layer containment filter in `hooks/session-start-vault-context.sh` does not inadvertently reject legitimate rules from the shipped `config/vault-topic-map.example.yaml`.

---

## Background

Gemini Tier-2 audit finding #4 stated that 5-of-12 rules in a topic-map yaml would fail the containment filter due to glob-pattern syntax (`**`, `*` as include paths). This raised the concern that the defensive layers added in a prior tier were too aggressive.

## What the repo actually ships

`config/vault-topic-map.example.yaml` contains **5 rules** with **7 unique include paths**, all using direct relative file references. No glob patterns exist:

| Rule | cwd_contains | Include paths |
|------|-------------|---------------|
| ProjectA | `project-a, ProjectA, projectA` | `_Maps/Dashboard.md`, `02 - Projects/ProjectA/Overview.md` |
| ProjectB | `project-b, ProjectB, projectB` | `_Maps/Dashboard.md`, `02 - Projects/ProjectB/Overview.md`, `01 - Clients/ProjectB Client/Brand Voice.md` |
| ProjectC | `project-c, ProjectC, projectC` | `_Maps/Dashboard.md`, `02 - Projects/ProjectC/Overview.md`, `07 - Claude Knowledge/Automation Stack.md` |
| Claude config / hooks | `.claude, Claude-Sync, claude-infinite-memory` | `_Maps/Dashboard.md`, `07 - Claude Knowledge/Automation Stack.md` |
| fallback | `*` | `_Maps/Dashboard.md`, `_Maps/Project Status Map.md` |

## Simulation results

Each rule was simulated against the full 5-layer containment filter using `tests/test-topic-map-containment.sh`. All 5 rules pass all 5 layers with zero rejections.

### Rule-by-rule analysis

| Rule | Layer 1 (abs) | Layer 2 (..) | Layer 3 (Personal) | Layer 4 (realpath) | Layer 5 (resolved Personal) | Result |
|------|--------------|-------------|-------------------|-------------------|------------------------------|--------|
| ProjectA | PASS | PASS | PASS | PASS | PASS | **PASS** |
| ProjectB | PASS | PASS | PASS | PASS | PASS | **PASS** |
| ProjectC | PASS | PASS | PASS | PASS | PASS | **PASS** |
| Claude config | PASS | PASS | PASS | PASS | PASS | **PASS** |
| fallback | PASS | PASS | PASS | PASS | PASS | **PASS** |

None of the paths:
- Start with `/` (would fail Layer 1)
- Contain `../` or `/../` or `/..` (would fail Layer 2)
- Start with `05 - Personal/` (would be silently skipped by Layer 3)
- Resolve outside the vault root via symlink (would fail Layer 4)
- Resolve to a path containing `/05 - Personal/` (would be silently skipped by Layer 5)

### Why the Gemini audit overstated the breakage

The audit's 5/12 claim was based on a **hypothetical 12-rule yaml** that included glob patterns like `**/*.md` as include paths. Those patterns are not present in the repo. The filter would reject `**/*.md` at Layer 2 (the `*` characters don't contain `..`, but glob expansion is not implemented — the raw glob string is passed as a literal filename, which then fails the `[[ -f "$file" ]]` guard and is silently skipped as a missing file, not rejected with a log entry).

This means if a user _did_ write `**/*.md` in their yaml today, the behavior would be: the path is treated as a literal filename, the file doesn't exist, the path is silently skipped. No injection, no error, just no content. This is safe but unintuitive. Glob expansion is a future feature request, not a present security gap.

## Adversarial probe results

8 adversarial probes were run to verify every security boundary:

| Probe | Path | Expected | Result |
|-------|------|---------|--------|
| 1 | `../../../etc/passwd` | REJECTED (Layer 2) | PASS |
| 2 | `/etc/passwd` | REJECTED (Layer 1) | PASS |
| 3 | `05 - Personal/Journal.md` | Silent skip (Layer 3) | PASS |
| 4 | `_Maps/../_Maps/Dashboard.md` | REJECTED (Layer 2) | PASS |
| 5 | `_Maps/evil.md` → `/etc/hosts` symlink | REJECTED (Layer 4) | PASS |
| 6 | `_Maps/Never.md` (nonexistent) | Silent continue | PASS |
| 7 | `_Maps/Dashboard.md` | PASS (valid) | PASS |
| 8 | `02 - Projects/ProjectA/Overview.md` | PASS (spaces) | PASS |

## Remediation decision

- **Remediation A (rule re-phrasing):** Not needed. All shipped rules already pass the filter as-is.
- **Remediation B (glob expansion):** Not needed. The shipped yaml contains no glob patterns. If added speculatively, it would expand the attack surface without a concrete user need. Deferred to a future feature with explicit containment design.

## What was changed

1. **Added** `tests/test-topic-map-containment.sh` — 13-assertion simulation covering all 5 shipped rules and 8 adversarial probes. Exits 0 on all pass.
2. **Added** a verification note in `hooks/session-start-vault-context.sh` header (before `set -uo pipefail`) referencing this test.
3. No changes to the containment logic itself — all 5 layers remain intact and unmodified.

## How to run

```bash
bash tests/test-topic-map-containment.sh
```

Exit 0 = all 13 assertions pass. Non-zero = at least one security boundary or shipped-rule rendering failed.
