#!/usr/bin/env python3
"""
obsidian-brain indexer
======================

Walks your Obsidian vault, chunks each markdown file at heading boundaries
into ~500-token sections, embeds each chunk via Ollama nomic-embed-text (with
a hash-based pseudo-embedding fallback if Ollama is unreachable), and stores
everything in a local SQLite database for the MCP server to query.

Incremental by default: files whose mtime hasn't changed are skipped. Pass
--full-rebuild to force re-embedding every file.

This script is safe to run concurrently (WAL mode), but the launchd daemon
wrapper serializes invocations anyway.

Intentional simplicity:
  - No external Python deps (stdlib only). `numpy` is unnecessary  we pack
    float32s with struct and do cosine similarity in pure Python.
  - No LLM involvement in chunking. Heading boundaries + a rough word-count
    approximation of "tokens" are good enough for small vaults.

Configuration via environment variables:
  CLAUDE_BRIDGE_HOME   where the index DB lives (defaults to ~/.claude)
  CLAUDE_BRIDGE_VAULT  path to the Obsidian vault root (REQUIRED)
  CLAUDE_BRIDGE_OLLAMA_HOST  Ollama endpoint (defaults to http://localhost:11434)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import sqlite3
import struct
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

def _require_env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        sys.stderr.write(f"ERROR: required env var {name} is not set\n")
        sys.exit(1)
    return v


CLAUDE_BRIDGE_HOME = Path(os.environ.get("CLAUDE_BRIDGE_HOME", str(Path.home() / ".claude"))).expanduser()
VAULT_ROOT = Path(_require_env("CLAUDE_BRIDGE_VAULT")).expanduser()
DB_PATH = CLAUDE_BRIDGE_HOME / "mcp-servers" / "obsidian-brain" / "index.db"
SCHEMA_PATH = Path(__file__).parent / "schema.sql"
LOG_PATH = CLAUDE_BRIDGE_HOME / "logs" / "obsidian-brain-indexer.log"

# Ollama endpoints: try the configured host first, then localhost. If neither
# responds within OLLAMA_TIMEOUT_S, fall back to the hash pseudo-embedder so
# the pipeline never blocks on Ollama being offline.
OLLAMA_HOSTS = [
    os.environ.get("CLAUDE_BRIDGE_OLLAMA_HOST", "http://localhost:11434"),
    "http://localhost:11434",
]
OLLAMA_MODEL = "nomic-embed-text"
OLLAMA_TIMEOUT_S = 8.0
OLLAMA_EMBED_PATH = "/api/embeddings"

# Target chunk size in "tokens"  we approximate by splitting on whitespace
# and counting words. 500 words is a reasonable semantic unit for markdown.
CHUNK_TARGET_TOKENS = 500
CHUNK_MIN_TOKENS = 30           # merge trailing tiny sections into the previous chunk

# Hash-fallback dimension. Deliberately small so it's obviously-pseudo in logs.
HASH_FALLBACK_DIM = 256

# Folders to fully exclude from indexing. The Personal folder is marked private
# in the obsidian-sync skill  never embed it, never expose it via search.
EXCLUDED_FOLDERS = {"05 - Personal", ".obsidian", ".trash"}


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def setup_logging() -> logging.Logger:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("obsidian-brain-indexer")
    if logger.handlers:
        return logger
    logger.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S")
    fh = logging.FileHandler(LOG_PATH)
    fh.setFormatter(fmt)
    logger.addHandler(fh)
    sh = logging.StreamHandler(sys.stderr)
    sh.setFormatter(fmt)
    logger.addHandler(sh)
    return logger


# ---------------------------------------------------------------------------
# Embedding backends
# ---------------------------------------------------------------------------

@dataclass
class EmbedResult:
    vector: list[float]
    dim: int
    backend: str   # 'nomic-embed-text' or 'hash-fallback'


class OllamaEmbedder:
    """
    Calls Ollama's /api/embeddings endpoint. Picks the first host from
    OLLAMA_HOSTS that responds to /api/tags within OLLAMA_TIMEOUT_S at
    construction time.
    """

    def __init__(self, logger: logging.Logger):
        self.logger = logger
        self.host: str | None = None
        self.dim: int | None = None
        for candidate in OLLAMA_HOSTS:
            if self._probe(candidate):
                self.host = candidate
                break
        if self.host:
            try:
                vec = self._embed_raw("probe")
                self.dim = len(vec)
                self.logger.info(
                    f"Ollama ready: host={self.host} model={OLLAMA_MODEL} dim={self.dim}"
                )
            except Exception as e:
                self.logger.warning(
                    f"Ollama host {self.host} reachable but embed failed: {e}. "
                    f"Hint: `ollama pull {OLLAMA_MODEL}` on that host."
                )
                self.host = None

    def _probe(self, host: str) -> bool:
        try:
            req = urllib.request.Request(f"{host}/api/tags")
            with urllib.request.urlopen(req, timeout=OLLAMA_TIMEOUT_S) as resp:
                return resp.status == 200
        except Exception:
            return False

    def _embed_raw(self, text: str) -> list[float]:
        payload = json.dumps({"model": OLLAMA_MODEL, "prompt": text}).encode("utf-8")
        req = urllib.request.Request(
            f"{self.host}{OLLAMA_EMBED_PATH}",
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=OLLAMA_TIMEOUT_S) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        vec = data.get("embedding") or (data.get("embeddings") or [None])[0]
        if not vec:
            raise RuntimeError(f"Ollama returned no embedding: {data!r}")
        return vec

    def is_available(self) -> bool:
        return self.host is not None

    def embed(self, text: str) -> EmbedResult:
        vec = self._embed_raw(text)
        return EmbedResult(vector=vec, dim=len(vec), backend=OLLAMA_MODEL)


class HashEmbedder:
    """
    Deterministic pseudo-embedder  for when Ollama is offline and we want
    the pipeline to still produce a (usable-in-tests, not-semantically-great)
    result rather than crash. Uses a bag-of-tokens hash projection.
    """

    def __init__(self, logger: logging.Logger):
        self.logger = logger
        self.dim = HASH_FALLBACK_DIM

    def is_available(self) -> bool:
        return True

    def embed(self, text: str) -> EmbedResult:
        vec = [0.0] * self.dim
        tokens = re.findall(r"[A-Za-z0-9_]+", text.lower())
        if not tokens:
            return EmbedResult(vector=vec, dim=self.dim, backend="hash-fallback")
        for tok in tokens:
            h = hashlib.sha256(tok.encode("utf-8")).digest()
            for i in range(self.dim):
                byte = h[i % len(h)]
                vec[i] += (byte / 255.0) - 0.5
        norm = sum(v * v for v in vec) ** 0.5
        if norm > 0:
            vec = [v / norm for v in vec]
        return EmbedResult(vector=vec, dim=self.dim, backend="hash-fallback")


def pack_embedding(vec: list[float]) -> bytes:
    return struct.pack(f"<{len(vec)}f", *vec)


# ---------------------------------------------------------------------------
# Markdown parsing / chunking
# ---------------------------------------------------------------------------

FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n", re.DOTALL)
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*$", re.MULTILINE)
INLINE_TAG_RE = re.compile(r"(?:^|[\s(])#([A-Za-z][A-Za-z0-9/_\-]*)")
CODE_FENCE_RE = re.compile(r"```.*?```", re.DOTALL)


def extract_frontmatter_tags(content: str) -> list[str]:
    m = FRONTMATTER_RE.match(content)
    if not m:
        return []
    fm = m.group(1)
    tags: list[str] = []
    line_match = re.search(r"^tags:\s*\[(.*?)\]", fm, re.MULTILINE)
    if line_match:
        raw = line_match.group(1)
        tags.extend(t.strip().strip("\"'") for t in raw.split(",") if t.strip())
    else:
        list_match = re.search(r"^tags:\s*\n((?:\s*-\s*.+\n?)+)", fm, re.MULTILINE)
        if list_match:
            for line in list_match.group(1).splitlines():
                t = line.strip().lstrip("-").strip().strip("\"'")
                if t:
                    tags.append(t)
    return [t for t in tags if t]


def extract_inline_tags(content: str) -> list[str]:
    stripped = CODE_FENCE_RE.sub("", content)
    return list({m.group(1) for m in INLINE_TAG_RE.finditer(stripped)})


def strip_frontmatter(content: str) -> str:
    return FRONTMATTER_RE.sub("", content, count=1)


@dataclass
class Chunk:
    idx: int
    headline: str
    text: str


def chunk_markdown(content: str) -> list[Chunk]:
    body = strip_frontmatter(content)
    heading_positions: list[tuple[int, str, int]] = []
    for m in HEADING_RE.finditer(body):
        heading_positions.append((m.start(), m.group(2).strip(), len(m.group(1))))

    sections: list[tuple[str, str]] = []
    if not heading_positions:
        sections.append(("(no heading)", body.strip()))
    else:
        first_offset = heading_positions[0][0]
        preamble = body[:first_offset].strip()
        if preamble:
            sections.append(("(preamble)", preamble))
        for i, (off, headline, _level) in enumerate(heading_positions):
            end = heading_positions[i + 1][0] if i + 1 < len(heading_positions) else len(body)
            section_text = body[off:end].strip()
            sections.append((headline, section_text))

    chunks: list[Chunk] = []
    idx = 0
    for headline, section_text in sections:
        if not section_text:
            continue
        words = section_text.split()
        if len(words) <= CHUNK_TARGET_TOKENS:
            chunks.append(Chunk(idx=idx, headline=headline, text=section_text))
            idx += 1
        else:
            for start in range(0, len(words), CHUNK_TARGET_TOKENS):
                sub = " ".join(words[start : start + CHUNK_TARGET_TOKENS])
                chunks.append(Chunk(idx=idx, headline=headline, text=sub))
                idx += 1

    merged: list[Chunk] = []
    for c in chunks:
        if merged and len(c.text.split()) < CHUNK_MIN_TOKENS:
            prev = merged[-1]
            merged[-1] = Chunk(
                idx=prev.idx,
                headline=prev.headline,
                text=prev.text + "\n\n" + c.text,
            )
        else:
            merged.append(c)
    for i, c in enumerate(merged):
        merged[i] = Chunk(idx=i, headline=c.headline, text=c.text)
    return merged


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def init_db(conn: sqlite3.Connection) -> None:
    with open(SCHEMA_PATH) as f:
        conn.executescript(f.read())


def vault_relative(path: Path) -> str:
    return str(path.relative_to(VAULT_ROOT))


def iter_markdown_files() -> Iterable[Path]:
    for path in VAULT_ROOT.rglob("*.md"):
        rel = path.relative_to(VAULT_ROOT)
        top = rel.parts[0] if rel.parts else ""
        if top in EXCLUDED_FOLDERS:
            continue
        if any(p.startswith(".") for p in rel.parts):
            continue
        yield path


# ---------------------------------------------------------------------------
# Main indexing logic
# ---------------------------------------------------------------------------

def index_file(
    conn: sqlite3.Connection,
    path: Path,
    embedder: OllamaEmbedder | HashEmbedder,
    logger: logging.Logger,
    full_rebuild: bool,
) -> tuple[bool, int]:
    rel_path = vault_relative(path)
    try:
        st = path.stat()
    except OSError as e:
        logger.warning(f"stat failed for {rel_path}: {e}")
        return (False, 0)

    row = conn.execute(
        "SELECT mtime, chunk_count FROM files WHERE file_path = ?", (rel_path,)
    ).fetchone()

    if row and not full_rebuild and abs(row[0] - st.st_mtime) < 1e-6:
        return (False, row[1])

    try:
        content = path.read_text(encoding="utf-8")
    except Exception as e:
        logger.warning(f"read failed for {rel_path}: {e}")
        return (False, 0)

    chunks = chunk_markdown(content)
    if not chunks:
        conn.execute(
            """
            INSERT INTO files(file_path, abs_path, mtime, size_bytes, chunk_count)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(file_path) DO UPDATE SET
                abs_path=excluded.abs_path,
                mtime=excluded.mtime,
                size_bytes=excluded.size_bytes,
                chunk_count=excluded.chunk_count,
                indexed_at=CURRENT_TIMESTAMP
            """,
            (rel_path, str(path.resolve()), st.st_mtime, st.st_size, 0),
        )
        conn.execute("DELETE FROM chunks WHERE file_path = ?", (rel_path,))
        conn.execute("DELETE FROM tags WHERE file_path = ?", (rel_path,))
        return (True, 0)

    fallback = HashEmbedder(logger)
    embedded: list[tuple[Chunk, EmbedResult]] = []
    for c in chunks:
        try:
            er = embedder.embed(c.text)
        except Exception as e:
            logger.warning(
                f"embed failed for {rel_path} chunk {c.idx}: {e}. Using hash fallback."
            )
            er = fallback.embed(c.text)
        embedded.append((c, er))

    fm_tags = extract_frontmatter_tags(content)
    inline_tags = extract_inline_tags(content)

    with conn:
        conn.execute(
            """
            INSERT INTO files(file_path, abs_path, mtime, size_bytes, chunk_count)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(file_path) DO UPDATE SET
                abs_path=excluded.abs_path,
                mtime=excluded.mtime,
                size_bytes=excluded.size_bytes,
                chunk_count=excluded.chunk_count,
                indexed_at=CURRENT_TIMESTAMP
            """,
            (rel_path, str(path.resolve()), st.st_mtime, st.st_size, len(chunks)),
        )
        conn.execute("DELETE FROM chunks WHERE file_path = ?", (rel_path,))
        conn.execute("DELETE FROM tags WHERE file_path = ?", (rel_path,))

        conn.executemany(
            """
            INSERT INTO chunks(file_path, chunk_idx, headline, chunk_text, embedding, dim, embedder)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    rel_path,
                    c.idx,
                    c.headline,
                    c.text,
                    pack_embedding(er.vector),
                    er.dim,
                    er.backend,
                )
                for c, er in embedded
            ],
        )

        tag_rows = (
            [(t, rel_path, "frontmatter") for t in fm_tags]
            + [(t, rel_path, "inline") for t in inline_tags]
        )
        if tag_rows:
            conn.executemany(
                "INSERT OR IGNORE INTO tags(tag, file_path, source) VALUES(?, ?, ?)",
                tag_rows,
            )

    return (True, len(chunks))


def garbage_collect_deleted(conn: sqlite3.Connection, logger: logging.Logger) -> int:
    rows = conn.execute("SELECT file_path FROM files").fetchall()
    removed = 0
    with conn:
        for (rel,) in rows:
            if not (VAULT_ROOT / rel).exists():
                conn.execute("DELETE FROM files WHERE file_path = ?", (rel,))
                removed += 1
                logger.info(f"gc: removed stale entry for {rel}")
    return removed


def main() -> int:
    parser = argparse.ArgumentParser(description="Index your Obsidian vault into SQLite.")
    parser.add_argument("--full-rebuild", action="store_true",
                        help="Ignore mtime cache; re-embed every file.")
    parser.add_argument("--quiet", action="store_true", help="Suppress stderr output.")
    args = parser.parse_args()

    logger = setup_logging()
    if args.quiet:
        for h in list(logger.handlers):
            if isinstance(h, logging.StreamHandler) and not isinstance(h, logging.FileHandler):
                logger.removeHandler(h)

    if not VAULT_ROOT.exists():
        logger.error(f"Vault not found at {VAULT_ROOT}. Is the volume mounted?")
        return 1

    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    init_db(conn)

    ollama = OllamaEmbedder(logger)
    if ollama.is_available():
        embedder: OllamaEmbedder | HashEmbedder = ollama
    else:
        logger.warning(
            "Ollama unreachable on all hosts  using hash-fallback embedder. "
            f"To enable semantic search, start Ollama and `ollama pull {OLLAMA_MODEL}`."
        )
        embedder = HashEmbedder(logger)

    t0 = time.time()
    indexed = 0
    skipped = 0
    total_chunks = 0
    files_seen = 0

    for path in iter_markdown_files():
        files_seen += 1
        try:
            did_work, chunk_count = index_file(conn, path, embedder, logger, args.full_rebuild)
        except Exception as e:
            logger.exception(f"index_file crashed for {path}: {e}")
            continue
        total_chunks += chunk_count
        if did_work:
            indexed += 1
            logger.info(f"indexed {vault_relative(path)} ({chunk_count} chunks)")
        else:
            skipped += 1

    gc_removed = garbage_collect_deleted(conn, logger)
    conn.execute("PRAGMA optimize")
    conn.close()

    elapsed = time.time() - t0
    logger.info(
        f"=== Done. files_seen={files_seen} indexed={indexed} skipped={skipped} "
        f"gc_removed={gc_removed} total_chunks={total_chunks} "
        f"elapsed={elapsed:.2f}s backend={getattr(embedder, 'host', 'hash-fallback')} ==="
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
