#!/bin/bash
# test-concurrent-writes.sh  Verify WAL mode lets 5 concurrent ingest.sh
# invocations all land their rows without loss or corruption.
#
# Uses a dedicated test DB (so we don't pollute the real vault-staging.db)
# and a test-specific session_id prefix so we can assert on counts.
#
# Exits 0 on PASS, non-zero on FAIL.

set -uo pipefail

CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
BACKEND_DIR="${CLAUDE_BRIDGE_HOME}/sqlite-backend"
INGEST="$BACKEND_DIR/ingest.sh"
SQLITE=/usr/bin/sqlite3

TEST_PREFIX="concurrent-test-$$-$(date +%s)"
TEST_DB_BACKUP=""
REAL_DB="$BACKEND_DIR/vault-staging.db"

if [[ ! -x "$INGEST" ]]; then
  echo "FAIL: ingest.sh not found at $INGEST"
  exit 1
fi

# Move real DB aside (if present) so the test gets a fresh one.
if [[ -f "$REAL_DB" ]]; then
  TEST_DB_BACKUP="${REAL_DB}.test-backup-$$"
  mv "$REAL_DB" "$TEST_DB_BACKUP"
  [[ -f "${REAL_DB}-wal" ]] && mv "${REAL_DB}-wal" "${TEST_DB_BACKUP}-wal"
  [[ -f "${REAL_DB}-shm" ]] && mv "${REAL_DB}-shm" "${TEST_DB_BACKUP}-shm"
fi

cleanup() {
  rm -f "$REAL_DB" "${REAL_DB}-wal" "${REAL_DB}-shm"
  if [[ -n "$TEST_DB_BACKUP" ]]; then
    mv "$TEST_DB_BACKUP" "$REAL_DB"
    [[ -f "${TEST_DB_BACKUP}-wal" ]] && mv "${TEST_DB_BACKUP}-wal" "${REAL_DB}-wal"
    [[ -f "${TEST_DB_BACKUP}-shm" ]] && mv "${TEST_DB_BACKUP}-shm" "${REAL_DB}-shm"
  fi
}
trap cleanup EXIT INT TERM

echo "== Concurrent write test: 5 parallel ingest.sh invocations =="
echo "   session_id prefix: $TEST_PREFIX"
echo

PIDS=()
for i in 1 2 3 4 5; do
  (
    PAYLOAD=$(cat <<JSON
{
  "session_id": "${TEST_PREFIX}-${i}",
  "type": "session_log",
  "entry_date": "$(date '+%Y-%m-%d')",
  "title": "concurrent test row ${i}",
  "goal": "verify WAL serializes concurrent writers",
  "outcome": "row ${i} landed",
  "key_decisions": "",
  "learnings": "",
  "links": ""
}
JSON
    )
    echo "$PAYLOAD" | "$INGEST"
  ) &
  PIDS+=($!)
done

FAILED=0
for pid in "${PIDS[@]}"; do
  if ! wait "$pid"; then
    FAILED=$((FAILED + 1))
  fi
done

if [[ "$FAILED" -gt 0 ]]; then
  echo "FAIL: $FAILED of 5 ingest.sh workers exited non-zero"
  exit 1
fi

SESSIONS_COUNT=$("$SQLITE" "$REAL_DB" \
  "SELECT COUNT(*) FROM sessions WHERE session_id LIKE '${TEST_PREFIX}-%';" 2>/dev/null)
ENTRIES_COUNT=$("$SQLITE" "$REAL_DB" \
  "SELECT COUNT(*) FROM session_log_entries WHERE session_id LIKE '${TEST_PREFIX}-%';" 2>/dev/null)

echo "   sessions rows inserted:             $SESSIONS_COUNT / 5"
echo "   session_log_entries rows inserted:  $ENTRIES_COUNT / 5"

JOURNAL_MODE=$("$SQLITE" "$REAL_DB" "PRAGMA journal_mode;" 2>/dev/null)
echo "   PRAGMA journal_mode:                $JOURNAL_MODE"

PASS=1
if [[ "$SESSIONS_COUNT" -ne 5 ]]; then
  echo "FAIL: expected 5 sessions rows, got $SESSIONS_COUNT"
  PASS=0
fi
if [[ "$ENTRIES_COUNT" -ne 5 ]]; then
  echo "FAIL: expected 5 session_log_entries rows, got $ENTRIES_COUNT"
  PASS=0
fi
if [[ "$JOURNAL_MODE" != "wal" ]]; then
  echo "FAIL: journal_mode is '$JOURNAL_MODE', expected 'wal'"
  PASS=0
fi

echo
if [[ "$PASS" -eq 1 ]]; then
  echo "PASS: 5/5 concurrent writes landed, WAL active, no data loss"
  exit 0
else
  echo "FAIL: see above"
  exit 1
fi
