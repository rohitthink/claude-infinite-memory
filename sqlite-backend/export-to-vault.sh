#!/bin/bash
# export-to-vault.sh  Drain the SQLite staging DB into the markdown vault.
#
# Selects pending rows (exported_to_markdown=0), renders them as markdown in
# the exact format the obsidian-sync skill uses, appends to the vault files,
# and flips the exported_to_markdown flag.
#
# Concurrency: holds the SAME global lockfile as the main SessionEnd hook
# ($CLAUDE_BRIDGE_HOME/sync-active/vault-sync.lock) so the two write paths
# never race each other. Lock is released via trap on exit (normal, INT, TERM).
#
# Idempotency: safe to run on cron every 15 min. Does nothing if no pending
# rows; re-runs after a partial failure will retry only the rows that didn't
# get marked exported.
#
# Exit codes:
#   0 ok (may be a no-op), 1 missing dep / DB / vault, 2 lock not acquired

set -uo pipefail

# Parse --section argument before the main body so we can branch early.
SECTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --section) SECTION="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
BACKEND_DIR="${CLAUDE_BRIDGE_HOME}/sqlite-backend"
DB="$BACKEND_DIR/vault-staging.db"
VAULT="${CLAUDE_BRIDGE_VAULT:-}"
KNOWLEDGE_DIR="$VAULT/07 - Claude Knowledge"
SESSION_LOG="$KNOWLEDGE_DIR/Session Log.md"
TECH_LEARN="$KNOWLEDGE_DIR/Technical Learnings.md"
USER_PROFILE="$KNOWLEDGE_DIR/User Profile.md"

LOG_DIR="${CLAUDE_BRIDGE_HOME}/logs"
LOG="$LOG_DIR/sqlite-backend.log"

LOCK_DIR_ROOT="${CLAUDE_BRIDGE_HOME}/sync-active"
GLOBAL_LOCK="$LOCK_DIR_ROOT/vault-sync.lock"
LOCK_WAIT_SECONDS=300

SQLITE=/usr/bin/sqlite3
SQLITE_BUSY_MS=30000

mkdir -p "$LOG_DIR" "$LOCK_DIR_ROOT"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [export-$$] $*" >> "$LOG"; }

# render_user_profile(): regenerate User Profile.md entirely from user_preferences table.
# Full regeneration (not incremental) — the DB is canonical; markdown is a derived view.
# Writes atomically via a temp file + mv so Obsidian never sees a partial file.
render_user_profile() {
  # Check table exists (DB may predate this migration).
  local tbl_exists
  tbl_exists=$("$SQLITE" "$DB" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='user_preferences';" 2>/dev/null || echo 0)
  if [[ "$tbl_exists" -eq 0 ]]; then
    log "render_user_profile: user_preferences table not found, skipping"
    return 0
  fi

  local total
  total=$("$SQLITE" "$DB" "SELECT COUNT(*) FROM user_preferences;" 2>/dev/null || echo 0)
  if [[ "$total" -eq 0 ]]; then
    log "render_user_profile: no rows, skipping render"
    return 0
  fi

  local today
  today=$(date '+%Y-%m-%d')

  local tmp
  tmp=$(mktemp "${KNOWLEDGE_DIR}/.user-profile-render.XXXXXX") || { log "ERROR: mktemp failed"; return 1; }

  {
    printf -- '---\nlast-updated: %s\n---\n# User Profile\n\n' "$today"

    # Ordered sections (archive always last). Parallel arrays avoid bash 3.2 assoc-array limit.
    local SECTION_CATS="communication technical antipattern tooling pending"
    local SECTION_HEADINGS="## Communication style|## Technical preferences|## Anti-patterns|## Tooling preferences|## Pending review"

    local US=$'\x1f' RS=$'\x1e'
    local first_section=1

    local i=0
    for cat in $SECTION_CATS; do
      i=$((i + 1))
      local heading
      heading=$(echo "$SECTION_HEADINGS" | cut -d'|' -f"$i")

      local rows
      rows=$("$SQLITE" -separator "$US" -newline "$RS" "$DB" \
        "SELECT preference, seen_count FROM user_preferences
         WHERE category='${cat}'
         ORDER BY first_seen DESC;" 2>/dev/null || echo "")
      [[ -z "$rows" ]] && continue

      [[ "$first_section" -eq 0 ]] && printf '\n'
      first_section=0
      printf '%s\n' "$heading"

      local OLD_IFS="$IFS"
      IFS="$RS"
      local row_arr=()
      read -r -d '' -a row_arr < <(printf '%s\0' "$rows") || true
      IFS="$OLD_IFS"

      local row
      for row in "${row_arr[@]}"; do
        [[ -z "$row" ]] && continue
        local pref seen_ct
        IFS="$US" read -r pref seen_ct <<<"$row"
        [[ -z "$pref" ]] && continue
        if [[ -n "$seen_ct" && "$seen_ct" -gt 1 ]]; then
          printf -- '- %s (seen %dx)\n' "$pref" "$seen_ct"
        else
          printf -- '- %s\n' "$pref"
        fi
      done
    done

    # Archive section (includes archived_at date in heading).
    local arch_rows
    arch_rows=$("$SQLITE" -separator "$US" -newline "$RS" "$DB" \
      "SELECT preference, seen_count, COALESCE(archived_at,'') FROM user_preferences
       WHERE category='archive'
       ORDER BY first_seen DESC;" 2>/dev/null || echo "")

    if [[ -n "$arch_rows" ]]; then
      local arch_max_date
      arch_max_date=$("$SQLITE" "$DB" \
        "SELECT COALESCE(MAX(archived_at), DATE('now')) FROM user_preferences WHERE category='archive';" \
        2>/dev/null || echo "$today")
      printf '\n## Archive (auto-expired %s)\n' "$arch_max_date"

      local OLD_IFS2="$IFS"
      IFS="$RS"
      local arch_arr=()
      read -r -d '' -a arch_arr < <(printf '%s\0' "$arch_rows") || true
      IFS="$OLD_IFS2"

      for row in "${arch_arr[@]}"; do
        [[ -z "$row" ]] && continue
        IFS="$US" read -r pref seen_ct _archived_at <<<"$row"
        [[ -z "$pref" ]] && continue
        printf -- '- %s\n' "$pref"
      done
    fi
  } > "$tmp" 2>>"$LOG"

  mkdir -p "$KNOWLEDGE_DIR"
  mv "$tmp" "$USER_PROFILE"
  log "render_user_profile: wrote $USER_PROFILE ($total preferences)"
}

# ---- Short-circuit for --section user-profile ----
# Only renders User Profile, then exits. Used by the hourly launchd job.
if [[ "$SECTION" == "user-profile" ]]; then
  if [[ ! -x "$SQLITE" ]]; then
    log "ERROR: sqlite3 not executable at $SQLITE"
    exit 1
  fi
  if [[ ! -f "$DB" ]]; then
    log "--section user-profile: no DB at $DB, nothing to render"
    exit 0
  fi
  if [[ -z "$VAULT" || ! -d "$VAULT" ]]; then
    log "ABORT: vault not set or not mounted at $VAULT"
    exit 1
  fi
  mkdir -p "$KNOWLEDGE_DIR"
  render_user_profile
  exit $?
fi

# ---- Dependency + path checks ----
if [[ ! -x "$SQLITE" ]]; then
  log "ERROR: sqlite3 not executable at $SQLITE"
  exit 1
fi
if [[ ! -f "$DB" ]]; then
  log "no staging DB at $DB  nothing to export"
  exit 0
fi
if [[ -z "$VAULT" || ! -d "$VAULT" ]]; then
  log "ABORT: vault not set or not mounted at $VAULT"
  exit 1
fi
mkdir -p "$KNOWLEDGE_DIR"
touch "$SESSION_LOG" "$TECH_LEARN"

# ---- Pre-flight: anything to do? (cheap check before grabbing the lock) ----
PENDING_LOG=$("$SQLITE" "$DB" "SELECT COUNT(*) FROM session_log_entries WHERE exported_to_markdown=0;" 2>/dev/null || echo 0)
PENDING_TL=$("$SQLITE" "$DB" "SELECT COUNT(*) FROM technical_learnings WHERE exported_to_markdown=0;" 2>/dev/null || echo 0)

if [[ "$PENDING_LOG" -eq 0 && "$PENDING_TL" -eq 0 ]]; then
  exit 0
fi

log "pending: session_log=$PENDING_LOG technical_learning=$PENDING_TL  starting export"

# ---- Acquire the same global lock the main hook uses ----
ACQUIRED=0
for i in $(seq 1 "$LOCK_WAIT_SECONDS"); do
  if mkdir "$GLOBAL_LOCK" 2>/dev/null; then
    ACQUIRED=1
    break
  fi
  sleep 1
done

if [[ "$ACQUIRED" -eq 0 ]]; then
  log "ABORT: could not acquire $GLOBAL_LOCK after ${LOCK_WAIT_SECONDS}s"
  exit 2
fi

cleanup() {
  rmdir "$GLOBAL_LOCK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "lock acquired"

# ---- Export pending session_log entries ----
US=$'\x1f'
RS=$'\x1e'

if [[ "$PENDING_LOG" -gt 0 ]]; then
  ROWS=$("$SQLITE" -separator "$US" -newline "$RS" "$DB" \
    "SELECT id, COALESCE(entry_date,''), COALESCE(title,''), COALESCE(goal,''), COALESCE(outcome,''), COALESCE(key_decisions,''), COALESCE(learnings,''), COALESCE(links,'') FROM session_log_entries WHERE exported_to_markdown=0 ORDER BY id ASC;" 2>>"$LOG")

  EXPORTED_IDS=()
  OLD_IFS="$IFS"
  IFS="$RS"
  read -r -d '' -a ROW_ARR < <(printf '%s\0' "$ROWS") || true
  IFS="$OLD_IFS"

  {
    for row in "${ROW_ARR[@]}"; do
      [[ -z "$row" ]] && continue
      IFS="$US" read -r id entry_date title goal outcome key_decisions learnings links <<<"$row"
      [[ -z "${id:-}" ]] && continue

      printf '\n## %s  %s\n' "$entry_date" "$title"
      [[ -n "$goal" ]]          && printf -- '- **Goal**: %s\n' "$goal"
      [[ -n "$outcome" ]]       && printf -- '- **Outcome**: %s\n' "$outcome"
      [[ -n "$key_decisions" ]] && printf -- '- **Key decisions**: %s\n' "$key_decisions"
      [[ -n "$learnings" ]]     && printf -- '- **Learnings**: %s\n' "$learnings"
      [[ -n "$links" ]]         && printf -- '- **Links**: %s\n' "$links"

      EXPORTED_IDS+=("$id")
    done
  } >> "$SESSION_LOG"

  if [[ ${#EXPORTED_IDS[@]} -gt 0 ]]; then
    IDS_CSV=$(IFS=,; echo "${EXPORTED_IDS[*]}")
    "$SQLITE" "$DB" "UPDATE session_log_entries SET exported_to_markdown=1 WHERE id IN ($IDS_CSV);" 2>>"$LOG" \
      || log "ERROR: failed to mark session_log_entries exported (ids=$IDS_CSV)"
    log "exported ${#EXPORTED_IDS[@]} session_log_entries"
  fi
fi

# ---- Export pending technical_learnings ----
if [[ "$PENDING_TL" -gt 0 ]]; then
  ROWS=$("$SQLITE" -separator "$US" -newline "$RS" "$DB" \
    "SELECT id, COALESCE(number,''), COALESCE(title,''), COALESCE(problem,''), COALESCE(solution,''), COALESCE(applies_to,'') FROM technical_learnings WHERE exported_to_markdown=0 ORDER BY id ASC;" 2>>"$LOG")

  EXPORTED_IDS=()
  OLD_IFS="$IFS"
  IFS="$RS"
  read -r -d '' -a ROW_ARR < <(printf '%s\0' "$ROWS") || true
  IFS="$OLD_IFS"

  {
    for row in "${ROW_ARR[@]}"; do
      [[ -z "$row" ]] && continue
      IFS="$US" read -r id number title problem solution applies_to <<<"$row"
      [[ -z "${id:-}" ]] && continue

      if [[ -n "$number" ]]; then
        printf '\n## %s. %s\n' "$number" "$title"
      else
        printf '\n## %s\n' "$title"
      fi
      [[ -n "$problem" ]]    && printf -- '**Problem**: %s\n' "$problem"
      [[ -n "$solution" ]]   && printf -- '**Solution**: %s\n' "$solution"
      [[ -n "$applies_to" ]] && printf -- '**Applies to**: %s\n' "$applies_to"

      EXPORTED_IDS+=("$id")
    done
  } >> "$TECH_LEARN"

  if [[ ${#EXPORTED_IDS[@]} -gt 0 ]]; then
    IDS_CSV=$(IFS=,; echo "${EXPORTED_IDS[*]}")
    "$SQLITE" "$DB" "UPDATE technical_learnings SET exported_to_markdown=1 WHERE id IN ($IDS_CSV);" 2>>"$LOG" \
      || log "ERROR: failed to mark technical_learnings exported (ids=$IDS_CSV)"
    log "exported ${#EXPORTED_IDS[@]} technical_learnings"
  fi
fi

log "export complete"
exit 0
