#!/usr/bin/env python3
from __future__ import annotations
"""
Regression tests for secure_resolve_vault_path read/write mode split (W14).

Creates an isolated tempdir vault, sets CLAUDE_BRIDGE_VAULT, then imports the
server module functions directly. Tests 10 assertion blocks covering read-existing,
read-missing, write-new-file, write-missing-parent, traversal, blocked-folder,
bad-basename, dispatcher, and backward-compat scenarios.

Run: python3 tests/test-mcp-path-resolution.py
"""

import importlib
import os
import sys
import tempfile
import traceback
from pathlib import Path


TESTS_PASSED = 0
TESTS_FAILED = 0


def ok(name: str) -> None:
    global TESTS_PASSED
    TESTS_PASSED += 1
    print(f"  PASS  {name}")


def fail(name: str, reason: str) -> None:
    global TESTS_FAILED
    TESTS_FAILED += 1
    print(f"  FAIL  {name}: {reason}")


def assert_raises(name: str, fn, exc_type=ValueError) -> None:
    try:
        result = fn()
        fail(name, f"expected {exc_type.__name__} but got {result!r}")
    except exc_type:
        ok(name)
    except Exception as e:
        fail(name, f"expected {exc_type.__name__} but got {type(e).__name__}: {e}")


def assert_returns_path(name: str, fn) -> Path | None:
    try:
        result = fn()
        if isinstance(result, Path):
            ok(name)
            return result
        else:
            fail(name, f"expected Path but got {type(result).__name__}: {result!r}")
            return None
    except Exception as e:
        fail(name, f"unexpected exception {type(e).__name__}: {e}")
        traceback.print_exc()
        return None


def setup_vault() -> tuple[tempfile.TemporaryDirectory, Path]:
    """Create a minimal vault with one existing file."""
    td = tempfile.mkdtemp(prefix=f"mcp-path-test-{os.getpid()}-")
    vault = Path(td)
    knowledge_dir = vault / "07 - Claude Knowledge"
    knowledge_dir.mkdir()
    (knowledge_dir / "Session Log.md").write_text("# Session Log\n## Entry 1\ntest\n")
    # Also create the blocked folder so containment checks are meaningful
    blocked_dir = vault / "05 - Personal"
    blocked_dir.mkdir()
    return td, vault


def _inject_mcp_stubs() -> None:
    """Stub out the mcp SDK so server.py can be imported without it installed."""
    from types import ModuleType

    def _make(name: str) -> ModuleType:
        m = ModuleType(name)
        sys.modules[name] = m
        return m

    if "mcp" not in sys.modules:
        mcp = _make("mcp")
        mcp_server = _make("mcp.server")
        mcp_server_stdio = _make("mcp.server.stdio")
        mcp_types = _make("mcp.types")

        class _Server:
            def __init__(self, *a, **kw): pass
            def list_tools(self): return lambda f: f
            def call_tool(self): return lambda f: f

        class _TextContent:
            def __init__(self, *a, **kw): pass

        class _Tool:
            def __init__(self, *a, **kw): pass

        async def _stdio_server(*a, **kw): pass

        mcp_server.Server = _Server
        mcp_server_stdio.stdio_server = _stdio_server
        mcp_types.TextContent = _TextContent
        mcp_types.Tool = _Tool


def import_server_functions(vault_path: Path):
    """Import the server module with the test vault configured."""
    os.environ["CLAUDE_BRIDGE_VAULT"] = str(vault_path)
    os.environ.setdefault("CLAUDE_BRIDGE_HOME", str(vault_path / ".claude-bridge"))

    _inject_mcp_stubs()

    server_py = Path(__file__).parent.parent / "mcp-servers" / "obsidian-brain" / "server.py"
    spec = importlib.util.spec_from_file_location("obsidian_brain_server_w14", server_py)
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except SystemExit:
        raise
    except Exception as e:
        print(f"ERROR loading server module: {type(e).__name__}: {e}")
        traceback.print_exc()
        sys.exit(1)

    secure_resolve = getattr(mod, "secure_resolve_vault_path", None)
    validate_path = getattr(mod, "validate_vault_path", None)
    if secure_resolve is None or validate_path is None:
        print("ERROR: could not load server functions — check import path")
        sys.exit(1)
    return secure_resolve, validate_path


def run_tests(vault: Path, secure_resolve, validate_path) -> None:
    existing = "07 - Claude Knowledge/Session Log.md"
    missing = "07 - Claude Knowledge/Nope.md"
    new_file = "07 - Claude Knowledge/User Profile.md"
    missing_parent = "99 - Future/Something.md"
    traversal = "../../../etc/passwd"
    blocked = "05 - Personal/Journal.md"
    compound_traversal = "07 - Claude Knowledge/../../evil.md"
    bad_charset = "07 - Claude Knowledge/$(rm rf).md"

    # --- Test 1: READ existing file returns a Path pointing at the file ---
    def t1():
        p = secure_resolve(existing, mode="read")
        assert p.exists(), f"resolved path does not exist on disk: {p}"
        assert p.name == "Session Log.md"
        return p

    print("\nTest 1: READ existing file")
    assert_returns_path("READ existing → Path exists", t1)

    # --- Test 2: READ missing file raises ValueError ---
    print("\nTest 2: READ missing file")
    assert_raises(
        "READ missing → ValueError",
        lambda: secure_resolve(missing, mode="read"),
    )

    # --- Test 3: WRITE new file with existing parent returns Path ---
    def t3():
        p = secure_resolve(new_file, mode="write")
        # Target must NOT exist yet (it's new)
        assert not p.exists(), f"expected non-existent path but it exists: {p}"
        # Parent must exist
        assert p.parent.exists(), f"parent directory does not exist: {p.parent}"
        return p

    print("\nTest 3: WRITE new file with existing parent")
    assert_returns_path("WRITE new-file → non-existent path with existing parent", t3)

    # --- Test 4: WRITE with missing parent raises ValueError ---
    print("\nTest 4: WRITE with missing parent")
    assert_raises(
        "WRITE missing-parent → ValueError",
        lambda: secure_resolve(missing_parent, mode="write"),
    )

    # --- Test 5: WRITE traversal attempt raises ValueError ---
    print("\nTest 5: WRITE traversal attempt (../../../etc/passwd)")
    assert_raises(
        "WRITE traversal → ValueError",
        lambda: secure_resolve(traversal, mode="write"),
    )

    # --- Test 6: WRITE into BLOCKED folder raises ValueError ---
    print("\nTest 6: WRITE into BLOCKED folder")
    assert_raises(
        "WRITE blocked-parent → ValueError",
        lambda: secure_resolve(blocked, mode="write"),
    )

    # --- Test 7: WRITE compound traversal raises ValueError ---
    print("\nTest 7: WRITE compound traversal (07-CK/../../evil.md)")
    assert_raises(
        "WRITE compound-traversal → ValueError",
        lambda: secure_resolve(compound_traversal, mode="write"),
    )

    # --- Test 8: WRITE bad basename (shell metacharacters) raises ValueError ---
    print("\nTest 8: WRITE bad charset basename $(rm rf).md")
    assert_raises(
        "WRITE bad-charset-basename → ValueError",
        lambda: secure_resolve(bad_charset, mode="write"),
    )

    # --- Test 9: Unknown mode raises ValueError ---
    print("\nTest 9: Unknown mode dispatcher")
    assert_raises(
        "unknown mode → ValueError",
        lambda: secure_resolve("x", mode="invalid"),
    )

    # --- Test 10: No-mode-kwarg backward compat matches mode='read' ---
    print("\nTest 10: Backward compat (no mode kwarg)")

    def t10():
        # Existing file should work without mode kwarg
        p_no_kwarg = secure_resolve(existing)
        p_read = secure_resolve(existing, mode="read")
        assert p_no_kwarg == p_read, (
            f"default mode differs from mode='read': {p_no_kwarg!r} vs {p_read!r}"
        )
        # Missing file should raise without mode kwarg
        try:
            secure_resolve(missing)
            return False  # should have raised
        except ValueError:
            return True  # correct

    try:
        result = t10()
        if result:
            ok("no-kwarg default == mode='read' (existing works, missing raises)")
        else:
            fail("no-kwarg default == mode='read'", "missing file did not raise ValueError")
    except Exception as e:
        fail("no-kwarg default == mode='read'", f"{type(e).__name__}: {e}")

    # --- Bonus: validate_vault_path mode='write' returns None on reject cases ---
    print("\nBonus: validate_vault_path write-mode returns None on reject")

    def bonus():
        r1 = validate_path(missing_parent, mode="write")
        assert r1 is None, f"expected None for missing parent, got {r1!r}"
        r2 = validate_path(traversal, mode="write")
        assert r2 is None, f"expected None for traversal, got {r2!r}"
        r3 = validate_path(new_file, mode="write")
        assert isinstance(r3, Path), f"expected Path for valid write target, got {r3!r}"
        return True

    try:
        bonus()
        ok("validate_vault_path write-mode: None on reject, Path on valid")
    except AssertionError as e:
        fail("validate_vault_path write-mode", str(e))
    except Exception as e:
        fail("validate_vault_path write-mode", f"{type(e).__name__}: {e}")


def main() -> int:
    import importlib.util

    print("=" * 60)
    print("MCP path resolution test suite (W14)")
    print("=" * 60)

    td, vault = setup_vault()
    print(f"\nVault: {vault}")
    print(f"Existing: {vault / '07 - Claude Knowledge' / 'Session Log.md'}")

    try:
        secure_resolve, validate_path = import_server_functions(vault)
        run_tests(vault, secure_resolve, validate_path)
    finally:
        import shutil
        shutil.rmtree(td, ignore_errors=True)

    print("\n" + "=" * 60)
    print(f"Results: {TESTS_PASSED} passed, {TESTS_FAILED} failed")
    print("=" * 60)

    return 0 if TESTS_FAILED == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
