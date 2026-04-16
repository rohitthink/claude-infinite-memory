---
name: obsidian-sync
description: Syncs Claude Code session knowledge, project status, technical learnings, and client updates to an Obsidian vault in real time. Use this skill after significant work sessions, when projects change status, when new technical insights are discovered, or when client deliverables are created. Triggers on "sync to obsidian", "update obsidian", "obsidian sync", "save to vault", "update vault", "log session", "update project status", or at the end of any substantial coding/cowork session.
---

# Obsidian Vault Sync

You are syncing Claude Code session data to the user's Obsidian knowledge base.

**Vault path**: read from the `CLAUDE_BRIDGE_VAULT` environment variable (e.g., `~/Documents/Obsidian/MyVault`). If unset, ask the user.

## Vault Structure

```
_Maps/
  Dashboard.md              Master overview (projects, clients, infra links)
  Project Status Map.md     Current state of every project
01 - Clients/               Client profiles and deliverables
02 - Projects/              Project overview pages
03 - Brand Library/         Brand kits, hashtags, calendars
04 - Infrastructure/        n8n, databases, Claude Code, Stack Reference
05 - Personal/              (do not modify)
06 - Templates/             Project Page, Session Log Entry
07 - Claude Knowledge/
  Workflow Patterns.md      How the user works with Claude
  Technical Learnings.md    Hard-won debugging insights
  Skills & Tools Index.md   Custom skills registry
  Session Log.md            Major session outcomes
  Automation Stack.md       Automation workflows, scheduled tasks
  User Profile.md           Accumulated user preferences (L2)
```

## Objective

Detect what changed in this session and update the relevant Obsidian notes. Every update must preserve existing content and add to it — never overwrite or delete prior entries.

## Steps

### 1. Assess what happened in this session

Read the conversation context and determine which categories apply:

- [ ] **Session milestone** A significant session just completed (shipped feature, fixed bug, built pipeline, delivered to client)
- [ ] **Project status change** A project moved between states (planning, development, active, completed)
- [ ] **New technical learning** A debugging insight, pattern, or gotcha worth remembering
- [ ] **New client deliverable** A document, analysis, or asset was created for a client
- [ ] **Infrastructure change** Automation workflow added/modified, new service connected, credentials changed
- [ ] **New skill or automation** A custom skill was created or an automation workflow was set up
- [ ] **Brand/content update** New brand kit, caption bank, or content strategy

### 2. Update files based on what changed

For each applicable category, read the target file first, then append or update:

#### Session Milestone → `07 - Claude Knowledge/Session Log.md`
Append a new entry using this format:
```markdown
## YYYY-MM-DD — {{Brief Title}}
- **Goal**: {{What was the session trying to accomplish?}}
- **Outcome**: {{What was achieved? Include numbers if relevant.}}
- **Key decisions**: {{Any non-obvious choices made and why}}
- **Learnings**: {{Anything worth remembering for future sessions}}
```

#### Project Status Change → `_Maps/Project Status Map.md`
Update the relevant project's status, description, and "Next" items. Move between sections (Active, In Development, Planning, Completed) if the state changed.

Also update the project's own `02 - Projects/<name>/Overview.md` status callout.

#### New Technical Learning → `07 - Claude Knowledge/Technical Learnings.md`
Append a new numbered entry:
```markdown
## N. {{Title}}
**Problem**: {{What went wrong or was confusing}}
**Solution**: {{What fixed it}}
**Applies to**: {{When this knowledge is relevant}}
```

#### New Client Deliverable → `01 - Clients/<name>/Profile.md`
Add the deliverable to the client's deliverables table. If the client doesn't have a profile yet, create one using the pattern from existing profiles.

#### Infrastructure Change → `04 - Infrastructure/<relevant>.md`
Update the specific infrastructure note. If it's a new service, create a new file following existing patterns.

Also update `04 - Infrastructure/Stack Reference.md` and `04 - Infrastructure/Credentials Index.md` if new services or accounts were added.

#### New Skill or Automation → `07 - Claude Knowledge/Skills & Tools Index.md`
Add the skill to the appropriate table with trigger phrases and description.

If it's an automation workflow, also update `07 - Claude Knowledge/Automation Stack.md`.

#### Brand/Content Update → `03 - Brand Library/<relevant>.md`
Update the brand kit, caption bank, or create new brand library entries.

### 3. Update Dashboard if needed

If a new project or client was added, update `_Maps/Dashboard.md` to include it in the relevant table.

### 4. Update frontmatter

On every file you modify, update the `last-updated` field to today's date:
```yaml
last-updated: YYYY-MM-DD
```

### 5. Cross-link

Ensure new notes are linked from related notes using `[[wikilinks]]`. Every new note should be reachable from at least 2 other notes.

### 6. Report

After syncing, output a brief summary:
```
Obsidian Sync Complete:
- Updated: [list of files modified]
- Created: [list of new files, if any]
- Connections: [new wikilinks added]
```

## File Format Rules

All Obsidian files MUST follow these conventions:

1. **YAML frontmatter** on every file:
   ```yaml
   ---
   tags: [relevant, tags]
   status: active|development|completed|planning|experimental  # for projects
   last-updated: YYYY-MM-DD
   ---
   ```

2. **Wikilinks** for cross-references: `[[folder/filename|Display Name]]`

3. **Tags**: Use `#project`, `#client`, `#active`, `#completed`, `#infrastructure`, `#learning`, `#automation`

4. **Callouts** for status:
   ```markdown
   > [!success] Status message
   > [!warning] Warning message
   > [!info] Info message
   ```

5. **Never** store actual passwords, tokens, or API keys — only service names and where to find credentials

## Constraints

- Do NOT modify `05 - Personal/` — that's private
- Do NOT delete or overwrite existing entries — always append
- Do NOT create duplicate notes — check if a file exists first
- Do NOT store secrets (tokens, passwords, API keys) — only reference where they live
- ALWAYS read a file before writing to it
- ALWAYS preserve existing wikilinks and frontmatter tags (add to them, don't replace)
- Keep entries concise — this is a knowledge graph, not a journal
