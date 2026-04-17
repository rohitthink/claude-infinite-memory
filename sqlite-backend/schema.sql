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

-- L2 User Profile: canonical store for user preferences accumulated across sessions.
-- Markdown (User Profile.md) is a DERIVED VIEW rendered by export-to-vault.sh.
-- Concurrent writes are safe: WAL + UNIQUE index deduplicates via upsert.
CREATE TABLE IF NOT EXISTS user_preferences (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    category        TEXT NOT NULL CHECK(category IN
                        ('technical','communication','antipattern','tooling','pending','archive')),
    preference      TEXT NOT NULL,
    source_session  TEXT,
    device_host     TEXT,
    confidence      TEXT CHECK(confidence IN ('low','medium','high')),
    first_seen      TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_reinforced TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    seen_count      INTEGER DEFAULT 1,
    archived_at     TEXT
);

-- Dedup guard: (category, preference) is the business key.
CREATE UNIQUE INDEX IF NOT EXISTS idx_pref_unique
    ON user_preferences(category, preference);

-- Hot-path for export renderer: category + recency sort.
CREATE INDEX IF NOT EXISTS idx_pref_category_recent
    ON user_preferences(category, last_reinforced DESC);
