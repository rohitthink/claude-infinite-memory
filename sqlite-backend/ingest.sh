#!/bin/bash
# ingest.sh  Optional SQLite-backed write path for the Obsidian vault bridge.
#
# Reads a single JSON object from stdin and INSERTs it into the staging DB.
#
# Injection safety: SQLite string literals have NO backslash interpretation
# (unlike MySQL)  a value is safe inside '...' iff every embedded single
# quote is doubled. That's the canonical, provable SQL literal quoting rule
# and what every parameter binder ultimately does. We apply it via sed.
#
# Payload schema (top-level fields):
#   session_id   TEXT  required
#   hostname     TEXT  optional (defaults to `hostname`)
#   type         TEXT  required, one of: session_log | technical_learning
#
# For type=session_log, also:
#   entry_date     TEXT  (YYYY-MM-DD; defaults to today)
#   title, goal, outcome, key_decisions, learnings, links
#
# For type=technical_learning, also:
#   number INTEGER, title TEXT, problem TEXT, solution TEXT, applies_to TEXT
#
# Side effects:
#   - Creates the DB + schema on first run.
#   - Upserts a row in `sessions` so FK references resolve.
#   - Appends a log line to $CLAUDE_BRIDGE_HOME/logs/sqlite-backend.log.
#
# Exit codes:
#   0 ok, 1 missing dependency, 2 bad payload, 3 sqlite error

set -uo pipefail

CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
BACKEND_DIR="${CLAUDE_BRIDGE_HOME}/sqlite-backend"
DB="$BACKEND_DIR/vault-staging.db"
SCHEMA="$BACKEND_DIR/schema.sql"
LOG_DIR="${CLAUDE_BRIDGE_HOME}/logs"
LOG="$LOG_DIR/sqlite-backend.log"

SQLITE=/usr/bin/sqlite3
# Tell every sqlite3 invocation to wait up to 30s for a lock before erroring
# out. With WAL mode + this timeout, concurrent writers queue cleanly instead
# of failing with "database is locked" under burst load.
SQLITE_BUSY_MS=30000

mkdir -p "$LOG_DIR" "$BACKEND_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [ingest-$$] $*" >> "$LOG"; }

# Quote a string for safe inclusion inside a SQLite '...' literal.
# Empty input becomes NULL (not '') so COALESCE in upserts works correctly.
sqlq() {
  local v="$1"
  if [[ -z "$v" ]]; then
    printf 'NULL'
  else
    printf "'%s'" "$(printf '%s' "$v" | sed "s/'/''/g")"
  fi
}

# Quote an integer-or-NULL. Empty -> NULL; non-numeric -> NULL (with warning).
sqlq_int() {
  local v="$1"
  if [[ -z "$v" ]]; then
    printf 'NULL'
  elif [[ "$v" =~ ^-?[0-9]+$ ]]; then
    printf '%s' "$v"
  else
    log "WARN: non-integer value coerced to NULL: $v"
    printf 'NULL'
  fi
}

# ---- Dependency checks ----
if ! command -v jq >/dev/null 2>&1; then
  log "ERROR: jq not found in PATH"
  exit 1
fi
if [[ ! -x "$SQLITE" ]]; then
  log "ERROR: sqlite3 not executable at $SQLITE"
  exit 1
fi

# ---- Create DB + apply schema on first run ----
INIT_LOCK="$BACKEND_DIR/.init.lock"
if [[ ! -f "$DB" ]]; then
  if [[ ! -f "$SCHEMA" ]]; then
    log "ERROR: schema.sql missing at $SCHEMA  cannot initialize DB"
    exit 1
  fi
  for i in $(seq 1 30); do
    if mkdir "$INIT_LOCK" 2>/dev/null; then
      if [[ ! -f "$DB" ]]; then
        log "initializing DB at $DB"
        "$SQLITE" -cmd ".timeout $SQLITE_BUSY_MS" "$DB" < "$SCHEMA" 2>>"$LOG" \
          || { log "ERROR: schema apply failed"; rmdir "$INIT_LOCK" 2>/dev/null; exit 3; }
      fi
      rmdir "$INIT_LOCK" 2>/dev/null
      break
    fi
    sleep 1
  done
  if [[ ! -f "$DB" ]]; then
    log "ERROR: DB init timed out waiting for lock"
    exit 3
  fi
fi

# Always ensure WAL is on (idempotent).
"$SQLITE" -cmd ".timeout $SQLITE_BUSY_MS" "$DB" "PRAGMA journal_mode=WAL;" >/dev/null 2>>"$LOG" || true

# ---- Read + validate payload ----
PAYLOAD=$(cat 2>/dev/null || echo "")
if [[ -z "$PAYLOAD" ]]; then
  log "ERROR: empty stdin payload"
  exit 2
fi

if ! echo "$PAYLOAD" | jq -e . >/dev/null 2>&1; then
  log "ERROR: stdin is not valid JSON"
  exit 2
fi

SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id // ""')
TYPE=$(echo "$PAYLOAD" | jq -r '.type // ""')
HOSTNAME_VAL=$(echo "$PAYLOAD" | jq -r '.hostname // ""')
[[ -z "$HOSTNAME_VAL" ]] && HOSTNAME_VAL=$(hostname 2>/dev/null || echo "unknown")

if [[ -z "$SESSION_ID" ]]; then
  log "ERROR: payload missing session_id"
  exit 2
fi
if [[ "$TYPE" != "session_log" && "$TYPE" != "technical_learning" ]]; then
  log "ERROR: unknown type=$TYPE (must be session_log or technical_learning)"
  exit 2
fi

STARTED_AT=$(echo "$PAYLOAD" | jq -r '.started_at // ""')
ENDED_AT=$(echo "$PAYLOAD" | jq -r '.ended_at // ""')
REASON=$(echo "$PAYLOAD" | jq -r '.reason // ""')
TRANSCRIPT_PATH=$(echo "$PAYLOAD" | jq -r '.transcript_path // ""')

# ---- Upsert session row ----
SQL_SESSION=$(cat <<SQL
INSERT INTO sessions(session_id, hostname, started_at, ended_at, reason, transcript_path)
VALUES($(sqlq "$SESSION_ID"), $(sqlq "$HOSTNAME_VAL"), $(sqlq "$STARTED_AT"), $(sqlq "$ENDED_AT"), $(sqlq "$REASON"), $(sqlq "$TRANSCRIPT_PATH"))
ON CONFLICT(session_id) DO UPDATE SET
  hostname        = COALESCE(excluded.hostname,        sessions.hostname),
  started_at      = COALESCE(excluded.started_at,      sessions.started_at),
  ended_at        = COALESCE(excluded.ended_at,        sessions.ended_at),
  reason          = COALESCE(excluded.reason,          sessions.reason),
  transcript_path = COALESCE(excluded.transcript_path, sessions.transcript_path);
SQL
)

if ! printf '%s\n' "$SQL_SESSION" | "$SQLITE" -cmd ".timeout $SQLITE_BUSY_MS" "$DB" 2>>"$LOG"; then
  log "ERROR: session upsert failed"
  exit 3
fi

# ---- Type-specific insert ----
case "$TYPE" in
  session_log)
    ENTRY_DATE=$(echo "$PAYLOAD" | jq -r '.entry_date // ""')
    [[ -z "$ENTRY_DATE" ]] && ENTRY_DATE=$(date '+%Y-%m-%d')
    TITLE=$(echo "$PAYLOAD" | jq -r '.title // ""')
    GOAL=$(echo "$PAYLOAD" | jq -r '.goal // ""')
    OUTCOME=$(echo "$PAYLOAD" | jq -r '.outcome // ""')
    KEY_DECISIONS=$(echo "$PAYLOAD" | jq -r '.key_decisions // ""')
    LEARNINGS=$(echo "$PAYLOAD" | jq -r '.learnings // ""')
    LINKS=$(echo "$PAYLOAD" | jq -r '.links // ""')

    SQL_INSERT=$(cat <<SQL
INSERT INTO session_log_entries(session_id, entry_date, title, goal, outcome, key_decisions, learnings, links)
VALUES($(sqlq "$SESSION_ID"), $(sqlq "$ENTRY_DATE"), $(sqlq "$TITLE"), $(sqlq "$GOAL"), $(sqlq "$OUTCOME"), $(sqlq "$KEY_DECISIONS"), $(sqlq "$LEARNINGS"), $(sqlq "$LINKS"));
SQL
)
    if ! printf '%s\n' "$SQL_INSERT" | "$SQLITE" -cmd ".timeout $SQLITE_BUSY_MS" "$DB" 2>>"$LOG"; then
      log "ERROR: session_log_entries insert failed"
      exit 3
    fi
    log "inserted session_log_entry session=$SESSION_ID title='$TITLE'"
    ;;

  technical_learning)
    NUMBER=$(echo "$PAYLOAD" | jq -r '.number // ""')
    TITLE=$(echo "$PAYLOAD" | jq -r '.title // ""')
    PROBLEM=$(echo "$PAYLOAD" | jq -r '.problem // ""')
    SOLUTION=$(echo "$PAYLOAD" | jq -r '.solution // ""')
    APPLIES_TO=$(echo "$PAYLOAD" | jq -r '.applies_to // ""')

    SQL_INSERT=$(cat <<SQL
INSERT INTO technical_learnings(number, title, problem, solution, applies_to, source_session_id)
VALUES($(sqlq_int "$NUMBER"), $(sqlq "$TITLE"), $(sqlq "$PROBLEM"), $(sqlq "$SOLUTION"), $(sqlq "$APPLIES_TO"), $(sqlq "$SESSION_ID"));
SQL
)
    if ! printf '%s\n' "$SQL_INSERT" | "$SQLITE" -cmd ".timeout $SQLITE_BUSY_MS" "$DB" 2>>"$LOG"; then
      log "ERROR: technical_learnings insert failed"
      exit 3
    fi
    log "inserted technical_learning session=$SESSION_ID title='$TITLE'"
    ;;
esac

exit 0
