#!/bin/bash
# auto-moc-daemon.sh
#
# Weekly (Sunday 04:00) job that generates/updates Maps of Content (MOCs)
# for topic clusters in your Obsidian vault.
#
# Algorithm:
#   1. Acquires the global vault-sync lock (same pattern as the
#      compaction daemon + session-end-vault-sync hook).
#   2. Scans Session Log* + Technical Learnings for topic signals:
#        a. Frontmatter `tags:` array items
#        b. Inline `#tag` tokens inside headings
#   3. For any topic with >=5 references, checks
#      `07 - Claude Knowledge/MOCs/<topic>.md`:
#        - Missing -> generate from scratch (links + short excerpts)
#        - Exists but has fewer links than current match count -> append
#          only the new links (never remove)
#   4. Updates MOC frontmatter `last-updated: YYYY-MM-DD`.
#   5. Pure text analysis does NOT invoke `claude -p`. Deterministic
#      and cheap.
#
# Security boundary (2026-04-16 audit fix):
#   This daemon deliberately does NOT call `claude -p`. MOC generation is
#   pure text analysis, so there is no LLM prompt surface and therefore
#   no `--allowedTools` to narrow. If a future change introduces a
#   `claude -p` call here, it MUST:
#     - use `--allowedTools "Read,Write,Edit,Glob,Grep"` (no Bash, no
#       Skill — vault content is untrusted multi-writer input);
#     - prepend a DEFENSIVE PROMPT preamble telling the model to treat
#       inline content as data, not instructions;
#     - mirror the compaction-daemon's human-in-the-loop pattern
#       (proposal file + explicit --apply) for any destructive step; and
#     - use create_sandbox() + validate_sandbox_output() from
#       compaction-daemon.sh to constrain Write/Edit to a per-run sandbox
#       under CLAUDE_BRIDGE_HOME/compaction-sandbox/<run-id>/ with
#       post-hoc path validation (Gemini Tier-2 finding #2). A prompt-
#       injected payload targeting ~/.zshrc or .git/hooks/ must be
#       rejected and the proposal discarded. See compaction-daemon.sh for
#       the reference implementation.
#
# Flags:
#   --dry-run                Plan only; no writes. Also DRYRUN=1.
#   --topic <topic>          Regenerate only this topic (still gated by
#                            the >=5 reference threshold).
#   --vault-override <path>  Override vault root (for tests).
#                            Also VAULT_OVERRIDE env var.
#   --help                   Show help and exit.

set -uo pipefail

# ---- Defaults (override via env) ----
CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
DEFAULT_VAULT="${CLAUDE_BRIDGE_VAULT:-}"

LOG_DIR="${CLAUDE_BRIDGE_HOME}/logs"
LOG="$LOG_DIR/compaction.log"   # shared with compaction-daemon for unified view
LOCK_DIR="${CLAUDE_BRIDGE_HOME}/sync-active"
GLOBAL_LOCK="$LOCK_DIR/vault-sync.lock"

MIN_REFERENCES="${MOC_MIN_FILES:-5}"
LOCK_WAIT_SEC=300

# Stopwords don't MOC these (too generic or managed elsewhere)
STOPWORDS_RE='^(claude|sessions?|log|index|tools?|automation|patterns?|debugging)$'

# Feature flag: 'sqlite' uses incremental tag cache; 'scan' (default) does
# a full vault scan on every run. Set CLAUDE_BRIDGE_MOC_CACHE=sqlite to opt in.
CLAUDE_BRIDGE_MOC_CACHE="${CLAUDE_BRIDGE_MOC_CACHE:-scan}"
SQLITE_DB="${CLAUDE_BRIDGE_HOME}/claude-bridge.db"
_MOC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOC_SCHEMA_SQL="$_MOC_SCRIPT_DIR/../../sqlite-backend/schema.sql"

# ---- Arg parsing ----
DRY_RUN="${DRYRUN:-0}"
TOPIC_FILTER=""
VAULT="${VAULT_OVERRIDE:-$DEFAULT_VAULT}"
MOC_INVALIDATE=0

usage() {
  cat <<'EOF'
auto-moc-daemon.sh weekly MOC (Map of Content) generator

Usage:
  auto-moc-daemon.sh [flags]

Flags:
  --dry-run                Print plan; no writes. Also DRYRUN=1 env var.
  --topic <topic>          Regenerate a specific MOC (still requires >=5
                           references in the vault).
  --vault-override <path>  Override vault root (for testing).
                           Also VAULT_OVERRIDE env var.
  --invalidate             Truncate the moc_file_tags cache and do a full
                           rebuild (escape hatch for CLAUDE_BRIDGE_MOC_CACHE=sqlite).
  --help                   Show this help.

Behavior:
  - Walks the vault's 07 - Claude Knowledge/ directory (plus all linked
    vault files).
  - Extracts frontmatter tags and inline #tag tokens from headings.
  - Counts references per tag (distinct file count).
  - For tags with >=5 distinct files: ensure MOCs/<tag>.md exists and
    contains [[wikilinks]] to every referencing file with a short
    excerpt.
  - Skips common stopwords (claude, sessions, log, etc.).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --topic)
      TOPIC_FILTER="${2:-}"
      if [[ -z "$TOPIC_FILTER" ]]; then
        echo "ERROR: --topic requires a value" >&2
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
    --invalidate)
      MOC_INVALIDATE=1
      shift
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

mkdir -p "$LOG_DIR" "$LOCK_DIR"

# ---- Log rotation at 1MB (shared log) ----
if [[ -f "$LOG" ]] && [[ $(wc -c < "$LOG" 2>/dev/null || echo 0) -gt 1048576 ]]; then
  mv -f "$LOG" "$LOG.1" 2>/dev/null || true
fi

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [auto-moc-$$] $*" >> "$LOG"
}

plan() {
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
MOCS_DIR="$KNOWLEDGE_DIR/MOCs"

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  log "ABORT: $KNOWLEDGE_DIR not found"
  exit 1
fi

log "=== auto-moc start | vault=$VAULT dry_run=$DRY_RUN topic=${TOPIC_FILTER:-all} cache=$CLAUDE_BRIDGE_MOC_CACHE ==="

TODAY="$(date '+%Y-%m-%d')"

# ---- SQLite helpers (sqlite mode only) ----

_moc_sql_esc() { printf '%s' "$1" | sed "s/'/''/g"; }

ensure_moc_db() {
  if [[ ! -f "$MOC_SCHEMA_SQL" ]]; then
    log "WARN: schema.sql not found at $MOC_SCHEMA_SQL; skipping DB init"
    return 1
  fi
  sqlite3 "$SQLITE_DB" < "$MOC_SCHEMA_SQL" 2>>"$LOG" || {
    log "ERROR: failed to init MOC SQLite schema at $SQLITE_DB"; return 1
  }
  return 0
}

moc_db_exec() {
  sqlite3 "$SQLITE_DB" "$1" 2>>"$LOG" || log "WARN: moc_db_exec failed: $1"
}

moc_db_query() {
  sqlite3 "$SQLITE_DB" "$1" 2>>"$LOG"
}

# ---- Lock ----
acquire_lock() {
  local acquired=0 i
  for i in $(seq 1 "$LOCK_WAIT_SEC"); do
    if mkdir "$GLOBAL_LOCK" 2>/dev/null; then
      acquired=1
      break
    fi
    sleep 1
  done
  if [[ "$acquired" -eq 0 ]]; then
    log "ABORT: could not acquire vault lock after ${LOCK_WAIT_SEC}s"
    echo "ERROR: could not acquire vault lock after ${LOCK_WAIT_SEC}s" >&2
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
  plan "dry-run: skipping lock acquisition"
fi

# ---- Work dir for transient tmpfiles ----
WORK_DIR=$(mktemp -d -t auto-moc.XXXXXX)
cleanup_all() {
  rm -rf "$WORK_DIR"
  release_lock
}
trap cleanup_all EXIT INT TERM

# ---- Scan candidate files ----
SCAN_LIST="$WORK_DIR/scan-list.txt"
: > "$SCAN_LIST"

while IFS= read -r -d '' f; do
  echo "$f" >> "$SCAN_LIST"
done < <(find "$KNOWLEDGE_DIR" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)

if [[ -d "$VAULT/_Maps" ]]; then
  while IFS= read -r -d '' f; do
    echo "$f" >> "$SCAN_LIST"
  done < <(find "$VAULT/_Maps" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)
fi

SCAN_COUNT=$(wc -l < "$SCAN_LIST" | tr -d ' ')
log "scan candidates: $SCAN_COUNT files"

# ---- Extract tags per file (full scan or incremental from cache) ----
TAG_HITS="$WORK_DIR/tag-hits.txt"
: > "$TAG_HITS"

# Helper: parse one file and emit tag<TAB>file lines to TAG_HITS.
_parse_file_tags() {
  local file="$1"
  [[ -f "$file" ]] || return

  local fm_tags
  fm_tags=$(awk '
    BEGIN { in_fm = 0; fm_seen = 0 }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; fm_seen = 1; next }
    in_fm && /^---[[:space:]]*$/ { in_fm = 0; exit }
    in_fm && /^tags:[[:space:]]*\[/ {
      line = $0
      sub(/^tags:[[:space:]]*\[/, "", line)
      sub(/\].*$/, "", line)
      print line
    }
  ' "$file" 2>/dev/null)

  if [[ -n "$fm_tags" ]]; then
    IFS=',' read -r -a tag_array <<< "$fm_tags"
    for t in "${tag_array[@]}"; do
      t="${t## }"; t="${t%% }"; t="${t//\"/}"; t="${t//\'/}"
      t=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
      t="${t#\#}"
      [[ -n "$t" ]] && printf '%s\t%s\n' "$t" "$file" >> "$TAG_HITS"
    done
  fi

  while IFS= read -r hline; do
    printf '%s' "$hline" | grep -oE '#[a-zA-Z][a-zA-Z0-9_-]+' | while IFS= read -r token; do
      local t="${token#\#}"
      t=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
      [[ -n "$t" ]] && printf '%s\t%s\n' "$t" "$file" >> "$TAG_HITS"
    done
  done < <(grep -E '^#+\s+' "$file" 2>/dev/null || true)
}

if [[ "$CLAUDE_BRIDGE_MOC_CACHE" == "sqlite" ]]; then
  # ---- Incremental scan: only re-parse files whose mtime > cached value ----
  ensure_moc_db || { log "WARN: falling back to full scan (DB init failed)"; CLAUDE_BRIDGE_MOC_CACHE=scan; }
fi

if [[ "$CLAUDE_BRIDGE_MOC_CACHE" == "sqlite" ]]; then
  if [[ "$MOC_INVALIDATE" -eq 1 ]]; then
    log "invalidate: truncating moc_file_tags cache"
    moc_db_exec "DELETE FROM moc_file_tags;"
  fi

  files_rescanned=0
  files_cached=0

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    rel_file="${file#$VAULT/}"
    current_mtime=$(stat -f '%m' "$file" 2>/dev/null || stat -c '%Y' "$file" 2>/dev/null || echo 0)
    cached_mtime=$(moc_db_query "SELECT MAX(file_mtime) FROM moc_file_tags WHERE file_path='$(_moc_sql_esc "$rel_file")';" 2>/dev/null)
    cached_mtime="${cached_mtime:-0}"

    if [[ "$current_mtime" -gt "${cached_mtime:-0}" ]]; then
      # File is newer than cache — reparse and refresh DB rows.
      moc_db_exec "DELETE FROM moc_file_tags WHERE file_path='$(_moc_sql_esc "$rel_file")';"
      _parse_file_tags "$file"

      # Build a single transaction of INSERTs for this file's tags.
      local_tags_file="$WORK_DIR/tags-for-insert-$$.txt"
      grep -F "$file" "$TAG_HITS" | awk -F'\t' '{print $1}' | sort -u > "$local_tags_file" 2>/dev/null || true
      if [[ -s "$local_tags_file" ]]; then
        now_ts=$(date '+%Y-%m-%d %H:%M:%S')
        {
          echo "BEGIN;"
          while IFS= read -r tag_val; do
            [[ -z "$tag_val" ]] && continue
            echo "INSERT OR REPLACE INTO moc_file_tags (file_path,tag,last_scanned_at,file_mtime) VALUES ('$(_moc_sql_esc "$rel_file")','$(_moc_sql_esc "$tag_val")','$now_ts',$current_mtime);"
          done < "$local_tags_file"
          echo "COMMIT;"
        } | sqlite3 "$SQLITE_DB" 2>>"$LOG"
        rm -f "$local_tags_file"
      fi
      files_rescanned=$((files_rescanned + 1))
    else
      # File unchanged — pull cached tag rows into TAG_HITS.
      while IFS='|' read -r tag_val; do
        [[ -z "$tag_val" ]] && continue
        printf '%s\t%s\n' "$tag_val" "$file" >> "$TAG_HITS"
      done < <(moc_db_query "SELECT tag FROM moc_file_tags WHERE file_path='$(_moc_sql_esc "$rel_file")';" 2>/dev/null)
      files_cached=$((files_cached + 1))
    fi
  done < "$SCAN_LIST"

  log "incremental scan: rescanned=$files_rescanned cached=$files_cached"

  # Delete-detection: remove DB rows for files that no longer exist on disk.
  del_count=0
  while IFS='|' read -r rel_path; do
    [[ -z "$rel_path" ]] && continue
    abs_path="$VAULT/$rel_path"
    if [[ ! -f "$abs_path" ]]; then
      moc_db_exec "DELETE FROM moc_file_tags WHERE file_path='$(_moc_sql_esc "$rel_path")';"
      del_count=$((del_count + 1))
      log "delete-detection: removed stale cache rows for $rel_path"
    fi
  done < <(moc_db_query "SELECT DISTINCT file_path FROM moc_file_tags;" 2>/dev/null)
  [[ "$del_count" -gt 0 ]] && log "delete-detection: pruned $del_count stale file(s) from cache"

else
  # ---- Full vault scan (default 'scan' mode) ----
  while IFS= read -r file; do
    _parse_file_tags "$file"
  done < "$SCAN_LIST"
fi

TAG_HIT_COUNT=$(wc -l < "$TAG_HITS" | tr -d ' ')
log "total tag hits: $TAG_HIT_COUNT (cache=$CLAUDE_BRIDGE_MOC_CACHE)"

TAG_COUNTS="$WORK_DIR/tag-counts.txt"
sort -u "$TAG_HITS" | awk -F'\t' '{ print $1 }' | sort | uniq -c | sort -rn > "$TAG_COUNTS"

log "distinct tag counts:"
while IFS= read -r line; do
  log "  $line"
done < "$TAG_COUNTS"

ELIGIBLE="$WORK_DIR/eligible.txt"
: > "$ELIGIBLE"

while IFS= read -r line; do
  count=$(echo "$line" | awk '{ print $1 }')
  tag=$(echo "$line" | awk '{ print $2 }')
  [[ -z "$tag" ]] && continue
  if [[ "$count" -lt "$MIN_REFERENCES" ]]; then
    continue
  fi
  if echo "$tag" | grep -qE "$STOPWORDS_RE"; then
    log "skipping stopword tag: $tag ($count refs)"
    continue
  fi
  if [[ -n "$TOPIC_FILTER" ]] && [[ "$tag" != "$TOPIC_FILTER" ]]; then
    continue
  fi
  echo "$count|$tag" >> "$ELIGIBLE"
done < "$TAG_COUNTS"

ELIGIBLE_COUNT=$(wc -l < "$ELIGIBLE" | tr -d ' ')
plan "eligible topics for MOC: $ELIGIBLE_COUNT"
while IFS='|' read -r cnt tag; do
  [[ -z "$tag" ]] && continue
  plan "  - $tag ($cnt refs)"
done < "$ELIGIBLE"

if [[ "$ELIGIBLE_COUNT" -eq 0 ]]; then
  log "no eligible topics; exiting"
  exit 0
fi

MOCS_CREATED=0
MOCS_UPDATED=0
MOCS_SKIPPED=0

mkdir -p "$MOCS_DIR" 2>/dev/null || true

extract_excerpt() {
  local file="$1"
  local tag="$2"
  local excerpt=""

  excerpt=$(awk -v tag="$tag" '
    BEGIN {
      IGNORECASE = 1
      collected = 0
      max_lines = 3
    }
    /^#+\s+/ {
      if (match(tolower($0), "#" tolower(tag) "(\\b|$)")) {
        print $0
        in_block = 1
        next
      } else {
        in_block = 0
      }
    }
    in_block && NF > 0 && !/^---/ {
      if (collected < max_lines) {
        print
        collected++
      }
    }
    in_block && collected >= max_lines { exit }
  ' "$file" 2>/dev/null | head -5)

  if [[ -z "$excerpt" ]]; then
    excerpt=$(awk '
      BEGIN { in_fm = 0; fm_seen = 0; done_fm = 0; picked = 0 }
      NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; fm_seen = 1; next }
      in_fm && /^---[[:space:]]*$/ { in_fm = 0; done_fm = 1; next }
      !fm_seen { done_fm = 1 }
      done_fm && !in_fm && NF > 0 && !/^#/ && !/^---/ {
        if (picked < 2) { print; picked++ }
      }
      picked >= 2 { exit }
    ' "$file" 2>/dev/null | head -2)
  fi

  excerpt=$(echo "$excerpt" | tr '\n' ' ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//')
  if [[ ${#excerpt} -gt 200 ]]; then
    excerpt="${excerpt:0:197}..."
  fi
  echo "$excerpt"
}

file_to_wikilink_name() {
  local p="$1"
  local base
  base="${p##*/}"
  base="${base%.md}"
  echo "$base"
}

while IFS='|' read -r cnt tag; do
  [[ -z "$tag" ]] && continue

  MATCHED_FILES="$WORK_DIR/matched-${tag}.txt"
  awk -F'\t' -v t="$tag" '$1 == t { print $2 }' "$TAG_HITS" | sort -u > "$MATCHED_FILES"

  MOC_PATH="$MOCS_DIR/${tag}.md"

  if [[ ! -f "$MOC_PATH" ]]; then
    plan "CREATE MOC: $MOC_PATH ($cnt matched files)"
    MOCS_CREATED=$((MOCS_CREATED + 1))

    if [[ "$DRY_RUN" != "1" ]]; then
      {
        cat <<EOF
---
tags: [moc, ${tag}]
last-updated: $TODAY
---

# MOC: ${tag}

Auto-generated Map of Content for \`#${tag}\`. Regenerated weekly by
the auto-moc daemon. New links are appended over
time; existing links are never removed. Edit the top matter or add
commentary below the daemon only touches the \`## Linked notes\` block.

## Linked notes

EOF
        while IFS= read -r mf; do
          [[ -f "$mf" ]] || continue
          name=$(file_to_wikilink_name "$mf")
          excerpt=$(extract_excerpt "$mf" "$tag")
          echo "- [[${name}]]"
          [[ -n "$excerpt" ]] && echo "    - ${excerpt}"
        done < "$MATCHED_FILES"
      } > "$MOC_PATH"
      log "wrote $MOC_PATH"
    fi

  else
    EXISTING_LINKS="$WORK_DIR/existing-${tag}.txt"
    grep -oE '\[\[[^]|]+(\|[^]]+)?\]\]' "$MOC_PATH" 2>/dev/null | \
      sed -E 's/\[\[//; s/\|.*$//; s/\]\]//' | sort -u > "$EXISTING_LINKS"

    EXISTING_COUNT=$(wc -l < "$EXISTING_LINKS" | tr -d ' ')

    NEW_LINKS="$WORK_DIR/new-${tag}.txt"
    : > "$NEW_LINKS"
    while IFS= read -r mf; do
      name=$(file_to_wikilink_name "$mf")
      if ! grep -qxF "$name" "$EXISTING_LINKS"; then
        echo "$mf" >> "$NEW_LINKS"
      fi
    done < "$MATCHED_FILES"

    NEW_COUNT=$(wc -l < "$NEW_LINKS" | tr -d ' ')

    if [[ "$NEW_COUNT" -eq 0 ]]; then
      plan "SKIP MOC (up to date): $MOC_PATH (existing=$EXISTING_COUNT)"
      MOCS_SKIPPED=$((MOCS_SKIPPED + 1))

      if [[ "$DRY_RUN" != "1" ]]; then
        if grep -q '^last-updated:' "$MOC_PATH"; then
          sed -i '' -E "s/^last-updated:.*/last-updated: $TODAY/" "$MOC_PATH" 2>/dev/null || \
            sed -i -E "s/^last-updated:.*/last-updated: $TODAY/" "$MOC_PATH"
        fi
      fi
    else
      plan "UPDATE MOC: $MOC_PATH (+$NEW_COUNT new links; existing=$EXISTING_COUNT)"
      MOCS_UPDATED=$((MOCS_UPDATED + 1))

      if [[ "$DRY_RUN" != "1" ]]; then
        {
          echo ""
          echo "### Added $TODAY"
          echo ""
          while IFS= read -r mf; do
            [[ -f "$mf" ]] || continue
            name=$(file_to_wikilink_name "$mf")
            excerpt=$(extract_excerpt "$mf" "$tag")
            echo "- [[${name}]]"
            [[ -n "$excerpt" ]] && echo "    - ${excerpt}"
          done < "$NEW_LINKS"
        } >> "$MOC_PATH"
        if grep -q '^last-updated:' "$MOC_PATH"; then
          sed -i '' -E "s/^last-updated:.*/last-updated: $TODAY/" "$MOC_PATH" 2>/dev/null || \
            sed -i -E "s/^last-updated:.*/last-updated: $TODAY/" "$MOC_PATH"
        fi
        log "appended $NEW_COUNT links to $MOC_PATH"
      fi
    fi
  fi

done < "$ELIGIBLE"

echo "summary: created=$MOCS_CREATED updated=$MOCS_UPDATED skipped=$MOCS_SKIPPED"
log "=== auto-moc end (created=$MOCS_CREATED updated=$MOCS_UPDATED skipped=$MOCS_SKIPPED dry_run=$DRY_RUN) ==="

exit 0
