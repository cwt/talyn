[⬅️ Back to Index](../todo.md)

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

#### Phase 2: Further boundary reductions (future)

| # | Task | Status |
|---|------|:---:|
| 10.7 | Fuse `PyIter_Send` with enter/leave in a single Zig→Python trampoline | 🔴 Future |
| 10.8 | Investigate `PyEval_SaveThread`/`PyEval_RestoreThread` overhead in callback dispatch loop | 🔴 Future |
| 10.9 | Profile remaining boundary crossings with `perf` to find next bottleneck | 🔴 Future |

---
