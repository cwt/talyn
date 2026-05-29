[⬅️ Back to Index](../todo.md)

# 🔴 PRIORITY 22: Fused User-Space Socket State Machine (2026-05-28)

This document details the complete design, implementation, validation results, and safeguards of the High-Performance Fused User-Space Socket State Machine designed to eliminate kernel workqueue overhead (`IOSQE_ASYNC`) and guarantee absolute stability under extreme concurrency and load.

---

## 🏗️ Core Architecture & Design

Historically, socket operations (`connect`, `accept`) in `src/loop/scheduling/io/socket.zig` enforced `sqe.flags |= IOSQE_ASYNC`. This delegated non-blocking handshakes to kernel-level threads (`io-wq`), introducing severe context-switching overhead and scheduling latency, capping relative speed at **0.74×** of asyncio.

### Zero-Workqueue Connect State Machine
1. Standard `IORING_OP_CONNECT` is submitted **without** `IOSQE_ASYNC`.
2. If the kernel returns `-EINPROGRESS` (non-blocking connection in-flight):
   * The Python Future remains in a `.pending` state.
   * We immediately submit an `IORING_OP_POLL_ADD` (`POLL_OUT`) watcher on the socket file descriptor.
3. Upon writability completion, `getsockopt` verifies the socket state:
   * If successful, the future resolves.
   * If failed (e.g. `EALREADY` / `-114` is returned), we gracefully handle the transient progress and re-arm the poll.

### Zero-Workqueue Accept State Machine
1. Instead of inline polling or blocking worker threads, we queue a `.WaitReadable` (`POLL_IN`) watcher on the listening socket.
2. Cooperative yield is enforced: the synchronous "fast-path" accept was completely removed, ensuring every accept event yields to the event loop first. This prevents stack-depth starvation and ensures pending client connections are allowed to progress.
3. Once readable, we issue an inline `accept4` system call, which is guaranteed to complete instantly in user-space with zero blocking.

---

## 🔍 Critical Bug Investigation & Resolutions

During intensive load testing, a deadlock regression was discovered at `m=4096` along with a garbage collection division-by-zero panic under stress. These were fully investigated and solved:

### 1. The Direct `accept4` System Call Error Check Bug
* **The Bug**: In the `accept_callback` inside [streamserver/main.zig](file:///home/cwt/Projects/leviathan/src/transports/streamserver/main.zig), the Zig return value of the raw system call `accept4` was checked using a strict `== std.math.maxInt(usize)` to detect failure.
* **The Mechanism**: On Linux, raw system calls return negative values on error (e.g., `-EAGAIN` / `0xFFFFFFFFFFFFFFF5`). Since this is not equal to `std.math.maxInt(usize)` (`-1`), transient level-triggered errors like `EAGAIN` or `ECONNABORTED` bypassed the failure block. The loop cast the large error value into a file descriptor (resulting in `-11` or `-103`), passed it to Python, and registered it in `io_uring`, which permanently stalled and deadlocked the accept queue.
* **The Fix**: Rewrote the failure check to correctly inspect `client_fd_ret >= std.math.maxInt(usize) - 4095` and extract the exact errno directly from the returned value, ensuring transient level-triggered errors robustly re-arm the poll and never stall the queue.

### 2. GC Division-by-Zero Panic in Partially Initialized Loops
* **The Bug**: If the loop initialization (`io_uring_queue_init`) failed with `SystemResources` under high-capacity stresses, the `LoopObject` was partially initialized, but `self.initialized` was already set to `true`. When Python GC ran to collect the failed loop object, `loop_traverse` called `traverse` on the uninitialized callback queues.
* **The Mechanism**: In [callback_manager.zig](file:///home/cwt/Projects/leviathan/src/callback_manager.zig), the traverse loop did `i % self.capacity`. Since initialization failed before capacity was set, it panicked with `division by zero` inside the garbage collection thread.
* **The Fix**: 
  1. Added a robust guard in `traverse` to immediately return `0` if `self.capacity == 0`.
  2. Deferred setting `self.initialized = true` to the very end of `Loop.init` in [src/loop/main.zig](file:///home/cwt/Projects/leviathan/src/loop/main.zig). If any component fails during setup, `self.initialized` remains `false`, GC safely skips internal loop structures, and the `errdefer` chain perfectly and cleanly deallocates resources without leaks.

---

## 📊 Verification & Validation Results

* **Functional Compatibility**: **100% PASS** on all CPython interpreters (`python3.13`, `python3.14`, `python3.13t`, `python3.14t`) in standard test suites and Zig unit tests.
* **Stability Stress Test**: **100% PASS** on sequential/concurrent socket stress tests up to `m=65536` with zero timeouts or deadlocks.
* **Graceful Fallbacks**: Correctly manages memory exhaustion (`SystemResources`) and fallback paths without hardcoded assumptions.

---

> [!NOTE]
> All zero-workqueue state machines are fully operational, memory-safe, and GC-compliant, providing significant throughput improvements matching the efficiency profile of `uvloop`.
