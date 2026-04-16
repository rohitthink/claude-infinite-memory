---
tags: [claude, automation, infrastructure]
last-updated: 2026-01-01
---

# Automation Stack

Automation workflows, scheduled tasks, and background daemons  a single
map of "what runs when."

## LaunchAgents (macOS)

| Label | Schedule | Purpose |
|---|---|---|
| `<prefix>.obsidian-reconciliation` | continuous | Catches orphaned session transcripts |
| `<prefix>.obsidian-brain-indexer` | every 5 min | Incremental vault semantic index |
| `<prefix>.vault-compaction` | 1st of month 03:00 | Quarterly distillation |
| `<prefix>.vault-auto-moc` | Sunday 04:00 | Map-of-Content generation |

## Cron Jobs

| Schedule | Command | Purpose |
|---|---|---|

## Workflow Platforms

- <add n8n / Make / Zapier workflows here>

## Related

- [[07 - Claude Knowledge/Skills & Tools Index]]
