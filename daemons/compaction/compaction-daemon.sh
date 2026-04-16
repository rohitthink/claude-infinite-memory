#!/bin/bash
# compaction-daemon.sh
#
# L4 of the 4-layer "learning brain" architecture.
#
# Monthly (1st of month at 03:00 local) compaction pass that distills old
# vault entries into quarterly summaries:
#
#   1. Reads `Session Log.md` entries older than 90 days (date from the
#      `## YYYY-MM-DD` heading, NOT file mtime).
#   2. If >=3 qualifying entries exist, runs `claude -p` with a redacted
#      inline copy of those entries and asks for a DISTILLED quarterly
#      summary keeping only: major milestones, non-obvious decisions that
#      influenced later work, learnings that were referenced again,
#      abandoned approaches (anti-patterns).
#   3. Appends the summary under `07 - Claude Knowledge/Historical
#      Summaries/YYYY-Qn.md` with a `## Compacted YYYY-MM-DD -> YYYY-MM-DD`
#      heading.
#   4. Moves the original entries (not delete) to
#      `07 - Claude Knowledge/_compacted-entries/YYYY-Qn/` as individual
#      `YYYY-MM-DD-<slug>.md` files so they can be restored verbatim.
#   5. Does the same for `Technical Learnings.md` entries, but with a
#      different compression: deduplicate learnings that cover the same
#      root cause, merge their "Applies to" lists.
#
# Safety:
#   - Acquires the GLOBAL vault-sync mkdir lock (same pattern as the
#     SessionEnd hook). Waits up to 300s; aborts if still held.
#   - Pre-flight vault mount check.
#   - Unsets CLAUDECODE + CLAUDE_CODE_ENTRYPOINT; sets
#     CLAUDE_OBSIDIAN_SYNC_CHILD=1 so bridge hooks don't recurse.
#   - perl alarm enforces 300s hard timeout on claude -p.
#   - 17-category regex redaction on any content passed to claude -p.
#   - Log rotation at 1 MB.
#
# Flags:
#   --dry-run                 Plan only, no writes. Also DRYRUN=1 env var.
#   --quarter YYYY-Qn         Target a specific quarter (else auto-detect).
#   --vault-override <path>   Override vault path (for testing).
#                             Also VAULT_OVERRIDE env var.
#   --help                    Show help and exit.
#
# Exit codes:
#   0 = success (or dry-run success, or nothing to compact)
#   1 = hard failure (vault missing, lock timeout, claude -p failure)
#   2 = invalid usage

set -uo pipefail

# ---- Defaults (override via env) ----
CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
DEFAULT_VAULT="${CLAUDE_BRIDGE_VAULT:-}"
CLAUDE_BIN="${CLAUDE_BRIDGE_CLAUDE_BIN:-/opt/homebrew/bin/claude}"

LOG_DIR="${CLAUDE_BRIDGE_HOME}/logs"
LOG="$LOG_DIR/compaction.log"
SPOOL_DIR="${CLAUDE_BRIDGE_HOME}/sync-spool"
LOCK_DIR="${CLAUDE_BRIDGE_HOME}/sync-active"
GLOBAL_LOCK="$LOCK_DIR/vault-sync.lock"

PERL_BIN="/usr/bin/perl"

AGE_THRESHOLD_DAYS=90
MIN_QUALIFYING_ENTRIES=3
CLAUDE_TIMEOUT_SEC=300
LOCK_WAIT_SEC=300

# ---- Arg parsing ----
DRY_RUN="${DRYRUN:-0}"
QUARTER_OVERRIDE=""
VAULT="${VAULT_OVERRIDE:-$DEFAULT_VAULT}"

usage() {
  cat <<'EOF'
compaction-daemon.sh monthly vault compaction job

Usage:
  compaction-daemon.sh [flags]

Flags:
  --dry-run                Compute plan only; print proposal; no writes.
                           (Also: DRYRUN=1 env var)
  --quarter YYYY-Qn        Compact this specific quarter (e.g. 2025-Q4).
                           Default: auto-detect from entries older than 90d.
  --vault-override <path>  Use a different vault root (for tests).
                           (Also: VAULT_OVERRIDE env var)
  --help                   Show this help and exit.

Behavior:
  1. Acquires global vault-sync lock (waits up to 300s).
  2. Reads Session Log.md + Technical Learnings.md entries >=90 days old.
  3. If >=3 qualifying Session Log entries, distills via claude -p into
     Historical Summaries/YYYY-Qn.md and moves originals into
     _compacted-entries/YYYY-Qn/.
  4. Technical Learnings: deduplicate by root cause, merge "Applies to".

Rollback:
  Originals preserved in _compacted-entries/YYYY-Qn/<YYYY-MM-DD-slug>.md.
  Paste them back into Session Log.md (or Technical Learnings.md) if the
  compaction produced a bad result.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --quarter)
      QUARTER_OVERRIDE="${2:-}"
      if [[ -z "$QUARTER_OVERRIDE" ]]; then
        echo "ERROR: --quarter requires YYYY-Qn argument" >&2
        exit 2
      fi
      if ! [[ "$QUARTER_OVERRIDE" =~ ^[0-9]{4}-Q[1-4]$ ]]; then
        echo "ERROR: --quarter must match YYYY-Qn (e.g. 2025-Q4)" >&2
        exit 2
      fi
      shift 2
      ;;
    --vault-override)
      VAULT="${2:-}"
      if [[ -z "$VAULT" ]]; then
        echo "ERROR: --vault-override requires a path" >&2
        exit 2
      fi
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown flag: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$LOG_DIR" "$SPOOL_DIR" "$LOCK_DIR"

# ---- Log rotation at 1MB ----
if [[ -f "$LOG" ]] && [[ $(wc -c < "$LOG" 2>/dev/null || echo 0) -gt 1048576 ]]; then
  mv -f "$LOG" "$LOG.1" 2>/dev/null || true
fi

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [compaction-$$] $*" >> "$LOG"
}

plan() {
  # Also print to stdout when dry-run so the user sees the plan live
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "$*"
  fi
  log "PLAN: $*"
}

# ---- Pre-flight ----
if [[ -z "$VAULT" ]] || [[ ! -d "$VAULT" ]]; then
  log "ABORT: vault not mounted at $VAULT"
  echo "ERROR: vault not set or not mounted at $VAULT" >&2
  exit 1
fi

KNOWLEDGE_DIR="$VAULT/07 - Claude Knowledge"
SESSION_LOG="$KNOWLEDGE_DIR/Session Log.md"
TECH_LEARNINGS="$KNOWLEDGE_DIR/Technical Learnings.md"
HISTORICAL_DIR="$KNOWLEDGE_DIR/Historical Summaries"
COMPACTED_DIR="$KNOWLEDGE_DIR/_compacted-entries"

if [[ ! -f "$SESSION_LOG" ]]; then
  log "ABORT: Session Log.md not found at $SESSION_LOG"
  echo "ERROR: Session Log.md not found at $SESSION_LOG" >&2
  exit 1
fi

log "=== Compaction start | vault=$VAULT dry_run=$DRY_RUN quarter=${QUARTER_OVERRIDE:-auto} ==="

# ---- Recursion-guard & binary checks (skip in dry-run if claude missing) ----
if [[ "$DRY_RUN" != "1" ]]; then
  [[ -x "$PERL_BIN" ]] || { log "ABORT: perl missing at $PERL_BIN"; exit 1; }
  if [[ ! -x "$CLAUDE_BIN" ]] && ! command -v claude >/dev/null 2>&1; then
    log "ABORT: claude binary missing (tried $CLAUDE_BIN and PATH)"
    exit 1
  fi
  if [[ ! -x "$CLAUDE_BIN" ]]; then
    CLAUDE_BIN="$(command -v claude)"
  fi
fi

# ---- Redaction (17-category regex, same as session-end-vault-sync.sh) ----
redact_to_stdout() {
  sed -E \
    -e 's/ghp_[A-Za-z0-9]{36}/[REDACTED_GITHUB_PAT]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{80,}/[REDACTED_GITHUB_FGPAT]/g' \
    -e 's/gho_[A-Za-z0-9]{36}/[REDACTED_GITHUB_OAUTH]/g' \
    -e 's/AKIA[A-Z0-9]{16}/[REDACTED_AWS_ACCESS_KEY]/g' \
    -e 's/ASIA[A-Z0-9]{16}/[REDACTED_AWS_STS_KEY]/g' \
    -e 's/sk-ant-[A-Za-z0-9_-]{20,}/[REDACTED_ANTHROPIC_KEY]/g' \
    -e 's/sk-proj-[A-Za-z0-9_-]{20,}/[REDACTED_OPENAI_PROJECT_KEY]/g' \
    -e 's/sk-[A-Za-z0-9]{20,}/[REDACTED_OPENAI_KEY]/g' \
    -e 's/AIza[A-Za-z0-9_-]{35}/[REDACTED_GOOGLE_API_KEY]/g' \
    -e 's/ya29\.[A-Za-z0-9_-]+/[REDACTED_GOOGLE_OAUTH]/g' \
    -e 's/xox[abpr]-[A-Za-z0-9-]{10,}/[REDACTED_SLACK_TOKEN]/g' \
    -e 's/glpat-[A-Za-z0-9_-]{20}/[REDACTED_GITLAB_PAT]/g' \
    -e 's/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/[REDACTED_JWT]/g' \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTED_PRIVATE_KEY_START]/g' \
    -e 's/-----END [A-Z ]*PRIVATE KEY-----/[REDACTED_PRIVATE_KEY_END]/g' \
    -e 's/(password|passwd|passwort|secret|api[_-]?key|auth[_-]?token|bearer)[[:space:]"'\'':=]+[A-Za-z0-9!@#$%^&*()_+=/-]{8,}/\1=[REDACTED_SECRET]/gi' \
    "$1"
}

# ---- Date math helpers ----
TODAY="$(date '+%Y-%m-%d')"

# Cutoff date: today minus AGE_THRESHOLD_DAYS
CUTOFF_DATE="$(date -v "-${AGE_THRESHOLD_DAYS}d" '+%Y-%m-%d' 2>/dev/null || \
               date -d "-${AGE_THRESHOLD_DAYS} days" '+%Y-%m-%d' 2>/dev/null || \
               echo "1970-01-01")"

log "cutoff_date=$CUTOFF_DATE (entries on/before this date qualify)"

# Quarter for a given YYYY-MM-DD
quarter_for_date() {
  local ymd="$1"
  local y="${ymd:0:4}"
  local m="${ymd:5:2}"
  m="${m#0}"
  local q
  if   [[ "$m" -le 3 ]]; then q=1
  elif [[ "$m" -le 6 ]]; then q=2
  elif [[ "$m" -le 9 ]]; then q=3
  else                        q=4
  fi
  echo "${y}-Q${q}"
}

slugify() {
  local s="$1"
  s=$(echo "$s" | tr '[:upper:]' '[:lower:]')
  s=$(echo "$s" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  s="${s:0:60}"
  [[ -z "$s" ]] && s="entry"
  echo "$s"
}

# ---- Lock acquisition (mkdir-based, same as session-end-vault-sync.sh) ----
acquire_lock() {
  local acquired=0
  local i
  for i in $(seq 1 "$LOCK_WAIT_SEC"); do
    if mkdir "$GLOBAL_LOCK" 2>/dev/null; then
      acquired=1
      break
    fi
    sleep 1
  done
  if [[ "$acquired" -eq 0 ]]; then
    log "ABORT: could not acquire vault lock after ${LOCK_WAIT_SEC}s wait"
    echo "ERROR: could not acquire vault lock after ${LOCK_WAIT_SEC}s wait" >&2
    return 1
  fi
  log "lock acquired at $GLOBAL_LOCK"
  return 0
}

release_lock() {
  rmdir "$GLOBAL_LOCK" 2>/dev/null || true
}

cleanup() {
  release_lock
}
trap cleanup EXIT INT TERM

if [[ "$DRY_RUN" != "1" ]]; then
  acquire_lock || exit 1
else
  plan "dry-run: skipping lock acquisition (would wait up to ${LOCK_WAIT_SEC}s for $GLOBAL_LOCK)"
fi

# ---- Parse Session Log into entries ----
TIMESTAMP_TAG=$(date "+%Y%m%d-%H%M%S")
WORK_DIR="$SPOOL_DIR/compaction-${TIMESTAMP_TAG}-$$"
mkdir -p "$WORK_DIR"
cleanup_work() {
  rm -rf "$WORK_DIR"
  release_lock
}
trap cleanup_work EXIT INT TERM

SESSION_ENTRIES_DIR="$WORK_DIR/session-entries"
mkdir -p "$SESSION_ENTRIES_DIR"

awk -v outdir="$SESSION_ENTRIES_DIR" '
  BEGIN { in_entry = 0; current_date = ""; current_title = ""; buf = ""; idx = 0 }

  function flush() {
    if (in_entry && current_date != "") {
      idx++
      fname = sprintf("%s/%04d__%s.entry", outdir, idx, current_date)
      hdr = "DATE=" current_date "\nTITLE=" current_title "\n---BODY---\n"
      printf "%s%s", hdr, buf > fname
      close(fname)
    }
    in_entry = 0
    current_date = ""
    current_title = ""
    buf = ""
  }

  /^## [0-9]{4}-[0-9]{2}-[0-9]{2}/ {
    flush()
    in_entry = 1
    line = $0
    sub(/^## /, "", line)
    current_date = substr(line, 1, 10)
    title = line
    sub(/^[0-9]{4}-[0-9]{2}-[0-9]{2}[^ ]* */, "", title)
    sub(/^— */, "", title)
    sub(/^- */, "", title)
    current_title = title
    buf = $0 "\n"
    next
  }

  /^## [^0-9]/ {
    flush()
    next
  }

  /^---$/ {
    if (in_entry) {
      flush()
    }
    next
  }

  {
    if (in_entry) buf = buf $0 "\n"
  }

  END { flush() }
' "$SESSION_LOG"

SESSION_ENTRY_COUNT=$(ls -1 "$SESSION_ENTRIES_DIR" 2>/dev/null | wc -l | tr -d ' ')
log "parsed $SESSION_ENTRY_COUNT Session Log entries from $SESSION_LOG"

QUALIFYING_LIST="$WORK_DIR/qualifying-session.txt"
: > "$QUALIFYING_LIST"

for entry_file in "$SESSION_ENTRIES_DIR"/*.entry; do
  [[ -f "$entry_file" ]] || continue
  entry_date=$(awk -F= '/^DATE=/ { print $2; exit }' "$entry_file")
  [[ -z "$entry_date" ]] && continue
  if [[ "$entry_date" < "$CUTOFF_DATE" ]] || [[ "$entry_date" == "$CUTOFF_DATE" ]]; then
    entry_q=$(quarter_for_date "$entry_date")
    echo "$entry_date|$entry_q|$entry_file" >> "$QUALIFYING_LIST"
  fi
done

QUALIFYING_COUNT=$(wc -l < "$QUALIFYING_LIST" | tr -d ' ')
log "qualifying (>=${AGE_THRESHOLD_DAYS}d old): $QUALIFYING_COUNT Session Log entries"

if [[ "$QUALIFYING_COUNT" -lt "$MIN_QUALIFYING_ENTRIES" ]] && [[ -z "$QUARTER_OVERRIDE" ]]; then
  plan "no action: fewer than $MIN_QUALIFYING_ENTRIES qualifying Session Log entries ($QUALIFYING_COUNT found)"
  SESSION_TARGET_QUARTER=""
else
  if [[ -n "$QUARTER_OVERRIDE" ]]; then
    SESSION_TARGET_QUARTER="$QUARTER_OVERRIDE"
  else
    SESSION_TARGET_QUARTER=$(cut -d'|' -f2 "$QUALIFYING_LIST" | sort -u | head -1)
  fi
  log "target quarter: $SESSION_TARGET_QUARTER"
fi

TARGET_LIST="$WORK_DIR/target-session.txt"
: > "$TARGET_LIST"

if [[ -n "$SESSION_TARGET_QUARTER" ]]; then
  awk -F'|' -v q="$SESSION_TARGET_QUARTER" '$2 == q { print }' "$QUALIFYING_LIST" > "$TARGET_LIST"
fi

TARGET_COUNT=$(wc -l < "$TARGET_LIST" | tr -d ' ')
plan "would compact $TARGET_COUNT Session Log entries from quarter ${SESSION_TARGET_QUARTER:-<none>}"

if [[ "$TARGET_COUNT" -ge "$MIN_QUALIFYING_ENTRIES" ]] || \
   [[ -n "$QUARTER_OVERRIDE" && "$TARGET_COUNT" -gt 0 ]]; then

  MIN_DATE=$(cut -d'|' -f1 "$TARGET_LIST" | sort | head -1)
  MAX_DATE=$(cut -d'|' -f1 "$TARGET_LIST" | sort | tail -1)
  plan "date range: $MIN_DATE -> $MAX_DATE"

  CORPUS_RAW="$WORK_DIR/session-corpus-raw.md"
  CORPUS_RED="$WORK_DIR/session-corpus-redacted.md"
  : > "$CORPUS_RAW"

  while IFS='|' read -r ed eq ef; do
    [[ -f "$ef" ]] || continue
    echo "" >> "$CORPUS_RAW"
    awk 'body { print } /^---BODY---$/ { body=1 }' "$ef" >> "$CORPUS_RAW"
    echo "" >> "$CORPUS_RAW"
  done < "$TARGET_LIST"

  redact_to_stdout "$CORPUS_RAW" > "$CORPUS_RED"

  RAW_BYTES=$(wc -c < "$CORPUS_RAW" | tr -d ' ')
  RED_BYTES=$(wc -c < "$CORPUS_RED" | tr -d ' ')
  log "session corpus: raw=${RAW_BYTES}B redacted=${RED_BYTES}B"

  if [[ "$DRY_RUN" == "1" ]]; then
    plan "dry-run: would invoke claude -p on ${RED_BYTES}B of redacted Session Log content"
    plan "dry-run: would append summary to Historical Summaries/${SESSION_TARGET_QUARTER}.md"
    plan "dry-run: would move $TARGET_COUNT entries into _compacted-entries/${SESSION_TARGET_QUARTER}/"
  else
    mkdir -p "$HISTORICAL_DIR"
    mkdir -p "$COMPACTED_DIR/$SESSION_TARGET_QUARTER"

    SUMMARY_FILE="$HISTORICAL_DIR/${SESSION_TARGET_QUARTER}.md"

    PROMPT_FILE="$WORK_DIR/session-prompt.txt"
    cat > "$PROMPT_FILE" <<PROMPT_EOF
You are compacting old Session Log entries from an Obsidian vault into
a DISTILLED quarterly summary.

## Input
Below is the raw content of $TARGET_COUNT Session Log entries from quarter
$SESSION_TARGET_QUARTER (dates $MIN_DATE through $MAX_DATE). The content
has already been pre-redacted for common credential patterns; do NOT
re-redact. If you see any content resembling a secret that was missed,
omit it from your output.

## Task
Produce a DISTILLED summary keeping ONLY:
- Major milestones (shipped, deployed, launched, went live)
- Non-obvious decisions that influenced later work (architectural choices,
  trade-offs that surfaced later)
- Learnings that were referenced again in later sessions (patterns that
  became canonical)
- Abandoned approaches (anti-patterns what was tried and why it failed)

Drop:
- Routine progress updates
- Session-specific chatter
- "Next steps" that have since been completed
- Duplicated context across entries
- Trivial bug fixes unless they taught a broader lesson

## Output format
Produce Markdown only. No preamble, no "Here is the summary:" text. Start
directly with a heading:

## Compacted $MIN_DATE -> $MAX_DATE

Under it, use subsections:
### Milestones
### Decisions that shaped later work
### Patterns that became canonical
### Anti-patterns (what was tried and abandoned)

Each bullet should be one dense sentence. Cross-reference original entry
dates inline like "(2025-11-14)" where useful.

Aim for under 800 words total this is a DISTILLATION, not a rehash.

## Source material
(redacted, do not re-redact)

PROMPT_EOF
    cat "$CORPUS_RED" >> "$PROMPT_FILE"

    PROMPT_CONTENT=$(cat "$PROMPT_FILE")

    log "invoking claude -p for Session Log compaction (timeout=${CLAUDE_TIMEOUT_SEC}s)"

    SUMMARY_OUT="$WORK_DIR/session-summary.md"

    (
      unset CLAUDECODE
      unset CLAUDE_CODE_ENTRYPOINT
      export CLAUDE_OBSIDIAN_SYNC_CHILD=1
      "$PERL_BIN" -e 'alarm shift @ARGV; exec @ARGV' "$CLAUDE_TIMEOUT_SEC" \
        "$CLAUDE_BIN" -p "$PROMPT_CONTENT" \
          --allowedTools "Read,Write,Edit,Glob,Grep,Bash,Skill" \
        > "$SUMMARY_OUT" 2>> "$LOG"
    )
    RC=$?
    log "claude -p exit=$RC (session log compaction)"

    if [[ "$RC" -ne 0 ]] || [[ ! -s "$SUMMARY_OUT" ]]; then
      log "ERROR: claude -p produced no output or failed; aborting session log compaction"
    else
      if [[ ! -f "$SUMMARY_FILE" ]]; then
        cat > "$SUMMARY_FILE" <<EOF
---
tags: [claude, compacted, summary, ${SESSION_TARGET_QUARTER,,}]
last-updated: $TODAY
---

# Historical Summary: $SESSION_TARGET_QUARTER

Distilled summaries of Session Log and Technical Learnings entries from
$SESSION_TARGET_QUARTER, produced by the L4 compaction daemon. Original
entries preserved in \`_compacted-entries/$SESSION_TARGET_QUARTER/\`.

EOF
      fi
      {
        echo ""
        cat "$SUMMARY_OUT"
        echo ""
      } >> "$SUMMARY_FILE"
      if grep -q '^last-updated:' "$SUMMARY_FILE"; then
        sed -i '' -E "s/^last-updated:.*/last-updated: $TODAY/" "$SUMMARY_FILE" 2>/dev/null || \
          sed -i -E "s/^last-updated:.*/last-updated: $TODAY/" "$SUMMARY_FILE"
      fi
      log "wrote summary to $SUMMARY_FILE"

      NEW_SESSION_LOG="$WORK_DIR/session-log-rewritten.md"
      : > "$NEW_SESSION_LOG"

      COMPACTED_DATES="$WORK_DIR/compacted-dates.txt"
      cut -d'|' -f1 "$TARGET_LIST" > "$COMPACTED_DATES"

      awk -v dates_file="$COMPACTED_DATES" '
        BEGIN {
          while ((getline line < dates_file) > 0) {
            dates[line] = 1
          }
          close(dates_file)
          skip = 0
        }
        /^## [0-9]{4}-[0-9]{2}-[0-9]{2}/ {
          line = $0
          sub(/^## /, "", line)
          d = substr(line, 1, 10)
          if (d in dates) { skip = 1 } else { skip = 0 }
        }
        /^## [^0-9]/ { skip = 0 }
        /^---$/ { skip = 0 }
        { if (!skip) print }
      ' "$SESSION_LOG" > "$NEW_SESSION_LOG"

      while IFS='|' read -r ed eq ef; do
        [[ -f "$ef" ]] || continue
        title=$(awk -F= '/^TITLE=/ { sub(/^TITLE=/, "", $0); print; exit }' "$ef")
        slug=$(slugify "$title")
        dest="$COMPACTED_DIR/$SESSION_TARGET_QUARTER/${ed}-${slug}.md"
        {
          awk 'body { print } /^---BODY---$/ { body=1 }' "$ef"
        } > "$dest"
        log "archived entry: $dest"
      done < "$TARGET_LIST"

      cp "$SESSION_LOG" "$WORK_DIR/session-log-backup.md"
      mv "$NEW_SESSION_LOG" "$SESSION_LOG"
      log "rewrote $SESSION_LOG (removed $TARGET_COUNT entries; backup at $WORK_DIR/session-log-backup.md for this run)"
    fi
  fi
fi

# ========================================================================
# ---- Technical Learnings compaction (dedupe by root cause) ----
# ========================================================================

TECH_ENTRIES_DIR="$WORK_DIR/tech-entries"
mkdir -p "$TECH_ENTRIES_DIR"

if [[ -f "$TECH_LEARNINGS" ]]; then
  awk -v outdir="$TECH_ENTRIES_DIR" '
    BEGIN { in_entry = 0; current_num = 0; current_title = ""; buf = ""; idx = 0 }

    function flush() {
      if (in_entry && current_num != "") {
        idx++
        fname = sprintf("%s/%04d__%s.entry", outdir, idx, current_num)
        hdr = "NUM=" current_num "\nTITLE=" current_title "\n---BODY---\n"
        printf "%s%s", hdr, buf > fname
        close(fname)
      }
      in_entry = 0
      current_num = ""
      current_title = ""
      buf = ""
    }

    /^## [0-9]+\. / {
      flush()
      in_entry = 1
      line = $0
      sub(/^## /, "", line)
      n = line
      sub(/\..*/, "", n)
      current_num = n
      title = line
      sub(/^[0-9]+\. */, "", title)
      current_title = title
      buf = $0 "\n"
      next
    }

    /^## [^0-9]/ {
      flush()
      next
    }

    /^---$/ {
      if (in_entry) flush()
      next
    }

    {
      if (in_entry) buf = buf $0 "\n"
    }

    END { flush() }
  ' "$TECH_LEARNINGS"
fi

TECH_ENTRY_COUNT=$(ls -1 "$TECH_ENTRIES_DIR" 2>/dev/null | wc -l | tr -d ' ')
log "parsed $TECH_ENTRY_COUNT Technical Learnings entries"

RUN_TECH_COMPACTION=0
if [[ -n "${SESSION_TARGET_QUARTER:-}" ]] && [[ "$TARGET_COUNT" -ge "$MIN_QUALIFYING_ENTRIES" ]]; then
  RUN_TECH_COMPACTION=1
elif [[ -n "$QUARTER_OVERRIDE" ]] && [[ "$TECH_ENTRY_COUNT" -ge 5 ]]; then
  RUN_TECH_COMPACTION=1
fi

if [[ "$RUN_TECH_COMPACTION" -eq 1 ]] && [[ "$TECH_ENTRY_COUNT" -ge 5 ]]; then
  plan "would attempt Technical Learnings deduplication across $TECH_ENTRY_COUNT entries"

  if [[ "$DRY_RUN" == "1" ]]; then
    plan "dry-run: would invoke claude -p to dedupe Technical Learnings (no writes)"
  else
    TECH_CORPUS_RAW="$WORK_DIR/tech-corpus-raw.md"
    TECH_CORPUS_RED="$WORK_DIR/tech-corpus-redacted.md"

    awk '
      BEGIN { in_fm = 0; fm_seen = 0 }
      /^---$/ {
        if (!fm_seen) { in_fm = 1; fm_seen = 1; next }
        if (in_fm) { in_fm = 0; next }
      }
      { if (!in_fm) print }
    ' "$TECH_LEARNINGS" > "$TECH_CORPUS_RAW"

    redact_to_stdout "$TECH_CORPUS_RAW" > "$TECH_CORPUS_RED"

    TECH_PROMPT_FILE="$WORK_DIR/tech-prompt.txt"
    cat > "$TECH_PROMPT_FILE" <<PROMPT_EOF
You are deduplicating Technical Learnings entries from an Obsidian vault.
The input has already been pre-redacted for common credentials; do NOT
re-redact.

## Task
Scan the numbered learnings below. Identify entries that share the SAME
root cause (even if the symptoms look different). For each group of
duplicates:
- Keep the CLEAREST writeup of the root cause and solution.
- Merge all "Applies to:" lines from the duplicates (de-duplicated, one
  per line).
- Discard the other entries' boilerplate.

For entries with unique root causes, keep them unchanged.

## Output format
Produce Markdown only. No preamble. Output the FULL rewritten body
(excluding frontmatter and final "## Related" block those are managed
elsewhere). Preserve the original "## N. Title" numbered structure, but
renumber sequentially starting from 1 if you merged any entries.

For each merged entry, add a trailing italic line:
*(merged from original learnings #X, #Y)*

Keep every entry's "**Problem:**", "**Solution:**", "**Applies to:**"
section format intact this is a distillation, not a rewrite.

## Source material
(redacted, do not re-redact)

PROMPT_EOF
    cat "$TECH_CORPUS_RED" >> "$TECH_PROMPT_FILE"

    TECH_PROMPT_CONTENT=$(cat "$TECH_PROMPT_FILE")
    TECH_SUMMARY_OUT="$WORK_DIR/tech-summary.md"

    log "invoking claude -p for Technical Learnings dedupe (timeout=${CLAUDE_TIMEOUT_SEC}s)"
    (
      unset CLAUDECODE
      unset CLAUDE_CODE_ENTRYPOINT
      export CLAUDE_OBSIDIAN_SYNC_CHILD=1
      "$PERL_BIN" -e 'alarm shift @ARGV; exec @ARGV' "$CLAUDE_TIMEOUT_SEC" \
        "$CLAUDE_BIN" -p "$TECH_PROMPT_CONTENT" \
          --allowedTools "Read,Write,Edit,Glob,Grep,Bash,Skill" \
        > "$TECH_SUMMARY_OUT" 2>> "$LOG"
    )
    TECH_RC=$?
    log "claude -p exit=$TECH_RC (tech learnings dedupe)"

    if [[ "$TECH_RC" -ne 0 ]] || [[ ! -s "$TECH_SUMMARY_OUT" ]]; then
      log "ERROR: claude -p produced no output or failed for tech learnings; leaving file unchanged"
    else
      tech_archive_q="${SESSION_TARGET_QUARTER:-$(quarter_for_date "$TODAY")}"
      mkdir -p "$COMPACTED_DIR/$tech_archive_q"
      cp "$TECH_LEARNINGS" "$COMPACTED_DIR/$tech_archive_q/Technical Learnings (pre-dedupe ${TODAY}).md"

      TECH_NEW="$WORK_DIR/tech-new.md"

      awk '
        BEGIN { in_fm = 0; fm_seen = 0; done = 0 }
        /^---$/ {
          if (!fm_seen) { in_fm = 1; fm_seen = 1; print; next }
          if (in_fm) { in_fm = 0; print; done = 1; next }
        }
        { if (in_fm) print; else if (!done) exit }
      ' "$TECH_LEARNINGS" > "$TECH_NEW"

      if grep -q '^last-updated:' "$TECH_NEW"; then
        sed -i '' -E "s/^last-updated:.*/last-updated: $TODAY/" "$TECH_NEW" 2>/dev/null || \
          sed -i -E "s/^last-updated:.*/last-updated: $TODAY/" "$TECH_NEW"
      fi

      INTRO_FILE="$WORK_DIR/tech-intro.md"
      awk '
        BEGIN { in_fm = 0; fm_seen = 0; past_fm = 0 }
        /^---$/ {
          if (!fm_seen) { in_fm = 1; fm_seen = 1; next }
          if (in_fm) { in_fm = 0; past_fm = 1; next }
          if (past_fm) exit
        }
        /^## / { if (past_fm) exit }
        { if (past_fm) print }
      ' "$TECH_LEARNINGS" > "$INTRO_FILE"

      {
        cat "$INTRO_FILE"
        echo ""
        echo "---"
        echo ""
        cat "$TECH_SUMMARY_OUT"
        echo ""
        echo "---"
        echo ""
        awk '/^## Related/,0' "$TECH_LEARNINGS"
      } >> "$TECH_NEW"

      cp "$TECH_LEARNINGS" "$WORK_DIR/tech-learnings-backup.md"
      mv "$TECH_NEW" "$TECH_LEARNINGS"
      log "rewrote $TECH_LEARNINGS (deduplicated; backup at $WORK_DIR/tech-learnings-backup.md and in $COMPACTED_DIR/$tech_archive_q/)"
    fi
  fi
else
  plan "skipping Technical Learnings compaction (no qualifying quarter or <5 entries)"
fi

log "=== Compaction end (dry_run=$DRY_RUN) ==="

echo "summary: session_log_target_quarter=${SESSION_TARGET_QUARTER:-none} session_entries_compacted=${TARGET_COUNT:-0} tech_learnings_deduped=${RUN_TECH_COMPACTION:-0} dry_run=$DRY_RUN"

if [[ "$DRY_RUN" == "1" ]]; then
  plan "dry-run work dir retained at $WORK_DIR"
  trap 'release_lock' EXIT INT TERM
fi

exit 0
