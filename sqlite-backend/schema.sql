-- SQLite schema for the optional Obsidian vault staging backend.
--
-- Purpose: provide a safe, concurrency-resistant buffer between Claude sessions
-- (many writers) and the user-facing markdown vault files (single destination).
-- Sessions INSERT rows here via ingest.sh. A separate export-to-vault.sh
-- periodically drains rows with exported_to_markdown=0 into the markdown
-- files under a global lockfile, then flips the flag.
--
-- WAL mode is enabled so concurrent writers don't block each other  SQLite
-- serializes them safely with no risk of partial-write corruption, which the
-- existing mkdir-lock + text-append scheme only mitigates, doesn't eliminate.

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS sessions (
    session_id       TEXT PRIMARY KEY,
    hostname         TEXT,
    started_at       TEXT,
    ended_at         TEXT,
    reason           TEXT,
    transcript_path  TEXT
);

CREATE TABLE IF NOT EXISTS session_log_entries (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id            TEXT,
    entry_date            TEXT,
    title                 TEXT,
    goal                  TEXT,
    outcome               TEXT,
    key_decisions         TEXT,
    learnings             TEXT,
    links                 TEXT,
    exported_to_markdown  INTEGER DEFAULT 0,
    created_at            TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(session_id) REFERENCES sessions(session_id)
);

CREATE TABLE IF NOT EXISTS technical_learnings (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    number                INTEGER,
    title                 TEXT,
    problem               TEXT,
    solution              TEXT,
    applies_to            TEXT,
    source_session_id     TEXT,
    exported_to_markdown  INTEGER DEFAULT 0,
    created_at            TEXT DEFAULT CURRENT_TIMESTAMP
);

-- Hot-path indexes for the exporter's SELECT WHERE exported_to_markdown=0
-- scan, plus date-based queries on the session log.
CREATE INDEX IF NOT EXISTS idx_session_log_pending
    ON session_log_entries(exported_to_markdown);
CREATE INDEX IF NOT EXISTS idx_session_log_entry_date
    ON session_log_entries(entry_date);
CREATE INDEX IF NOT EXISTS idx_tech_learnings_pending
    ON technical_learnings(exported_to_markdown);
CREATE INDEX IF NOT EXISTS idx_tech_learnings_created
    ON technical_learnings(created_at);
