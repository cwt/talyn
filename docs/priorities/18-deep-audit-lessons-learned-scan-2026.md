---
type: project_priority
title: PRIORITY 18: Deep Audit — Lessons-Learned Scan (2026-05-17)
description: Project priority tracking document.
tags: [priority, historical]
timestamp: 2026-07-07T16:30:00Z
---

[⬅️ Back to Index](../index.md)

# 🔴 PRIORITY 18: Deep Audit — Lessons-Learned Scan (2026-05-17)

Full codebase scan against all 12 lessons + 6 architectural mandates. 49 files, ~8000 LOC.
Results below grouped by severity.

### 🔥 CRITICAL (4) — will crash or silently lose data

| # | Lesson | File:Line | Bug | Fix |
|---|--------|-----------|-----|-----|
| C1 | L5 Resilience | `loop/child_watcher.zig:141-144` | Child exit callback error silently dropped. `PyObject_Call` fails → exception fetched + decref'd → function returns `void` (success). User never knows their child handler crashed. | ✅ **FIXED** — Route exception to loop's `call_exception_handler`. |
| C2 | L5 Resilience | `loop/fs_watcher.zig:119-124` | Same pattern — inotify callback errors silently dropped. `PyObject_Call` returns null → `PyErr_GetRaisedException` + decref → `return`. | ✅ **FIXED** — Route exception to loop's `call_exception_handler`. |
| C3 | L5 Resilience | `transports/subprocess/transport.zig:178-185` | `.CHILD` error branch: both `process_exited` (L178) and `connection_lost` (L184) callbacks silently swallow errors with `PyErr_Clear`. Double loss. | ✅ **FIXED** — Route both to `call_exception_handler`. |
| C4 | M4 Null Discovery | `python_c.zig:266` | `obj.ob_type orelse unreachable` — In Python 3.13t free-threading, `ob_type` CAN be null during concurrent deallocation. Used from dozens of call sites (`is_type`, `type_check`, `long_check`, etc.). | ✅ **FIXED** — `get_type` returns `?*PyTypeObject`, all 9 callers guard with `orelse return`/`orelse return error.PythonError`. |

### 🔶 HIGH (10) — will break under load or leak memory

| # | Lesson | File:Line | Bug | Fix |
|---|--------|-----------|-----|-----|
| H1 | M1 No Panics | `callback_manager.zig:90` | `@panic("RingBuffer overflow")` on static `RingBuffer(N)`. Burst of >524288 callbacks → SIGABRT. No grow mechanism on the static buffer used by `Soon.dispatch`. | ⚠️ Intentional guardrail — production uses `DynamicRingBuffer.push_or_grow()` which auto-grows. Static `RingBuffer(N)` only in unit tests. |
| H2 | M2 EINTR | `loop/runner.zig:248,252,261` | `ring.copy_cqes()` not EINTR-protected. Signal during CQE harvest → error propagates → event loop crashes. 3 unprotected call sites. | ✅ **FIXED** — wrapped in `copy_cqes_eintr_safe()` with `SignalInterrupt` retry loop. |
| H3 | L3 Ghost Refs | `transports/subprocess/transport.zig:9-21` | `SubprocessTransportObject`: 4 PyObject fields (`loop`, `protocol`, `popen`, `returncode`), no `tp_traverse`, no `HAVE_GC`. Cyclic ref through subprocess transport = permanent leak. | ✅ **FIXED** — added `tp_traverse`, `tp_clear`, `HAVE_GC` flag, `PyObject_GC_UnTrack` in dealloc. |
| H4 | L3 Ghost Refs | `loop/unix_signals.zig:17` | `UnixSignals.callbacks` BTree stores PyObject refs in `callback.data.user_data`. Never traversed by `loop_traverse`. Signal handler callbacks are ghost refs from GC's perspective. | ✅ **FIXED** — added `UnixSignals.traverse()` with btree node walk; guarded with `fd < 0` for uninitialized state; called from `loop_traverse`. |
| H5 | L3 Ghost Refs | `future/main.zig:17` | `exceptions_queue: ArrayList(?*PyObject)` not traversed by `future_traverse`. Exception refs from `ExceptionGroup` aggregation invisible to GC. | ✅ **FIXED** — added traversal of `exceptions_queue.items` in `future_traverse`. |
| H6 | M3 Thread Safety | `loop/scheduling/soon.zig:22-28` | `dispatch_guaranteed_nonthreadsafe` doesn't check `ring_blocked` / write eventfd. Callbacks dispatched while loop is blocked → loop sleeps forever waiting for IO that may never arrive. | ✅ **FIXED** — added `ring_blocked` check + `wakeup_eventfd()` call. |
| H7 | L5 Resilience | `transports/stream/lifecycle.zig:61-62,69-70` | `connection_lost` callback errors silently dropped in `close_transports`. Both `PyObject_CallOneArg` failures cleared with `PyErr_Clear`. | ✅ **FIXED** — route errors to loop's `call_exception_handler` via context dict. |
| H8 | L10 Cancelled | `transports/write_transport.zig:109` | `flush_buffered_writes` prepare hook missing `data.cancelled` guard. During shutdown, called from `execute_hooks` → queues IO to deinitialized ring. | ✅ **FIXED** — added `if (data.cancelled) return;` at top. |
| H9 | L10 Cancelled | `transports/read_transport.zig:122` | `read_operation_completed` missing proper `data.cancelled` early-exit. Only skips `bytes_read` calculation (L132), still calls Python read callback + touches transport state. | ✅ **FIXED** — added `if (data.cancelled) { cleanup_resources_callback(data.user_data); return; }` at top. |

### 🟡 MEDIUM (5) — fragile, could bite later

| # | Lesson | File:Line | Bug | Fix |
|---|--------|-----------|-----|-----|
| M1 | L10 Cancelled | `loop/python/control.zig:161` | `hook_callback` missing `data.cancelled` guard. During shutdown, `execute_hooks` calls arbitrary Python code on a potentially torn-down loop. | ✅ **FIXED** — added `if (data.cancelled) { py_decref(handle); return; }`. |
| M2 | L3 Ghost Refs | `loop/python/control.zig:126-132` | `HookHandle.callback`: separate `py_newref` on callback object. When hook is unlinked from HooksList, this ref becomes invisible to GC. | ✅ **FIXED** — added `tp_traverse` + `HAVE_GC` flag to `HookHandleType`. |
| M3 | L3 Ghost Refs | `loop/python/control.zig:198-203` | `PathWatcherHandle.callback`: same pattern as HookHandle. Separate incref invisible when watcher removed from FSWatcher. | ✅ **FIXED** — added `tp_traverse` + `HAVE_GC` flag to `PathWatcherHandleType`. |
| M4 | M4 Null Discovery | `transports/datagram/write.zig:191` | `args[1].?` evaluated before `is_none` check. If `args[1]` is null, `.?` crashes before `is_none` can return false. | ✅ **FIXED** — added `args[1] != null` guard before `.?` unwrap. |
| M5 | L5 Resilience | `loop/runner.zig:147-153` | `execute_hooks` uses `try` — single failing hook (e.g. `flush_buffered_writes`) propagates error → kills the event loop. | ✅ **FIXED** — changed `try` to `catch continue` per-hook. |

### 🟢 LOW / INFO (3) — defense-in-depth, not high priority

| # | Lesson | File:Line | Bug | Fix |
|---|--------|-----------|-----|-----|
| L1 | L12 Ring FD | `loop/scheduling/io/main.zig:382` | `register_fixed_file()` lacks `ring.fd >= 0` guard. If called after `io.deinit()`, `register_files_update` will assert-fail. Currently protected by Python layer preventing new connections on stopped loop. | ✅ **FIXED** — added `if (self.ring.fd < 0) return error.LoopDeinitialized;` guard. |
| L2 | L2 EINTR | `loop/scheduling/io/main.zig:414` | Eventfd write discards return value via `_ =`. EINTR before the atomic 8-byte write could theoretically lose a wakeup (rare). | ✅ **FIXED** — retry loop on EINTR, return on any other error. |
| L3 | L2 EINTR | `loop/child_watcher.zig:104` | `waitid` with WNOHANG: EINTR causes re-arm cycle where the pidfd read is queued again. Not crashy but wastes one io_uring cycle per signal. | ✅ **FIXED** — immediate retry on EINTR inside a `while(true)` loop. |

### ✅ What's Clean

The scan also confirmed these areas are properly handled:

| Lesson | Finding |
|--------|---------|
| L6 Stack | No `var loop: Loop = undefined;` on the stack. ~42MB struct always heap-allocated via `LoopObject`. All `self.* = .{...}` patterns on small structs. |
| L7 @alignCast | Both instances in traverse functions (`future/python/constructors.zig:85`, `future/callback.zig:168`) are safe — restoring known types from opaque pointers. |
| L10 Cancelled | 44/47 production callbacks properly handle `data.cancelled`. Only 3 missing (H8, H9, M1 above). |
| L5 Dispatch | `execute_ring_buffer` / `execute_dynamic_ring_buffer` correctly catch errors, route to exception handler, check for KeyboardInterrupt/SystemExit, and continue. |
| L5 Task Errors | All task callbacks (`execute_task_send`, `execute_task_throw`, etc.) use `handle_zig_function_error` properly. |
| L1 Atomic Sleep | `should_wait` evaluated AFTER flush, inside mutex. `ring_blocked` set before dropping GIL. Eventfd write after push. Correct pattern. |
| M3 Atomics | Ring buffer read/write indices use `@atomicLoad`/`@atomicStore` with `.acquire`/`.release`. `BlockingTasksSet.index` correctly synchronized. |
| M5 Init Order | All collection insertions initialize data before advancing index/linking node. GC-safe ordering throughout. |

### Summary

| Severity | Count | Impact |
|----------|:-----:|--------|
| CRITICAL | 4 | Silently lost Python errors, crash in free-threading |
| HIGH | 10 | Memory leaks under load, loop crashes on signals, shutdown crashes |
| MEDIUM | 5 | GC blind spots, fragile null handling, loop-killing hook errors |
| LOW | 3 | Defense-in-depth gaps, no current crash risk |
| **Total** | **22** | |

---
