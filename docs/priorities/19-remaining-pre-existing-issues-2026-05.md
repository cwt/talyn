[⬅️ Back to Index](../todo.md)

# 🔴 PRIORITY 19: Remaining Pre-Existing Issues (2026-05-18)

Issues confirmed present at rev 484 (before P18), surfaced during investigation.

### 19.3 — Happy Eyeballs Future Leak (std test_streams) — 🔴 UNFIXED

Standard `test.test_asyncio.test_streams.StreamTests.test_open_connection_happy_eyeball_refcycles`
fails on ALL 4 Python variants:

```
AssertionError: Lists differ: [<leviathan.Future object at ...>] != []
gc.get_referrers(exc) returns a leviathan Future instead of empty list.
```

**Root cause:** The `create_connection` happy-eyeballs code stores Python exception
objects in `TransportCreationData` or `MultiConnectState` without proper
`tp_traverse`. When a connection fails, the exception is held in a Zig-native
struct that Python GC cannot see. `gc.get_referrers(exc)` finds the leviathan
Future because it holds a reference to `exc` through an invisible path.

**Why surfaced now:** Before implementing `set_exception_handler`, 20 tests errored
with `NotImplementedError` before reaching this test. Now those tests pass, and
this leak test runs and catches the ghost reference.

**Files involved:**
- `src/loop/python/io/client/create_connection.zig:58-69` — `TransportCreationData` has `protocol_factory: PyObject` with no traverse
- `src/loop/python/io/client/create_connection.zig` — `MultiConnectState` stores exception objects
- `src/future/main.zig:17` — `exceptions_queue` traversal added in H5, but this leak is from a different path

**Reproduction:** 100% consistent across all 4 Python variants. Not intermittent.

**Fix approach:** Add `tp_traverse` to `TransportCreationData` / `MultiConnectState`
that visits the exception and protocol_factory fields. Or ensure exception
references are properly dropped (py_decref) when the connection attempt completes.

### 19.1 — set_exception_handler Not Implemented — ✅ FIXED

Loop was missing `set_exception_handler(handler)`. Standard test_streams had 20
tests depending on it. Fixed at `leviathan/loop.py:161-165`.

### 19.2 — AsyncMock GC Crash in Free-Threading — ✅ FIXED

`AsyncMock.__new__` triggers GC during mock init in 3.13t. GC traverses Future
callbacks with dangling PythonGeneric pointers from earlier tests -> segfault.
Fixed by replacing all `AsyncMock()()` with `async def dummy(): pass; dummy()`.
`Future.release()` reordering also narrowed the race window.

### 19.4 — RLIMIT_NOFILE Sensitivity (SSH/tmux) — ✅ FIXED

SSH sessions default to ulimit 1024. Pytest collection and register_files_sparse
need more fds. Fixed with module-level ensure_fd_limit(), graceful fallback for
fixed files, and eventfd callback branching on fixed_files_enabled.
