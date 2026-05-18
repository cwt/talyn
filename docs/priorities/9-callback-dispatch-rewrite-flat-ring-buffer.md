[⬅️ Back to Index](../todo.md)

# 🔴 PRIORITY 9: Callback Dispatch Rewrite — Flat Ring Buffer (2026-05-11)

### Root Cause of 0.42× Task Performance

After 7 performance optimizations (Priority 8), leviathan remains **2-2.5× slower** than `asyncio` on task-intensive workloads. All incremental fixes hit the same wall: the `CallbacksSetsQueue` linked-list dispatch layer.

```
uvloop/libuv:  array[index++] = callback_ptr     // O(1), 1 store
leviathan:     walk(node) → find_slot() → copy(80-byte Callback)
               // O(n) walk, memcpy per append
```

### Design: Flat Ring Buffer Replacements

Replace the current `CallbacksSetsQueue` + `CallbacksSet` linked-list with two fixed-size ring buffers.

### Implementation Plan

#### Phase 1: Single Ring Buffer (Non-thread-safe)

| # | Task | Files | Status |
|---|------|-------|:---:|
| 9.1 | Define `RingBuffer(N)` struct with `[N]Callback` array, `read_idx`, `write_idx`, `executed` bitset | `callback_manager.zig` | ✅ **DONE** |
| 9.2 | Replace `append()` with O(1) ring push | `callback_manager.zig` | ✅ **DONE** |
| 9.3 | Replace `execute_callbacks()` loop with ring drain | `callback_manager.zig` | ✅ **DONE** |
| 9.4 | Replace `prune()` with ring reset | `callback_manager.zig` | ✅ **DONE** |
| 9.5 | Add `tp_traverse` for ring buffer | `callback_manager.zig` | ✅ **DONE** |
| 9.6 | Wire up `call_once`, `dispatch_nonthreadsafe`, double-buffer swap | `runner.zig`, `soon.zig` | ✅ **DONE** |
| 9.7 | Update zig unit tests | `callback_manager.zig` | ✅ **DONE** |
| 9.8 | Run full test suite + benchmarks | All | ✅ **DONE** |

**Current impact:**
- Task-intensive benchmarks: 0.42× → **0.44×** (marginal gain, task spawning still bottlenecked).
- I/O benchmarks (UDP Ping-Pong): 0.80× → **1.08×** (matching/beating asyncio).
- Stability: No more linked-list walks or dynamic growth panics. GC-safe in free-threading.

#### Phase 2: io_uring Batching (Requires Phase 1)

Once the dispatch layer is O(1), the next bottleneck is io_uring submission/reaping overhead:

| # | Task | Status |
|---|------|:---:|
| 9.9 | Batch SQE submission — collect pending ops, submit all in one `io_uring_enter` | 🔴 **REVERTED** |
| 9.10 | Batch CQE reaping — process all CQEs per `copy_cqes` without re-entering loop | 🔴 Pending |
| 9.11 | Registered buffers / fixed files for hot paths | 🔴 Pending |

**Expected impact with both phases:** leviathan at **2-5×** asyncio, matching or beating uvloop.

---
