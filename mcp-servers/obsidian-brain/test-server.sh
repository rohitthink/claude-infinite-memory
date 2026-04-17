#!/bin/bash
# End-to-end smoke test for obsidian-brain.
#
# Runs:
#   1. Indexer (ensures DB is built).
#   2. Direct-call tests of each tool function via a small Python harness
#      that imports server.py and invokes the underlying tool_* helpers
#      without the full MCP stdio dance. This lets us check logic without
#      wiring up an MCP client just for CI.
#   3. A minimal stdio-transport exercise: spawns server.py, sends an
#      initialize + list_tools + call_tool sequence, and parses responses.
#
# Exits 0 on all-pass, 1 on any failure.
#
# Required env (typically provided by config.template.sh):
#   CLAUDE_BRIDGE_HOME    defaults to ~/.claude
#   CLAUDE_BRIDGE_VAULT   REQUIRED  path to your Obsidian vault
#   CLAUDE_BRIDGE_PYTHON  defaults to /opt/homebrew/bin/python3

set -uo pipefail

CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
PYTHON="${CLAUDE_BRIDGE_PYTHON:-/opt/homebrew/bin/python3}"
BRAIN_DIR="${CLAUDE_BRIDGE_HOME}/mcp-servers/obsidian-brain"
LOG="/tmp/obsidian-brain-test.log"

if [[ -z "${CLAUDE_BRIDGE_VAULT:-}" ]]; then
  echo "SKIP: CLAUDE_BRIDGE_VAULT env var not set (this test indexes a real vault; not meaningful on CI)"
  exit 77   # Autoconf skip convention; harness interprets as SKIP
fi

fail() {
  echo "FAIL: $*"
  echo "  see $LOG for details"
  exit 1
}

pass() {
  echo "PASS: $*"
}

: > "$LOG"
echo "=== obsidian-brain test-server.sh ==="
echo "log: $LOG"

# 1. Python + mcp package available.
if ! "$PYTHON" -c "import mcp" 2>>"$LOG"; then
  fail "mcp SDK not installed on $PYTHON. Run: $PYTHON -m pip install --break-system-packages mcp"
fi
pass "python + mcp SDK available"

# 2. Indexer runs + DB exists.
echo "--- running indexer (incremental) ---" | tee -a "$LOG"
if ! "$PYTHON" "$BRAIN_DIR/indexer.py" --quiet >>"$LOG" 2>&1; then
  fail "indexer.py failed"
fi
if [[ ! -s "$BRAIN_DIR/index.db" ]]; then
  fail "index.db not created"
fi
db_size=$(stat -f "%z" "$BRAIN_DIR/index.db" 2>/dev/null || stat -c "%s" "$BRAIN_DIR/index.db")
pass "index.db present (${db_size} bytes)"

# 3. Row-level sanity checks.
chunk_count=$(sqlite3 "$BRAIN_DIR/index.db" "SELECT COUNT(*) FROM chunks")
file_count=$(sqlite3 "$BRAIN_DIR/index.db" "SELECT COUNT(*) FROM files")
tag_count=$(sqlite3 "$BRAIN_DIR/index.db" "SELECT COUNT(DISTINCT tag) FROM tags")
echo "files=$file_count chunks=$chunk_count distinct_tags=$tag_count" | tee -a "$LOG"
if [[ "$file_count" -lt 1 ]]; then
  fail "expected >= 1 file indexed, got $file_count (is the vault empty?)"
fi
pass "index populated (files=$file_count chunks=$chunk_count tags=$tag_count)"

# 4. Confirm no chunks from blocked folder leaked in.
blocked_chunks=$(sqlite3 "$BRAIN_DIR/index.db" "SELECT COUNT(*) FROM chunks WHERE file_path LIKE '05 - Personal%'")
if [[ "$blocked_chunks" -ne 0 ]]; then
  fail "found $blocked_chunks chunks from blocked folder '05 - Personal'  indexer is leaking"
fi
pass "no chunks from blocked folder '05 - Personal'"

# 5. Direct-call tool tests via the server module.
cat > /tmp/obsidian-brain-tooltest.py <<PYEOF
import json, os, sys
sys.path.insert(0, os.environ["BRAIN_DIR"])
import server as s

fails = []

def check(name, cond, detail=""):
    print(("OK  " if cond else "BAD ") + name + (" :: " + detail if detail else ""))
    if not cond:
        fails.append(name)

# Shell-injection rejection (no vault dependency).
r3 = s.tool_search_vault("\`rm -rf /\`; cat /etc/passwd")
check("search: shell-injection query rejected -> []",
      r3 == [], f"got {r3!r}")

# get_file  path traversal rejected.
bad = s.tool_get_file("../../../etc/passwd")
check("get_file: ../../../etc/passwd rejected", bad.startswith("ERROR:"), bad[:80])

# get_file  blocked folder rejected.
bad2 = s.tool_get_file("05 - Personal/anything.md")
check("get_file: 05 - Personal rejected", bad2.startswith("ERROR:"), bad2[:80])

# list_topics  returns a list.
topics = s.tool_list_topics()
check("list_topics: returns list", isinstance(topics, list), f"count={len(topics)}")

# recent_entries  unknown category returns error.
bad_cat = s.tool_recent_entries("nonexistent", limit=3)
check("recent_entries: unknown category -> error key",
      bool(bad_cat) and "error" in bad_cat[0])

# Redaction sanity.
fake = "token: ghp_" + "A" * 36
red = s.redact(fake)
check("redact: scrubs github PAT", "[REDACTED_GITHUB_PAT]" in red, red)

print(f"=== tool-level tests: {len(fails)} failure(s) ===")
sys.exit(1 if fails else 0)
PYEOF

BRAIN_DIR="$BRAIN_DIR" "$PYTHON" /tmp/obsidian-brain-tooltest.py >>"$LOG" 2>&1
if [[ $? -ne 0 ]]; then
  tail -30 "$LOG"
  fail "tool-level tests failed"
fi
pass "tool-level tests (see $LOG for detail)"

# 6. MCP stdio smoke test: send initialize + list_tools + call_tool.
cat > /tmp/obsidian-brain-mcptest.py <<PYEOF
import asyncio, json, os, sys
from contextlib import AsyncExitStack

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def main():
    params = StdioServerParameters(
        command=os.environ["PYTHON"],
        args=[os.path.join(os.environ["BRAIN_DIR"], "server.py")],
    )
    async with AsyncExitStack() as stack:
        read, write = await stack.enter_async_context(stdio_client(params))
        session = await stack.enter_async_context(ClientSession(read, write))
        await session.initialize()
        tools = await session.list_tools()
        names = sorted(t.name for t in tools.tools)
        print("tools:", names)
        expected = {"search_vault", "get_file", "list_topics", "recent_entries"}
        if set(names) != expected:
            print(f"FAIL: tool set mismatch. got={names} expected={sorted(expected)}")
            sys.exit(1)

        # list_topics  should return a list, possibly empty
        r = await session.call_tool("list_topics", {})
        topics = json.loads(r.content[0].text) if r.content else []
        if not isinstance(topics, list):
            print(f"FAIL: list_topics returned non-list: {r.content[0].text[:200]}")
            sys.exit(1)
        print(f"stdio list_topics: {len(topics)} distinct tags")

        print("OK: stdio MCP exercise passed")

asyncio.run(main())
PYEOF

PYTHON="$PYTHON" BRAIN_DIR="$BRAIN_DIR" "$PYTHON" /tmp/obsidian-brain-mcptest.py >>"$LOG" 2>&1
if [[ $? -ne 0 ]]; then
  tail -40 "$LOG"
  fail "MCP stdio smoke test failed"
fi
pass "MCP stdio smoke test"

echo ""
echo "=== ALL CHECKS PASSED ==="
exit 0
