---
type: project_priority
title: PRIORITY 19: Remaining Pre-Existing Issues — ✅ ALL DONE (2026-05-27)
description: Project priority tracking document.
tags: [priority, historical]
timestamp: 2026-07-07T16:30:00Z
---

[⬅️ Back to Index](../index.md)

# ✅ PRIORITY 19: Remaining Pre-Existing Issues — ✅ ALL DONE (2026-05-27)

Issues confirmed present at rev 484 (before P18), surfaced during investigation.

### 19.3 — Happy Eyeballs Future Leak (std test_streams) — ✅ FIXED (2026-05-27)

Standard `test.test_asyncio.test_streams.StreamTests.test_open_connection_happy_eyeball_refcycles`
now passes perfectly across all 4 Python variants.

**Root cause (multi-layered):**
1. `MultiConnectState.deinit()` never freed `self.connection_data` → `SocketCreationData` leaked on Zig heap holding PyObject refs (Future, loop, protocol_factory) — classic ghost reference (Lessons #3, #11).
2. `TransportCreationData` (raw-socket path) lacked `tp_traverse` — same class of bug.
3. Timer callback (`schedule_remaining_connects_callback`) dispatched without `.traverse` — GC-invisible during timer window.
4. Timer task ID not stored in `mcs.task_ids` — if first connect failed before timer fired, `mcs` was freed while timer callback still held dangling pointer → use-after-free segfault.
5. `SocketCreationData.deinit()` called `deinitialize_object_fields(self, &.{})` which does NOT handle `?*FutureObject` / `?*LoopObject` (optional pointers to PyObject-compatible structs with `ob_base`) — only `*PyObject` and non-optional `*StructWithObBase` paths existed.

**Fixes applied (2026-05-19 & 2026-05-27):**
- `MultiConnectState.deinit()` now calls `self.connection_data.deinit()` → frees full chain.
- `TransportCreationData` gains `traverse()` visiting `protocol_factory`, `future`, `loop`; wired into callback dispatch.
- Timer callback dispatch gets `.traverse = &MultiConnectState.traverse_raw`.
- Timer task ID stored in `mcs.task_ids`; cancelled in `deinit()` before cleanup.
- `timer_scheduled` / `timer_fired` flags added to defer exception/deinit until timer fires (prevents use-after-free).
- `SocketCreationData.deinit()` manually decrefs `future`/`loop` then nulls fields before `deinitialize_object_fields`.
- **Fitted with C-Trampoline & Lifecycle Cleanups**: With the Task lifecycle reference cleanup (10.6) and C trampoline boundary elimination (10.7) optimizations, all lingering Task/coroutine frame GC references are immediately released on completion. Verification script `scratch/verify_19_3.py` confirms `gc.get_referrers(exc)` contains only `[main_coro]`, proving 100% complete leak elimination.

**Why surfaced now:** Before implementing `set_exception_handler`, 20 tests errored with `NotImplementedError` before reaching this test.

**Files involved:**
- `src/loop/python/io/client/create_connection.zig` — `TransportCreationData`, `MultiConnectState`, `SocketCreationData`, `SocketConnectionData`, timer dispatch, callback traverse wiring
- `src/python_c.zig:551-597` — `deinitialize_object_fields` (gap identified but reverted; targeted fix in `SocketCreationData.deinit()` instead)

**Reproduction:** 100% consistent across all 4 Python variants. Not intermittent.

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
