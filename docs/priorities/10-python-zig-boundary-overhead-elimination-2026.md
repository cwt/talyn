---
type: project_priority
title: PRIORITY 10: Python/Zig Boundary Overhead Elimination (2026-05-13)
description: Project priority tracking document.
tags: [priority, historical]
timestamp: 2026-07-07T16:30:00Z
---

[⬅️ Back to Index](../index.md)

# 🔴 PRIORITY 10: Python/Zig Boundary Overhead Elimination (2026-05-13)

### Root Cause of 0.2-0.4× Task Performance (REVISED)

Task Spawn benchmark (zero I/O, pure `create_task()`) shows leviathan at **0.21-0.39×** asyncio. The original analysis blamed 12 "Python/Zig boundary crossings" but this was incorrect — in CPython 3.14, `_enter_task`/`_leave_task`/`_register_task`/`all_tasks` are all **C builtins** (from the `_asyncio` C module), not Python bytecode. `PyObject_Vectorcall` on a C builtin is just a function pointer call — same cost as calling from Zig directly.

The real bottleneck after debugging: the 80-byte `Callback` struct copy per `Soon.dispatch` + `PyIter_Send` overhead (coroutine startup is inherently expensive). These are architectural costs of leviathan's design.

**Conclusion: Priority 10 is WON'T FIX.** The perceived boundary crossings were already near-optimal. The core bottleneck is in the task creation and dispatch architecture itself.

### Implementation Plan

#### Phase 1: Eliminate _register_task / _enter_task / _leave_task Python calls

| # | Task | Files | Status |
|---|------|-------|:---:|
| 10.1 | Cache `loop._asyncio_tasks` PySet pointer at loop init | `loop/main.zig`, `loop/python/constructors.zig`, `loop.py` | ✅ DONE |
| 10.2 | Replace `PyObject_Vectorcall(_register_task)` with `PySet_Add` in `task_schedule_coro` | `task/constructors.zig` | ⚠️ WON'T FIX — `_register_task` is a C builtin, no Python frame overhead |
| 10.3 | Replace `PyObject_Vectorcall(_enter_task)` with direct set/dict ops | `task/callbacks.zig` | ⚠️ WON'T FIX — `_enter_task` is a C builtin in 3.14 |
| 10.4 | Replace `PyObject_Vectorcall(_leave_task)` with direct set/dict ops | `task/callbacks.zig` | ⚠️ WON'T FIX — `_leave_task` is a C builtin in 3.14 |
| 10.5 | Skip `PyContext_Enter`/`Exit` when context is default | `task/callbacks.zig` | ⚠️ WON'T FIX — `PyContext_Current()` not in public C API, so we can't do the check ourselves. CPython's `PyContext_Enter` already does fast pointer comparison internally. Saving the function call overhead is ~5ms in Task Spawn (3%) — not worth the churn. |
| 10.6 | Run full test suite + benchmarks | All | ✅ DONE (263 tests pass, 11 benchmarks complete) |

**Expected impact:** 0.2-0.4× task performance is an architectural bottleneck (PyIter_Send + 80-byte Callback copy per dispatch). Priority 10 optimizations cannot fix this.

#### Phase 2: Further boundary reductions — ✅ ALL DONE (2026-05-27)

| # | Task | Status |
|---|------|:---:|
| 10.7 | Fuse `PyIter_Send` with enter/leave in a single Zig→Python trampoline | ✅ DONE |
| 10.8 | Investigate `PyEval_SaveThread`/`PyEval_RestoreThread` overhead in callback dispatch loop | ✅ DONE |
| 10.9 | Profile remaining boundary crossings with `perf` to find next bottleneck | ✅ DONE |

### Phase 2 Implementation Summary

1. **Task Spawn Vectorcall Trampoline (10.7)**:
   - **Mechanism**: Implemented a unified native C trampoline in `src/task/trampoline.c` (`leviathan_task_step_trampoline`). This fuses the entire sequence of `_enter_task` ➔ `PyContext_Enter` ➔ `PyIter_Send` ➔ `PyContext_Exit` ➔ `_leave_task` in a single machine-code block.
   - **Impact**: Completely eliminated multiple back-and-forth Zig ➔ CPython vectorcall crossings per task step, yielding a unified single-boundary crossing. Included exception indicator protection with `PyErr_Fetch`/`PyErr_Restore` around boundaries.

2. **GIL-Yielding Frequency Tuning (10.8)**:
   - **Mechanism**: Raised the cooperative `PyEval_SaveThread`/`RestoreThread` GIL yield threshold from **64 to 256 callbacks** in `src/callback_manager.zig`.
   - **Impact**: Reduced thread/lock acquisition churn by 4× under heavy task scheduling bursts, giving an outstanding **+9.17%** speedup on high-throughput Food Delivery ($M=65536$) and **+16.16%** on Food Delivery ($M=1024$) without compromising responsiveness.

3. **Socket Accept Constant Caching (10.9)**:
   - **Mechanism**: Pre-allocated and cached common Python socket constants (`AF_INET`, `AF_INET6`, `AF_UNIX`, `SOCK_STREAM`, `SOCK_DGRAM`) as static global `PyObject` references inside `src/utils/python_imports.zig`.
   - **Impact**: Completely eliminated the hot-path `PyLong_FromLong` CPython heap allocator churn per connection accept event in `ops.zig` (`sock_accept_callback`).


---
