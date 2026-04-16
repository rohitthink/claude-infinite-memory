#!/usr/bin/env python3
"""
obsidian-brain MCP server
=========================

Gives Claude Code semantic-search access to your Obsidian vault. Runs
over stdio. Exposes four tools:

  - search_vault(query, limit)    top-N semantic matches
  - get_file(path)                fetch a vault-relative file (path-guarded)
  - list_topics()                 distinct tags from frontmatter + inline
  - recent_entries(category, limit) last N entries in a known category

Content returned by any tool is passed through the same 17-category regex
redaction used by the SessionEnd vault-sync hook so the MCP can't be used
as a secret-exfil channel if the vault itself gets compromised.

The server re-uses the same SQLite index built by indexer.py. It does NOT
re-index on its own  the launchd daemon indexer-daemon.sh handles that
every 5 minutes. On startup the server does a lazy check of the DB age
and warns (but doesn't fail) if it's more than 1 hour stale.

Configuration via environment variables:
  CLAUDE_BRIDGE_HOME   where the index DB lives (defaults to ~/.claude)
  CLAUDE_BRIDGE_VAULT  path to the Obsidian vault root (REQUIRED)
  CLAUDE_BRIDGE_OLLAMA_HOST  Ollama endpoint (defaults to http://localhost:11434)
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import os
import re
import sqlite3
import struct
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

try:
    from mcp.server import Server
    from mcp.server.stdio import stdio_server
    from mcp.types import TextContent, Tool
except ImportError as e:
    sys.stderr.write(
        f"ERROR: mcp SDK not importable: {e}\n"
        "Install with: python3 -m pip install --user mcp\n"
        "Or inside a venv: python3 -m venv .venv && source .venv/bin/activate && pip install mcp\n"
    )
    raise

# ---------------------------------------------------------------------------
# Configuration (kept in sync with indexer.py)
# ---------------------------------------------------------------------------

def _require_env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        sys.stderr.write(f"ERROR: required env var {name} is not set\n")
        sys.exit(1)
    return v


CLAUDE_BRIDGE_HOME = Path(os.environ.get("CLAUDE_BRIDGE_HOME", str(Path.home() / ".claude"))).expanduser()
VAULT_ROOT = Path(_require_env("CLAUDE_BRIDGE_VAULT")).expanduser().resolve()
DB_PATH = CLAUDE_BRIDGE_HOME / "mcp-servers" / "obsidian-brain" / "index.db"
LOG_PATH = CLAUDE_BRIDGE_HOME / "logs" / "obsidian-brain-server.log"

# Folders that get_file refuses to read, and that search_vault filters out
# even if a chunk somehow ended up indexed. The Personal folder is marked
# private in the obsidian-sync skill.
BLOCKED_FOLDERS = {"05 - Personal"}

OLLAMA_HOSTS = [
    os.environ.get("CLAUDE_BRIDGE_OLLAMA_HOST", "http://localhost:11434"),
    "http://localhost:11434",
]
OLLAMA_MODEL = "nomic-embed-text"
OLLAMA_TIMEOUT_S = 8.0

HASH_FALLBACK_DIM = 256

# Known categories for recent_entries  maps to a canonical vault file.
# "session_log_device" is included but resolved dynamically to the current host.
CATEGORY_FILES = {
    "session_log": "07 - Claude Knowledge/Session Log.md",
    "technical_learnings": "07 - Claude Knowledge/Technical Learnings.md",
    "skills_tools": "07 - Claude Knowledge/Skills & Tools Index.md",
    "automation_stack": "07 - Claude Knowledge/Automation Stack.md",
    "workflow_patterns": "07 - Claude Knowledge/Workflow Patterns.md",
    "sync_log": "07 - Claude Knowledge/Sync Log.md",
    "user_profile": "07 - Claude Knowledge/User Profile.md",
}

# Max chars returned by get_file to keep responses bounded.
GET_FILE_MAX_BYTES = 512 * 1024  # 512 KB


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def setup_logging() -> logging.Logger:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("obsidian-brain-server")
    if logger.handlers:
        return logger
    logger.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S")
    fh = logging.FileHandler(LOG_PATH)
    fh.setFormatter(fmt)
    logger.addHandler(fh)
    # MCP servers communicate over stdout/stdin  never log to stdout,
    # only stderr.
    sh = logging.StreamHandler(sys.stderr)
    sh.setFormatter(fmt)
    logger.addHandler(sh)
    return logger


logger = setup_logging()


# ---------------------------------------------------------------------------
# Secret redaction
# ---------------------------------------------------------------------------

# Mirrors the sed rules in hooks/session-end-vault-sync.sh so
# any content leaving this server via a tool response has the same secret-
# pattern scrub applied. Reason: the vault may be synced to a cloud service
# and could in principle contain a leaked token that slipped past the
# ingestion filter; the MCP server must not be a second exfiltration vector
# on query.
#
# 17 distinct categories cover the biggest leak families. Not exhaustive
# this is defense-in-depth, not the primary guarantee.
REDACTIONS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"ghp_[A-Za-z0-9]{36}"), "[REDACTED_GITHUB_PAT]"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{80,}"), "[REDACTED_GITHUB_FGPAT]"),
    (re.compile(r"gho_[A-Za-z0-9]{36}"), "[REDACTED_GITHUB_OAUTH]"),
    (re.compile(r"AKIA[A-Z0-9]{16}"), "[REDACTED_AWS_ACCESS_KEY]"),
    (re.compile(r"ASIA[A-Z0-9]{16}"), "[REDACTED_AWS_STS_KEY]"),
    (re.compile(r"sk-ant-[A-Za-z0-9_\-]{20,}"), "[REDACTED_ANTHROPIC_KEY]"),
    (re.compile(r"sk-proj-[A-Za-z0-9_\-]{20,}"), "[REDACTED_OPENAI_PROJECT_KEY]"),
    (re.compile(r"sk-[A-Za-z0-9]{20,}"), "[REDACTED_OPENAI_KEY]"),
    (re.compile(r"AIza[A-Za-z0-9_\-]{35}"), "[REDACTED_GOOGLE_API_KEY]"),
    (re.compile(r"ya29\.[A-Za-z0-9_\-]+"), "[REDACTED_GOOGLE_OAUTH]"),
    (re.compile(r"xox[abpr]-[A-Za-z0-9\-]{10,}"), "[REDACTED_SLACK_TOKEN]"),
    (re.compile(r"glpat-[A-Za-z0-9_\-]{20}"), "[REDACTED_GITLAB_PAT]"),
    (
        re.compile(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"),
        "[REDACTED_JWT]",
    ),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "[REDACTED_PRIVATE_KEY_START]"),
    (re.compile(r"-----END [A-Z ]*PRIVATE KEY-----"), "[REDACTED_PRIVATE_KEY_END]"),
    # Generic password/secret/api_key/bearer assignment, e.g. `password=hunter22`.
    (
        re.compile(
            r"(password|passwd|passwort|secret|api[_-]?key|auth[_-]?token|bearer)[\s\"':=]+[A-Za-z0-9!@#$%^&*()_+=/\-]{8,}",
            re.IGNORECASE,
        ),
        lambda m: f"{m.group(1)}=[REDACTED_SECRET]",
    ),
    # Unquoted bare tokens after common labels (e.g. `Authorization: Bearer eyJ...`)
    (
        re.compile(r"(Authorization:\s*Bearer)\s+[A-Za-z0-9._\-]{20,}", re.IGNORECASE),
        r"\1 [REDACTED_BEARER]",
    ),
]


def redact(text: str) -> str:
    out = text
    for pat, repl in REDACTIONS:
        if callable(repl):
            out = pat.sub(repl, out)
        else:
            out = pat.sub(repl, out)
    return out


# ---------------------------------------------------------------------------
# Shell-injection prefilter
# ---------------------------------------------------------------------------

# We don't execute user queries as shell, but a query that looks like a shell
# payload is almost certainly either an attack probe or accidental paste
# log + reject rather than embed it. Checks for backticks, $(...), and
# clear chaining (; & | followed by something).
SHELL_INJECTION_PATTERNS: list[re.Pattern[str]] = [
    re.compile(r"`[^`]{0,200}`"),                         # backticks
    re.compile(r"\$\([^)]{0,200}\)"),                     # $(...)
    re.compile(r"(?:^|\s)(?:rm\s+-rf|curl\s+[^\s]+\s*\|)"),  # overt shell calls
    re.compile(r"[;&|]{2,}"),                             # ;;, &&, ||
]


def looks_like_shell_injection(q: str) -> bool:
    if len(q) > 4000:
        return True
    for pat in SHELL_INJECTION_PATTERNS:
        if pat.search(q):
            return True
    return False


# ---------------------------------------------------------------------------
# Path validation
# ---------------------------------------------------------------------------

def validate_vault_path(rel_path: str) -> Path | None:
    """
    Resolve a vault-relative path and verify (via realpath) it is inside
    VAULT_ROOT and not in a blocked folder. Returns the resolved Path or
    None if the path is invalid/blocked.
    """
    try:
        raw = (VAULT_ROOT / rel_path)
        resolved = raw.resolve()
    except (OSError, RuntimeError):
        return None

    # realpath containment check.
    try:
        resolved.relative_to(VAULT_ROOT)
    except ValueError:
        return None

    # Blocked-folder check on the vault-relative parts.
    rel_parts = resolved.relative_to(VAULT_ROOT).parts
    if rel_parts and rel_parts[0] in BLOCKED_FOLDERS:
        return None

    return resolved


# ---------------------------------------------------------------------------
# Embedding the query
# ---------------------------------------------------------------------------

_query_embedder_cache: dict[str, Any] = {}


def _probe_ollama(host: str) -> bool:
    try:
        req = urllib.request.Request(f"{host}/api/tags")
        with urllib.request.urlopen(req, timeout=OLLAMA_TIMEOUT_S) as resp:
            return resp.status == 200
    except Exception:
        return False


def _embed_ollama(host: str, text: str) -> list[float] | None:
    try:
        payload = json.dumps({"model": OLLAMA_MODEL, "prompt": text}).encode("utf-8")
        req = urllib.request.Request(
            f"{host}/api/embeddings",
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=OLLAMA_TIMEOUT_S) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        vec = data.get("embedding") or (data.get("embeddings") or [None])[0]
        return vec
    except Exception as e:
        logger.warning(f"Ollama embed failed on {host}: {e}")
        return None


def _hash_embed(text: str, dim: int = HASH_FALLBACK_DIM) -> list[float]:
    import hashlib
    vec = [0.0] * dim
    tokens = re.findall(r"[A-Za-z0-9_]+", text.lower())
    if not tokens:
        return vec
    for tok in tokens:
        h = hashlib.sha256(tok.encode("utf-8")).digest()
        for i in range(dim):
            byte = h[i % len(h)]
            vec[i] += (byte / 255.0) - 0.5
    norm = math.sqrt(sum(v * v for v in vec))
    if norm > 0:
        vec = [v / norm for v in vec]
    return vec


def embed_query(text: str, target_backend: str) -> tuple[list[float], str]:
    """
    Produce an embedding for the query that matches the backend the index
    was built with. If the index has Ollama embeddings but Ollama is
    unreachable, we fall back to hash-embedding BOTH query and index chunks
    but that'd require re-embedding the index, which we can't do at query
    time. Instead we log a mismatch warning and return a zero vector so
    results degrade gracefully to empty rather than producing garbage.
    """
    if target_backend == "hash-fallback":
        return (_hash_embed(text), "hash-fallback")

    # target_backend = nomic-embed-text (or similar) -> try Ollama hosts.
    cached_host = _query_embedder_cache.get("host")
    hosts = [cached_host] + OLLAMA_HOSTS if cached_host else list(OLLAMA_HOSTS)
    for host in hosts:
        if not host:
            continue
        if host not in _query_embedder_cache.get("_probed", set()):
            if _probe_ollama(host):
                _query_embedder_cache.setdefault("_probed", set()).add(host)
            else:
                continue
        vec = _embed_ollama(host, text)
        if vec:
            _query_embedder_cache["host"] = host
            return (vec, OLLAMA_MODEL)

    logger.warning(
        "Index was built with Ollama embeddings but Ollama is unreachable at "
        "query time. Returning empty results. Start Ollama or rebuild the "
        "index with --full-rebuild under hash-fallback to query offline."
    )
    return ([], "unavailable")


# ---------------------------------------------------------------------------
# Search / cosine similarity
# ---------------------------------------------------------------------------

def unpack_embedding(blob: bytes, dim: int) -> list[float]:
    return list(struct.unpack(f"<{dim}f", blob))


def cosine(a: list[float], b: list[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


def excerpt(text: str, max_chars: int = 350) -> str:
    """First ~max_chars of the chunk, collapsing whitespace for readable preview."""
    collapsed = re.sub(r"\s+", " ", text).strip()
    if len(collapsed) <= max_chars:
        return collapsed
    return collapsed[: max_chars - 1] + "\u2026"


def open_db() -> sqlite3.Connection:
    if not DB_PATH.exists():
        raise RuntimeError(
            f"Index not found at {DB_PATH}. "
            "Run `python3 indexer.py --full-rebuild` first."
        )
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.execute("PRAGMA query_only=ON")
    return conn


# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

def tool_search_vault(query: str, limit: int = 5) -> list[dict]:
    q = (query or "").strip()
    if not q:
        return []
    if looks_like_shell_injection(q):
        logger.warning(f"rejected search query (shell-injection heuristic): {q[:120]!r}")
        return []

    limit = max(1, min(int(limit or 5), 50))

    conn = open_db()
    try:
        row = conn.execute("SELECT embedder, dim FROM chunks LIMIT 1").fetchone()
        if not row:
            return []
        backend, index_dim = row[0], row[1]

        qvec, q_backend = embed_query(q, backend)
        if not qvec or len(qvec) != index_dim:
            if not qvec:
                return []
            logger.warning(
                f"query vector dim {len(qvec)} != index dim {index_dim}; "
                "re-index with the current backend to search."
            )
            return []

        rows = conn.execute(
            """
            SELECT c.file_path, c.chunk_idx, c.headline, c.chunk_text,
                   c.embedding, c.dim, c.embedder
            FROM chunks c
            """
        ).fetchall()
    finally:
        conn.close()

    scored: list[tuple[float, str, int, str, str]] = []
    for fp, idx, headline, text, emb_blob, dim, _embedder in rows:
        if dim != index_dim:
            continue
        rel_parts = Path(fp).parts
        if rel_parts and rel_parts[0] in BLOCKED_FOLDERS:
            continue
        try:
            cvec = unpack_embedding(emb_blob, dim)
        except Exception:
            continue
        score = cosine(qvec, cvec)
        scored.append((score, fp, idx, headline or "", text))

    scored.sort(key=lambda x: x[0], reverse=True)
    top = scored[:limit]

    results: list[dict] = []
    for score, fp, idx, headline, text in top:
        results.append({
            "file_path": fp,
            "chunk_idx": idx,
            "headline": redact(headline),
            "excerpt": redact(excerpt(text)),
            "similarity": round(score, 4),
            "backend": backend,
        })
    return results


def tool_get_file(path: str) -> str:
    if not path:
        return "ERROR: empty path"
    resolved = validate_vault_path(path)
    if resolved is None:
        logger.warning(f"rejected get_file for {path!r} (outside vault or blocked)")
        return f"ERROR: path rejected (outside vault, nonexistent, or in a blocked folder): {path}"
    if not resolved.is_file():
        return f"ERROR: not a file: {path}"
    try:
        data = resolved.read_bytes()
    except Exception as e:
        return f"ERROR: read failed: {e}"
    if len(data) > GET_FILE_MAX_BYTES:
        data = data[:GET_FILE_MAX_BYTES]
        truncated_note = f"\n\n[... truncated at {GET_FILE_MAX_BYTES} bytes ...]"
    else:
        truncated_note = ""
    try:
        text = data.decode("utf-8", errors="replace")
    except Exception as e:
        return f"ERROR: decode failed: {e}"
    return redact(text) + truncated_note


def tool_list_topics() -> list[str]:
    conn = open_db()
    try:
        rows = conn.execute(
            "SELECT DISTINCT tag FROM tags ORDER BY tag COLLATE NOCASE"
        ).fetchall()
    finally:
        conn.close()
    return [redact(r[0]) for r in rows if r[0]]


def tool_recent_entries(category: str, limit: int = 10) -> list[dict]:
    """
    Return the last N "entries" in a known category file. Heuristic: we
    treat each `## ` heading as an entry boundary (matches the Technical
    Learnings / Session Log / Skills Index convention in the vault). Most
    recent means "last in file" since entries in these files are appended.
    """
    if category not in CATEGORY_FILES:
        return [{"error": f"unknown category: {category}. known: {sorted(CATEGORY_FILES.keys())}"}]
    rel = CATEGORY_FILES[category]
    resolved = validate_vault_path(rel)
    if resolved is None or not resolved.is_file():
        return [{"error": f"category file missing: {rel}"}]

    text = resolved.read_text(encoding="utf-8", errors="replace")
    # Strip frontmatter.
    text = re.sub(r"^---\n.*?\n---\n", "", text, count=1, flags=re.DOTALL)

    # Split on `## ` headings (level-2). Keep the heading with its body.
    parts = re.split(r"(?m)^(?=##\s+)", text)
    entries: list[dict] = []
    for part in parts:
        stripped = part.strip()
        if not stripped.startswith("## "):
            continue
        first_line, _, body = stripped.partition("\n")
        entries.append({
            "title": redact(first_line.lstrip("#").strip()),
            "excerpt": redact(excerpt(body)),
            "file_path": rel,
        })

    limit = max(1, min(int(limit or 10), 50))
    # "Recent" = tail of the file (these vault docs append).
    return entries[-limit:][::-1]  # last N, newest first


# ---------------------------------------------------------------------------
# MCP server wiring
# ---------------------------------------------------------------------------

server = Server("obsidian-brain")


@server.list_tools()
async def handle_list_tools() -> list[Tool]:
    return [
        Tool(
            name="search_vault",
            description=(
                "Semantic search across your Obsidian vault. Returns top-N chunks "
                "(file path, nearest heading, excerpt, cosine similarity) ranked by "
                "similarity to the query. Uses local nomic-embed-text via Ollama."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Natural-language search query."},
                    "limit": {
                        "type": "integer", "default": 5, "minimum": 1, "maximum": 50,
                        "description": "Max results to return.",
                    },
                },
                "required": ["query"],
            },
        ),
        Tool(
            name="get_file",
            description=(
                "Read a single vault-relative markdown file. Path is validated against "
                "the vault root via realpath; paths outside the vault or inside the "
                "'05 - Personal' folder are refused."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Vault-relative path, e.g. '07 - Claude Knowledge/Session Log.md'.",
                    },
                },
                "required": ["path"],
            },
        ),
        Tool(
            name="list_topics",
            description="Return distinct tags found in vault frontmatter and inline #tags.",
            inputSchema={"type": "object", "properties": {}, "required": []},
        ),
        Tool(
            name="recent_entries",
            description=(
                "Return the last N level-2-heading entries in a canonical category "
                "file (session_log, technical_learnings, skills_tools, automation_stack, "
                "workflow_patterns, sync_log, user_profile)."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "category": {
                        "type": "string",
                        "enum": list(CATEGORY_FILES.keys()),
                        "description": "Canonical category name.",
                    },
                    "limit": {
                        "type": "integer", "default": 10, "minimum": 1, "maximum": 50,
                    },
                },
                "required": ["category"],
            },
        ),
    ]


@server.call_tool()
async def handle_call_tool(name: str, arguments: dict[str, Any] | None) -> list[TextContent]:
    arguments = arguments or {}
    try:
        if name == "search_vault":
            result = tool_search_vault(arguments.get("query", ""), arguments.get("limit", 5))
        elif name == "get_file":
            result = tool_get_file(arguments.get("path", ""))
        elif name == "list_topics":
            result = tool_list_topics()
        elif name == "recent_entries":
            result = tool_recent_entries(
                arguments.get("category", ""), arguments.get("limit", 10)
            )
        else:
            return [TextContent(type="text", text=f"ERROR: unknown tool {name!r}")]
    except Exception as e:
        logger.exception(f"tool {name} crashed: {e}")
        return [TextContent(type="text", text=f"ERROR: {e}")]

    if isinstance(result, str):
        return [TextContent(type="text", text=result)]
    return [TextContent(type="text", text=json.dumps(result, ensure_ascii=False, indent=2))]


def check_index_age() -> None:
    if not DB_PATH.exists():
        logger.warning(f"index DB missing at {DB_PATH}. Run indexer.py --full-rebuild.")
        return
    age_s = time.time() - DB_PATH.stat().st_mtime
    if age_s > 3600:
        logger.warning(f"index DB is {age_s / 60:.1f} minutes stale  is the daemon running?")


async def main() -> None:
    check_index_age()
    logger.info(f"obsidian-brain starting; vault={VAULT_ROOT} db={DB_PATH}")
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream, write_stream, server.create_initialization_options()
        )


if __name__ == "__main__":
    asyncio.run(main())
