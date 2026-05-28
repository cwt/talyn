[⬅️ Back to Index](../todo.md)

# 🔴 PRIORITY 21: Advanced Event Loop Optimization (2026-05-28)

This document maps out the strategic implementation and validation plan for advanced low-level runtime optimizations to overcome remaining event loop overheads in **Task Spawning** and **Hot-Path I/O**. It incorporates strict guidelines compiled from the project's historical engineering mistakes, race conditions, and architectural stability mandates.

---

## 🏗️ Core Architecture & Bottleneck Targets

At extreme concurrency scales (e.g. $M=65536$), the primary runtime overhead is **micro-latency propagation** during:
1. **Memory Allocations and Copies:** High-frequency copying of verbose structures during queue scheduling.
2. **System Call Overhead:** Superfluous kernel entries when the scheduler has pending in-memory tasks but no hardware I/O completions to wait for.
3. **Synchronization Churn:** Excessive locking and context yielding under CPython's free-threaded (`3.13t` / `3.14t`) runtime model.

---

## 🛠️ Phases of Optimization

### 📈 Phase 1: High-Performance Callback Struct Slimming
* **Objective:** Reduce task/event queue memory footprint to maximize CPU L1/L2 cache residency.
* **Mechanism:** 
  * Redesign the legacy `Callback` structure, compressing its footprint to **32 bytes or less** using compact field unions and pre-cached callback identifiers.
* **Mandatory Safeguards (Lessons 3, 7, 11 & 14):**
  > [!CAUTION]
  > **Avoid GC Ghost References:** Any field or union holding a `PyObject` reference must be fully visible to standard Python GC traversal interfaces. 
  > * You must implement explicit traversal handlers. DO NOT use unverified generic wrapper macros (`deinitialize_object_fields`). 
  > * Avoid raw pointer casts (`@alignCast(@ptrCast(ptr))`) during GC traversal sweeps to ensure deterministic memory scanning.
  > * Unexecuted callback slots must be programmatically marked `executed = true` to allow idempotent, safe cleanup sweeps and prevent double-decrefs.

---

### 🚀 Phase 2: Zero-Syscall Short-Circuiting & Combined Wait Polling — ✅ DONE (Pre-implemented in P15 / P19)
* **Objective:** Short-circuit kernel transitions entirely during hot processing loops.
* **Mechanism:**
  * Implement an active check for `ring.sq_ready()` before calling into `io_uring_enter`. If there are no pending hardware I/O events, bypass the kernel transition to yield **0 syscalls per tick** on in-memory operations.
  * In instances where hardware I/O is required, enforce unified `io_uring_enter(to_submit, wait_nr, IORING_ENTER_GETEVENTS)` execution to fuse submission and CQE draining into a single system call.
* **Status Note:** Fully completed during the implementation of Priority 15 (Batch Dispatch Engine + Full io_uring) and Priority 19. The `sq_ready()` check in `flush_pending_sqes()` and unified wait polling via `submit_and_wait(1)` are fully active and validated.
* **Mandatory Safeguards (Lessons 9 & 13):**
  > [!IMPORTANT]
  > **Prevent EventFD Deadlock:** Infrastructure SQEs (such as initial `eventfd` registration or active cancellations) must never be batched lazily. They **must** be submitted immediately to avoid thread hangs.
  > * Ensure that if fallback paths are active (e.g., when running with constrained ulimits where sparse files are disabled), the scheduling paths gracefully fall back to raw file descriptors without hardcoding fixed indices.

---

### 🔒 Phase 3: Adaptive free-threaded GIL Release Tuning — ✅ DONE (Completed on 2026-05-28)
* **Objective:** Minimize cooperative synchronization churn under free-threaded Python runtimes (`3.13t`/`3.14t`).
* **Mechanism:**
  * Implement an adaptive algorithm that scales the `PyEval_SaveThread` / `PyEval_RestoreThread` release thresholds dynamically based on processing queue density (e.g., from 64 callbacks up to 512 callbacks under high burst loads).
* **Status Note:** Implemented in `src/callback_manager.zig`. The dynamic algorithm calculates `yield_threshold` using `get_adaptive_yield_threshold(ring.count())` which scales smoothly: $\le 64$ is $64$, $\le 256$ is $128$, $\le 1024$ is $256$, and $> 1024$ is $512$ callbacks.
* **Mandatory Safeguards (Lessons 1 & 17):**
  > [!WARNING]
  > **Atomic Wakeups & Lock Safety:** The decision to sleep must remain entirely atomic under the protection of `loop.mutex` to prevent background task wakeups from firing after check sequences but prior to kernel block entries.
  > * Generic task wrappers running during teardown sequences must bypass standard thread locks, relying on non-threadsafe fast-paths (like `Soon.dispatch_guaranteed_nonthreadsafe`) to avoid recursive deadlock spins at loop termination.

---

## 📊 Verification & Benchmarking Targets

All implementation phases must be exhaustively verified to guarantee zero functional regressions:
1. **Thread/GC Sanitizer Run:** Run tests under both `python3.14` and `python3.14t` with garbage collection active to verify reference count integrity.
2. **Ulimit Verification:** Run all suites under strict constraints:
   ```bash
   ulimit -n 1024 ./scripts/test_all.sh
   ```
3. **Execution Throughput Targets:**
   * **Task Spawn:** Boost relative throughput from current **0.57×–0.64×** up to **0.80×** of asyncio.
   * **TCP Echo:** Leverage unified batch completions to sustain performance at **3.0×** relative standard asyncio speed.
