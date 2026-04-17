---
name: promote-prefs
description: Reviews pending user preference signals in User Profile.md and interactively promotes, discards, or merges them into the main sections. Use this skill when invoked as /promote-prefs, when the user wants to review queued preferences, or after multiple sessions have accumulated pending entries.
---

# Promote Pending Preferences

You are the preference-review gatekeeper for the user's L2 learning profile.

**Vault path**: read from the `CLAUDE_BRIDGE_VAULT` environment variable. If unset, ask the user.

## Purpose

New preference signals detected during sessions land in `## Pending review` of `07 - Claude Knowledge/User Profile.md`. They are NOT authoritative until the user reviews them here. This skill walks through each pending entry one-by-one and moves it to the right section (or discards it).

## Steps

### 1. Load User Profile

Read `$VAULT/07 - Claude Knowledge/User Profile.md`.

If the file does not exist, tell the user: "No User Profile found at the expected path. Run a session first to generate pending entries." and stop.

### 2. Extract Pending entries

Parse the `## Pending review` section. Extract each bullet line (`- TIMESTAMP — "..."`) in order.

If there are no pending entries, tell the user: "No pending preferences to review. You're all caught up!" and stop.

Count the entries and tell the user: "Found N pending preference(s) to review. Let's go through them one by one."

### 3. Review loop — one entry at a time

For each pending entry (oldest first):

**Show the entry clearly:**
```
---
Pending preference:
  TIMESTAMP — "preference text"
  Source: session SESSION_ID, confidence: LEVEL

Options:
  1. Promote → Communication style
  2. Promote → Technical preferences
  3. Promote → Anti-patterns
  4. Promote → Tooling preferences
  5. Merge with an existing entry (you'll specify which)
  6. Discard (this signal is wrong or too vague)
  7. Skip for now (leave in Pending)
  8. Stop reviewing (keep remaining entries pending)
---
```

**Wait for the user's choice.** Do not proceed until you have an answer.

**Execute the choice:**

- **Options 1–4 (Promote to section):**
  1. Read the target section to check for a semantically similar entry (Grep first).
  2. If a similar entry exists: inform the user and ask if they still want a separate entry, or prefer to update the existing one (treat as Merge).
  3. If no similar entry: append a new line to the target section:
     `- preference text (promoted YYYY-MM-DD, last-reinforced: YYYY-MM-DD)`
     where YYYY-MM-DD = today from `date +%Y-%m-%d`.
  4. Remove the entry from `## Pending review`.

- **Option 5 (Merge with existing):**
  1. Ask the user: "Paste or describe the existing entry to merge with."
  2. Grep for that entry in the file.
  3. If found: append a note to the existing line: `; also observed TIMESTAMP (confidence: LEVEL)` and update `last-reinforced: YYYY-MM-DD`.
  4. Remove the entry from `## Pending review`.
  5. If not found: tell the user the entry wasn't found and ask if they want to promote as new instead.

- **Option 6 (Discard):**
  1. Remove the entry from `## Pending review`.
  2. Log: "Discarded: TIMESTAMP — preference text" (printed to chat only, not written to vault).

- **Option 7 (Skip):**
  1. Leave the entry in `## Pending review` unchanged.
  2. Move to the next entry.

- **Option 8 (Stop):**
  1. Leave all remaining entries in `## Pending review` unchanged.
  2. Jump to Step 4 (summary).

After each action (promote/discard/merge), confirm: "Done. Moving to the next entry..."

### 4. Summary

After all entries are processed (or user chose Stop), report:
- How many were promoted (and to which sections)
- How many were merged
- How many were discarded
- How many remain pending

Update the `last-updated:` frontmatter field in User Profile.md to today's date.

## Rules

- **NEVER auto-promote.** Every move to a main section requires explicit user confirmation.
- **NEVER delete the `## Pending review` section header**, even if it's empty after review.
- **Preserve all non-pending content** exactly — only modify the `## Pending review` section and the target section being written to.
- **Use Read/Write/Edit/Grep tools only** — no arbitrary shell commands.
- **One entry at a time** — do not batch-present multiple entries. The user needs to think about each one individually.
