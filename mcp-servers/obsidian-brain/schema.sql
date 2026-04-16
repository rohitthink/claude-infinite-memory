-- SQLite schema for the obsidian-brain MCP server's semantic-search index.
--
-- Purpose: give Claude Code fast cosine-similarity lookups across your
-- Obsidian vault. Each file is chunked at heading boundaries into ~500-token
-- sections; every chunk is embedded via Ollama nomic-embed-text (768-dim) or
-- a hash-based fallback (256-dim). Embeddings are stored as raw
-- little-endian float32 BLOBs for cheap struct-unpack.
--
-- THIS DATABASE IS A DISPOSABLE CACHE.
--   - Not synced anywhere (lives only on this machine's local disk).
--   - Not inside the vault (kept outside to keep a vault clone free of
--     index artifacts).
--   - Rebuildable from the vault at any time via `indexer.py --full-rebuild`.
--
-- Journaling is WAL so the indexer's writes don't block search reads.

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

-- One row per indexed file. Used for incremental re-indexing: the indexer
-- compares stored mtime to the filesystem's mtime and skips unchanged files.
CREATE TABLE IF NOT EXISTS files (
    file_path        TEXT PRIMARY KEY,    -- vault-relative path (e.g. "07 - Claude Knowledge/Technical Learnings.md")
    abs_path         TEXT NOT NULL,       -- realpath of the file at index time (validation aid)
    mtime            REAL NOT NULL,       -- os.stat().st_mtime at last index
    size_bytes       INTEGER NOT NULL,
    chunk_count      INTEGER NOT NULL,
    indexed_at       TEXT DEFAULT CURRENT_TIMESTAMP
);

-- One row per chunk. A chunk is a heading-bounded span of ~500 tokens.
-- embedding is a raw bytes blob of little-endian float32s; dim matches the
-- embedder's output (768 for nomic-embed-text, 256 for the hash fallback).
CREATE TABLE IF NOT EXISTS chunks (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path        TEXT NOT NULL,       -- vault-relative, FK into files
    chunk_idx        INTEGER NOT NULL,    -- 0-based position within the file
    headline         TEXT,                -- nearest markdown heading above this chunk
    chunk_text       TEXT NOT NULL,       -- raw chunk content (for excerpt rendering)
    embedding        BLOB NOT NULL,       -- float32 little-endian packed
    dim              INTEGER NOT NULL,    -- vector dimension
    embedder         TEXT NOT NULL,       -- 'nomic-embed-text' or 'hash-fallback'
    created_at       TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(file_path) REFERENCES files(file_path) ON DELETE CASCADE
);

-- Tags extracted from frontmatter + inline #tags. Stored flat for list_topics.
CREATE TABLE IF NOT EXISTS tags (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    tag              TEXT NOT NULL,
    file_path        TEXT NOT NULL,
    source           TEXT NOT NULL,       -- 'frontmatter' | 'inline'
    FOREIGN KEY(file_path) REFERENCES files(file_path) ON DELETE CASCADE,
    UNIQUE(tag, file_path, source)
);

-- Indexes for the indexer's incremental re-index SELECT ... WHERE mtime != ?
-- and the server's list_topics DISTINCT tag scan.
CREATE INDEX IF NOT EXISTS idx_files_mtime ON files(mtime);
CREATE INDEX IF NOT EXISTS idx_chunks_file_path ON chunks(file_path);
CREATE INDEX IF NOT EXISTS idx_tags_tag ON tags(tag);
CREATE INDEX IF NOT EXISTS idx_tags_file_path ON tags(file_path);
