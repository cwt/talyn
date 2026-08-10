---
type: lessons_learned
title: Registered Buffer Fallback & MEMLOCK (BUG-117)
description: io_uring registered (fixed) buffer registration failure under RLIMIT_MEMLOCK pressure, the behavior-preserving graceful fallback, and the per-process MEMLOCK accounting that initially broke the regression test.
tags: [io-uring, registered-buffers, memlock, fallback, testing, bug-117]
timestamp: 2026-07-15T13:17:00Z
---

[⬅️ Back to Lessons Index](./index.md)

# Registered Buffer Fallback & MEMLOCK (BUG-117)

Lessons from **BUG-117** — a latent memory-safety/correctness defect in how Talyn handled io_uring *registered (fixed) buffer* registration failure, and the subtle test-isolation trap that followed the fix.

---

### The Defect

io_uring registered buffers require locked/pinned memory (`RLIMIT_MEMLOCK`). Under memory pressure (e.g. many concurrent live loops exhausting the `RLIMIT_MEMLOCK` budget, or a low `ulimit -l`), `io_uring_register(IORING_REGISTER_BUFFERS)` fails (typically `error.SystemResources`).

The original `IO.init` wrapped that call in a `catch` that **swallowed the error and prematurely tore down `buffer_pool`**:

```zig
self.ring.register_buffers(self.buffer_pool.iovecs) catch |err| {
    self.buffer_pool.deinit(allocator);   // premature teardown
    std.log.err("io_uring buffer registration failed: {}", .{err});
};
```

Two real problems, not just a swallowed error:

1. **Hidden init failure** — `IO.init` returned success even though a setup step failed, so the `Loop` was handed to Python as fully initialized.
2. **Fragile ownership** — `buffer_pool` was freed mid-init while later `lease`/`release` and `IO.deinit` paths still logically owned it. In practice the freed pool is never dereferenced (the empty slice guards `len == 0`), so the observable effect is *silent loss of the registered-buffer optimization*, not a deterministic SIGSEGV — but the ownership is fragile and a latent UAF risk.

### The Fix (behavior-preserving graceful fallback)

Implemented as **option (b)** — keep functionality, never make registration fatal:

- Added `buffers_registered: bool = false` to `IO`.
- On `register_buffers` failure: set `buffers_registered = false`, log a warning, and **return success without deinitializing `buffer_pool`**. On success: set `buffers_registered = true`.
- `lease_buffer()` returns `null` when `!buffers_registered`; every consumer (`read_transport`, datagram) then falls back to a heap buffer, and `read.zig` only issues `ring.read_fixed` when `fixed_buffer_index != null`. This satisfies Architectural Mandate #7 (complete feature fallback paths).
- `IO.deinit` keeps a single, correct `buffer_pool.deinit` — the pool is never torn down in the catch, so there is exactly one owner and one teardown.

**Why not option (a)** (`return err`)? Making the *first* loop past the `RLIMIT_MEMLOCK` budget fatal would cap Talyn at ~8 concurrent live loops and break the proxy's many-concurrent-loops use case. It is also unsafe as written: `Loop.init` holds an `errdefer self.io.deinit()`, while `IO.init` already owns cleanup `errdefer`s (ring, buffer_pool, eventfd); a bare `return err` would double-`deinit` the ring and double-free `blocking_ready_tasks`/`fixed_file_table` and double-`close(eventfd)`.

### The Trap: per-process MEMLOCK accounting

The regression test (`tests/test_buffer_fallback.py`) clamps `RLIMIT_MEMLOCK` to `1024*1024 - 65536` (below the 1 MiB pool need, above the ~100 KiB ring need) to force the fallback. It passed **standalone** but failed in the full `test_all.sh` suite with `OSError: SystemResources` from `Loop.__init__`.

Root cause: io_uring accounts **all** its pinned memory (the SQ/CQ rings *and* registered buffers) against the **per-process** `RLIMIT_MEMLOCK` budget. The full suite creates and tears down many loops before this test; the kernel releases registered-buffer pins *asynchronously*, so by the time the test runs the parent process's pinned-memory budget is still elevated (~1–2 MiB). Clamping `cur` to `983040` therefore broke **ring setup itself** (`IoUring.init` → `error.SystemResources`, an *unguarded* failure path — only `register_buffers` is caught), so the test never reached the fallback it intended to exercise.

Key measurements:

- Fresh process + clamp `983040` → `io_uring_setup` succeeds (ring ≈100 KiB < budget).
- After 61 loop tests + clamp `983040` → `io_uring_setup` fails `ENOMEM`; succeeds again only at `rlimit_cur ≥ 2 MiB`, proving accumulated usage ~1–2 MiB.
- A child **subprocess** spawned mid-suite succeeds under the same clamp — the accumulation is **per-process**, not per-UID-sticky.

**Fix for the test:** run the clamp+loop scenario in an **isolated subprocess** (clean per-process MEMLOCK budget), so the clamp affects only buffer registration. The subprocess loads the test module by file path (since `tests/` is not a package) and honors the existing skip condition.

### Invariants to preserve

- **`!buffers_registered ⇒ pool is full ⇒ `release_buffer` is a safe no-op.** Because `lease_buffer` returns `null` before touching the pool when `!buffers_registered`, no slot is ever leased, so `free_count == SlotCount` and `RegisteredBufferPool.release` returns early via its overflow guard. Documented on `IO.release_buffer`.
- **`RegisteredBufferPool.release` bounds-checks `index`.** A valid index only ever originates from `lease()` (0..`SlotCount-1`); an out-of-range index must not be written into `free_slots`. A `if (index >= SlotCount) return;` guard was added.
- **Consumers pair lease/release.** `read_transport` only calls `release_buffer` when `fixed_buffer_index` was set (i.e., the lease succeeded); `perform()` passes `fixed_buffer_index = null` when none was leased, so `read.zig` issues `ring.read` (never `read_fixed`). Datagram's `RecvMsgData` has no `fixed_buffer_index` field at all, so it can never issue `read_fixed`.

### Cross-references

- Bug report: [BUGS.md — BUG-117](../BUGS.md)
- Kernel feature-gating / complete fallback: [io_uring §Lesson 13](04-io-uring-and-kernel.md)
- Deferred-submission buffer ownership: [io_uring §Lesson 60](04-io-uring-and-kernel.md)
- Released in Talyn **v0.8.1** (BUG-117 fix + version bump).
