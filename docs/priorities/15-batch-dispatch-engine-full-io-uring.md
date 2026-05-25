[⬅️ Back to Index](../todo.md)

# 🔴 PRIORITY 15: Batch Dispatch Engine + Full io_uring — Architectural Redesign

### Phase 1: Completion Record Buffer — ✅ DONE (2026-05-15)

Infrastructure in place. Batch insertion disabled; completions flow through standard callback path.
All 268 tests pass on all 4 Pythons (3.13, 3.14, 3.13t, 3.14t).

**Files added/modified:**
| File | Change |
|------|--------|
| `src/loop/completion.zig` | New: `CompletionOp` enum, `CompletionRecord` (32 bytes), `CompletionBatch` (max 4096, GC-safe traverse) |
| `src/loop/main.zig` | `Loop` struct: added `completion_batch: CompletionBatch` field |
| `src/loop/runner.zig` | `dispatch_completion_batch()` + `batch_clear()` functions; called in main loop tick |
| `src/loop/runner.zig` | `fetch_completed_tasks`: batch insertion logic present but bypassed; uses standard callback path |
| `src/transports/read_transport.zig` | `perform()`: sets `module_ptr` to `parent_transport` for batch routing; added `batch_dispatched` flag |
| `src/transports/stream/read.zig` | Skip Python protocol call when `batch_dispatched` is true; still re-queues read |
| `src/callback_manager.zig` | Added `batch_dispatched` flag to `CallbackData` |
| `leviathan/loop.py` | `_dispatch_completions()`, `_dispatch_completions_with_list()`, `_dispatch_data_received()`, `_dispatch_eof_received()`, `_dispatch_buffer_updated()`, `_dispatch_connection_lost()` |
| `src/loop/python/constructors.zig` | `loop_traverse`: visits `completion_batch` for GC safety |

### Phase 2: Batch Dispatch — ✅ DONE (2026-05-16)

Batch dispatch now enabled. **Key insight:** eliminate ALL PyObject pointers from
`CompletionRecord`. Store only raw Zig pointers — GC never touches the batch.

**Root cause 1 (deadlock — FIXED):** Protocol methods call `loop.call_soon()` which
needs the mutex. Moved `dispatch_completion_batch` to after `mutex.unlock()`.

**Root cause 3 (GC segfault):** `CompletionRecord` stored `transport: ?PyObject` and
`data: ?PyObject`. The GC traversed these. When `batch_clear` decref'd them without
nullifying the slot first, the GC could visit a dangling pointer during decref's own
`__del__` if the deallocator triggered a GC collection → segfault.

**Fix:** Replaced PyObject fields with raw Zig pointers:
- `transport: ?PyObject` → `stream_transport: ?*anyopaque` (Zig pointer to `StreamTransportObject`)
- `data: ?PyObject` → `buffer_ptr: ?*anyopaque` (raw bytes pointer) + `nbytes: i64`
- PyBytes created during dispatch from `buffer_ptr + nbytes`
- Protocol accessed via transport's cached method pointers (`protocol_data_received`, `protocol_buffer_updated`)
- `batch_clear` simplified to just `reset()` — no decrefs needed (no PyObject stored)
- No GC `traverse` needed — `CompletionBatch` has zero PyObject pointers
- Python-side dispatch helpers (`_dispatch_completions`, etc.) retained but bypassed in favor of direct Zig dispatch

**Why the old approach failed:** The fundamental issue was storing PyObject pointers
in a buffer that can be overwritten between `tp_traverse` visits. Even with proper
incref/decref, the window between `batch_clear` (which decref'd the pointers) and
the next `reset()` created a race where GC traversal could visit stale pointers.

**New approach (robust):**
1. `CompletionRecord` stores `stream_transport: ?*anyopaque` — transport is a Zig struct, not a PyObject. GC doesn't visit it.
2. `buffer_ptr: ?*anyopaque` + `nbytes: i64` — raw bytes from the read transport's internal buffer. No PyBytes until dispatch.
3. In `fetch_completed_tasks`: push record directly (no incref, no PyBytes creation).
4. In `dispatch_completion_batch`: read records, create PyBytes + call protocol methods via transport's cached `*anyopaque` pointers.
5. `batch_clear` is just `batch.reset()` — zero PyObject interaction.
6. No GC traverse for the batch at all.

**Files changed:**
| File | Change |
|------|--------|
| `src/loop/completion.zig` | Remove PyObject fields + `traverse()`. Add `stream_transport`, `buffer_ptr` fields |
| `src/loop/runner.zig` | `fetch_completed_tasks`: enable batch insertion (remove `false and` guard). `dispatch_completion_batch`: create PyBytes from raw buffer + call protocol methods. Remove `batch_clear` |
| `src/loop/python/constructors.zig` | Remove `completion_batch.traverse()` from `loop_traverse` |

**Impact:** All 268 tests pass on all 4 Pythons + standard asyncio test suites pass on all 4 Pythons + Zig unit tests pass.

### Root Cause of 0.6-0.8× I/O Performance

The current architecture processes completions one-at-a-time with per-completion Zig→Python crossings:

```
CQE → Zig callback → memcpy 48-byte Callback into ring buffer → pop → PyObject_Call → Python method
```

This means **1 Zig→Python boundary crossing per I/O completion**. For TCP Echo at M=65536:
- 128 completions per batch (64 read + 64 write)
- 128 Python crossings via `PyObject_CallOneArg(protocol.data_received, py_bytes)`
- Each crossing: CPython builds args tuple, does type checks, calls method, returns

**The fix:** Replace per-completion Python calls with batched dispatch. Zig writes completion records to a shared buffer, Python reads the batch and dispatches in a tight native loop.

### Design: Completion Record Buffer

```
Current:                                      Proposed:
                                                                    
Zig: copy_cqes → fetch_completed_tasks        Zig: copy_cqes → fill CompletionRecord[64]  
       → ring_buffer.push(Callback)                  → set ready_count atomic
       → each callback does PyObject_Call     Python: read batch[0..ready_count]
                                                     → for each: switch type → call method
                                                     → clear batch
```

**CompletionRecord** (lightweight, no function pointers):
```zig
const CompletionRecord = struct {
    operation: enum { DataReceived, EofReceived, ConnectionLost, 
                     ResumeWriting, Accept, Connected, ... },
    transport: ?*TransportObject,
    data: union { bytes: *PyObject, nbytes: i64, error: ?*PyObject, ... },
};
```

Instead of copying a 48-byte `Callback` struct (with function pointer, module_ptr, callback_ptr), we store just the operation type + transport pointer + data. Python reads this and calls the protocol method natively — no function pointer indirection.

### Implementation Plan

#### Phase 1: Completion Record Buffer (replaces callback_manager ring buffer for IO completions) — ✅ DONE

| # | Task | Files | Expected |
|---|------|-------|:--------:|
| 15.1 | Define `CompletionRecord` union for all IO operation types | `src/loop/completion.zig` | ✅ |
| 15.2 | Replace `fetch_completed_tasks` — write `CompletionRecord` instead of pushing `Callback` | `runner.zig` | ⏸ (infra ready, batch insertion bypassed) |
| 15.3 | Add Python-accessible batch buffer (`CompletionRecord[N]` + `ready_count` atomic) | `loop/main.zig` | ✅ |
| 15.4 | Add Python-side dispatch loop: read batch, call protocol methods natively | `loop.py` | ✅ |
| 15.5 | Route Python dispatch errors back to loop exception handler | `loop.py` | ✅ |
| 15.6 | Keep callback_manager for non-IO tasks (call_soon, call_later, task wakeups) | — | ✅ No change for task dispatch |
| 15.7 | Run full test suite + benchmarks | All | ✅ 268 tests pass, 4 Pythons |

#### Phase 2: io_uring SQPOLL — Zero-Syscall Submission — ⛔ REVERTED

SQPOLL was implemented and tested but **reverted** after benchmarks showed net regressions.
See [PRIORITY 17](#🔴-priority-17-sqpoll-hang-after-16000-total-sqes--✅-fixed-2026-05-17) for full analysis.

| # | Task | Status |
|---|------|:------:|
| 15.8 | Init io_uring with `IORING_SETUP_SQPOLL` | ⛔ Reverted |
| 15.9 | `submit_guaranteed()` SQPOLL fast path | ⛔ Reverted |
| 15.10 | Handle `IORING_SQ_NEED_WAKEUP` | ⛔ Reverted |
| 15.11 | Unit tests for SQPOLL | ⛔ Removed |

**Why reverted:** On kernel 7.0.6, SQPOLL has a critical bug causing hangs after ~16000 SQEs
(P17). The P17 fix (eventfd write before every blocking `enter()` + `SQ_WAKEUP` on every
`submit()`) adds more overhead than SQPOLL saves. Net result: **UDP Ping-Pong dropped
from 1.16× to 0.57×**, Socket Ops from 0.65× to 0.49×. Zero-syscall submission is
theoretically valuable but practically harmful on this kernel.

#### Phase 3: Registered Buffers & Fixed Files — 🟡 IN PROGRESS

IOSQE_FIXED_FILE optimization eliminates `fget`/`fput` per IO operation. Socket FDs are
registered in a sparse fixed file table at transport creation. Index 0 reserved for eventfd.

**Architectural Design Update (2026-05-25):** 
An `io_uring` ring allows only a single buffer registration table. Dynamic register/unregister operations per transport are extremely slow and trigger kernel-level `EBUSY` errors when multiple I/O requests are in flight. 

To solve this, we are implementing a global, contiguous **`RegisteredBufferPool`** (1024 slots of 64KB, totaling 64MB) inside `IO.init()`. Transports will dynamically lease/release a slot index and its pre-registered memory slice at creation/destruction. If the pool is empty, they fallback gracefully to heap-allocated buffers and standard `read` operations.

**Bug found & fixed (2026-05-17):** `Loop.release()` order was wrong — `io.deinit()` ran
before callback dispatch. Pending `read_operation_completed` callbacks called
`unregister_fixed_file()` on a deinitialized ring (fd = -1), triggering
`assert(fd >= 0)` → abort. Fixed by:
1. Guarding `unregister_fixed_file()` with `ring.fd >= 0` check
2. Moving callback dispatch before `io.deinit()` in `Loop.release()`
See Lesson 12 for details.

| # | Task | Files | Status | Expected / Notes |
|---|------|-------|:------:|:-----------------|
| 15.12 | Register transport buffers via global `RegisteredBufferPool` (1024 * 64KB) | `io/main.zig`, transport files | 🔴 **Pending** | Pre-allocated in `IO.init()`, leased by transports |
| 15.13 | Use `IOSQE_FIXED_FILE` for hot-path socket operations | `read.zig`, `write.zig` | ✅ **DONE** | Bypasses kernel fd reference count overhead |
| 15.14 | Pre-register eventfd + pidfds as fixed files | `io/main.zig`, `child_watcher.zig` | ✅ **DONE** | Bypasses eventfd tracking overhead |
| 15.15 | Benchmark — measure buffer registration impact | All | 🔴 **Pending** | **Expected: 1.5-2.5× → 2.0-3.5×** |

#### Phase 4: Combined Submit+Wait + Full-Batch CQE Drain

| # | Task | Files | Expected |
|---|------|-------|:--------:|
| 15.16 | Replace `flush_pending_sqes()` + `copy_cqes()` with combined `io_uring_enter(to_submit, wait_nr, GETEVENTS)` — one syscall instead of two | `runner.zig` | |
| 15.17 | Drain ALL available CQEs per batch (not just batch_size) — `IORING_ENTER_GETEVENTS` with `wait_nr = 0` after first wake | `runner.zig` | |
| 15.18 | Benchmark | All | |

### Expected Impact (M=65536)

| Benchmark | Current (479) | Phase 1 | Phase 3 | Phase 4 |
|-----------|:------------:|:-------:|:-------:|:-------:|
| **TCP Echo** | **0.65×** | 1.2× | 2.5× | **3.0×** |
| **UDP Ping-Pong** | **0.57×** | 1.5× | 3.0× | **3.5×** |
| Socket Ops | 0.49× | 1.0× | 2.5× | **3.0×** |
| Chat | 0.95–1.06× | 1.0× | 1.5× | **1.8×** |
| Subprocess | 0.98× | 1.0× | 1.2× | **1.5×** |

**Note:** Phase 2 (SQPOLL) was reverted. These targets assume Phases 3+4 are built
on the non-SQPOLL baseline, which already has batched SQE submission (Phase 1)
via `flush_pending_sqes()`. The main missing pieces are registered buffers and
combined submit+wait.

---
