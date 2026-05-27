[⬅️ Back to Index](../todo.md)

# 🔴 PRIORITY 11: SQE Batch Submission — io_uring Batching (2026-05-13)

### Root Cause of 0.2-0.5× I/O Performance

Every IO operation (read, write, poll, connect, accept, shutdown, timer, cancel) calls `IO.submit_guaranteed()` immediately after prepping the SQE — **1 `io_uring_enter` syscall per SQE**. Verified across all 6 IO op files and all 46 revisions of the project:

| Rev | Pattern | Batch? |
|-----|---------|:------:|
| 240 | `ring.submit()` after each op | ❌ |
| 276 | `ring.submit()` + `error.SQENotSubmitted` | ❌ |
| 292 | Single ring, still `ring.submit()` per op | ❌ |
| 353 | `IO.submit_guaranteed()` wrapper (EINTR-safe) | ❌ |
| 433 | Priority 9 ring buffer; submission unchanged | ❌ |
| tip | Same as 433 | ❌ |

For TCP Echo with 65536 messages: **131,072 `io_uring_enter` syscalls** for read+write. With batching: **~2 syscalls per loop iteration** regardless of message count.

High standard deviation (Unix Echo stdev=58% of mean, TCP Echo stdev=64%) confirms the bursty pattern: completions arrive unpredictably because there's no periodic flush point aggregating SQEs into a single `io_uring_enter`.

### Why Previous Attempt Failed (`.orig` files)

The `.orig` files (dated May 12, 7:08am — same day as Priority 9) represent an uncommitted, half-finished batching attempt with a fatal flaw:

```
queue() preps SQE, returns, then:
  if sq_ready() >= TotalTasksItems - 2: submit()
```

**Problem 1 — No forced flush:** If the workload has only 1-2 operations per loop iteration, SQEs sit in the submission queue **indefinitely** with no flush trigger. Deadlock.

**Problem 2 — Cancellation breaks:** `cancel.zig` submits a new SQE targeting `task_id`. If the target SQE is still in the submission queue (not flushed), the kernel has no record of the original operation — cancel is a silent no-op.

**Problem 3 — Eventfd deadlock:** Without immediate submission for eventfd registration (Lesson 9), background threads can't wake the loop.

### Design: Deferred Submission with Forced Flush

The key insight: **don't submit in IO op functions. Instead, flush all pending SQEs at a single point in the loop runner.**

```
Before:  IO op → prep SQE → submit_guaranteed() → return task_id
After:   IO op → prep SQE → [flush if SQ near full] → return task_id
         poll_blocking_events(): flush_pending_sqes() → copy_cqes()
         cancel.zig:           flush_pending_sqes() → prep cancel SQE → submit()
```

This ensures:
1. All SQEs from a callback batch are submitted in ONE `io_uring_enter` call
2. No SQE sits indefinitely — `poll_blocking_events()` always flushes before waiting
3. Cancellation works because we flush before cancel
4. Eventfd registration still submits immediately (exception)

### Expected Impact

| Benchmark | Current | Expected | Why |
|-----------|:-------:|:--------:|-----|
| TCP Echo | 0.31-0.62× | **1.5-3.0×** | 2 syscalls/msg → 2 syscalls/batch |
| Unix Echo | 0.17-0.40× | **1.5-3.0×** | Same pattern |
| Producer-Consumer | 0.42-0.93× | **1.0-2.0×** | Mix of task + IO |
| Async Task Workflow | 0.46-0.86× | **1.0-2.0×** | Many IO ops between tasks |
| Socket Ops | 0.52× | **2.0-4.0×** | Mostly syscall-bound |
| Subprocess | 0.24× | **0.5-1.0×** | waitid/pipe syscalls batched |
| UDP Ping-Pong | 0.65-0.85× | **1.5-3.0×** | recvmsg+sendmsg batched |
| Task Spawn | 0.41-0.44× | **0.41-0.44×** | No IO — different bottleneck |

### Implementation Plan

#### Phase 1: Core Batching (this session)

| # | Task | Files | Status |
|---|------|-------|:---:|
| 11.1 | Refactor `Read.perform`, `Write.perform/sendmsg/writev` — keep immediate submit (buffer ptr) | `read.zig`, `write.zig` | ✅ **DONE** |
| 11.2 | Refactor `Timer.wait` — keep immediate submit (timespec ptr) | `timer.zig` | ✅ **DONE** |
| 11.3 | Refactor `Socket.connect/accept` — keep immediate submit (sockaddr ptr) | `socket.zig` | ✅ **DONE** |
| 11.4 | Refactor `Socket.shutdown`, `Read/Wait.wait_ready` — DEFER (no pointer args) | `read.zig`, `write.zig`, `socket.zig` | ✅ **DONE** |
| 11.5 | Add `IO.flush_pending_sqes()` + auto-flush in `queue()` when SQ near-full | `io/main.zig` | ✅ **DONE** |
| 11.6 | Wire forced flush + `should_wait` deadlock guard into `poll_blocking_events()` | `runner.zig` | ✅ **DONE** |
| 11.7 | Fix cancel: `queue()` flushes SQEs before dispatching Cancel | `io/main.zig` | ✅ **DONE** |
| 11.8 | Fix submit-count check: `ret == 0` instead of `ret != expected` (dtype: don't care) | All IO op files | ✅ **DONE** |
| 11.9 | Keep eventfd registration as immediate submit (Lesson 9) | `io/main.zig` | ✅ **DONE** |
| 11.10 | Run full test suite + benchmarks | All | ✅ **DONE** |

#### Phase 2: Combined Submit+Wait (future)

| # | Task | Status |
|---|------|:---:|
| 11.11 | Combined submit+wait — already done via `submit_and_wait(1)` in waiting path. `copy_cqes(..., 0)` is pure memcpy (0 syscalls). Non-waiting path already 0 syscalls (`submit()` skips `io_uring_enter` in non-SQPOLL). | ✅ Already done |
| 11.12 | Batch CQE reaping — process all CQEs per `copy_cqes` without re-entering loop | ✅ **DONE** |
| 11.13 | Registered buffers / fixed files for hot paths | ✅ **DONE** |

#### Phase 3: Pointer-Safe Deferred Submission — DONE (2026-05-15)

All operations now use deferred submission. RecvMsg/SendMsg msghdrs were already
heap-allocated in transport structs — just removed the redundant `submit_guaranteed()`.
Zero-copy paths stored their stack-allocated msghdr in new `BlockingTask.msg_storage`
and `BlockingTask.write_iov` fields in the persistent task_data_pool.

**Changes:**
- `BlockingTask`: Added `msg_storage: msghdr` + `write_iov: iovec` for zero-copy paths
- `Read.recvmsg`: Removed immediate submit (msghdr in heap SockRecvFromData)
- `Write.sendmsg`: Removed immediate submit (msghdr in heap SockSendToData)
- `Read.perform` zero-copy: msghdr now in `data_ptr.msg_storage` instead of stack
- `Write.perform` zero-copy: msghdr + iovec now in `data_ptr.msg_storage/write_iov`
- `Write.perform_with_iovecs` zero-copy: msghdr now in `data_ptr.msg_storage`
- `Cancel.perform`: Still immediate (cancel targets in-flight ops)

| # | Task | Status |
|---|------|:---:|
| 11.14 | Add `storage` fields to `BlockingTask` (msghdr, iovec) | `io/main.zig` | ✅ **DONE** |
| 11.15 | `Timer.wait` — already deferred via `timer_storage` | `timer.zig` | ✅ Already done |
| 11.16 | `Socket.connect` — already deferred (addr in heap) | `socket.zig` | ✅ Already done |
| 11.17 | `Socket.accept` — already deferred (addr/addrlen in heap) | `socket.zig` | ✅ Already done |
| 11.18 | `Read.perform`/`Write.perform` — zero-copy msghdr in `msg_storage` | `read.zig`, `write.zig` | ✅ **DONE** |
| 11.19 | `RecvMsg`/`SendMsg` — removed immediate submit | `read.zig`, `write.zig` | ✅ **DONE** |
| 11.20 | Removed `submit_guaranteed()` from all ops except cancel | All IO op files | ✅ **DONE** |

**Impact:** All non-cancel IO operations are now deferred. SQEs accumulate across callback
batches and are flushed together in `poll_blocking_events()` maximising each io_uring_enter().

**Expected impact with Phases 2 + 3:** 0.4-0.6× → **1.5-3.0×** asyncio on all I/O benchmarks.
Leviathan finally leverages io_uring's true advantage: batched submission + kernel-side dispatch.

---
