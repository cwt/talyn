---
type: lessons_learned
title: io_uring & Kernel Interaction Lessons
description: SQE submission queue, kernel interactions, ring lifecycle, and buffer management.
tags: [io-uring, kernel, async-io, linux, zig]
timestamp: 2026-07-07T15:35:00Z
---

[⬅️ Back to Lessons Index](./index.md)

# io_uring & Kernel Interaction

Lessons about SQE/CQE lifecycle, io_uring submission, kernel feature gating, fixed files, and deferred I/O buffers.

---

### Immediate vs Deferred Submission

**Lesson 9 — Immediate Submission for Wakeup (EventFD Deadlock)**
Queuing the `eventfd` read SQE without an immediate `submit` caused deadlocks. Background threads wrote to the `eventfd`, but the loop (blocked in `io_uring_enter`) wasn't watching it yet because its SQE was still sitting in the local buffer.
- **Lesson:** Critical "infrastructure" SQEs (like the initial `eventfd` registration) **must** be submitted immediately upon registration. Never defer wakeup mechanisms — the loop must be responsive to external wakeups from the moment the SQE is queued.

**Lesson 60 — Deferred Submission Demands Heap-Owned Inputs**
`Write.perform_with_iovecs` stored the caller's iovec pointer directly in `msg_storage.iov`. With deferred submission (io_uring batches SQEs), the kernel reads the iovec array at submit time — long after the caller's stack frame returned. Stack-allocated iovecs were read from freed memory.
- **Fix:** Copy the caller's iovec array into a heap-allocated buffer owned by the `BlockingTask`. Freed in both `discard` and `deinit` paths.
- **Lesson:** When batching operations into a submission queue, the kernel reads input buffers at **submit time**, not queue time:
  1. Stack-allocated inputs are unsafe — the caller's stack frame may have returned.
  2. Heap-allocated inputs are safe — the heap outlives the caller.
  3. The fix is to copy — if the caller might pass stack inputs, copy into a heap-resident buffer the library owns.
  4. Document if you can't copy — the API contract must state that inputs must outlive the operation.

**Lesson 24 — SQE Use-After-Free via `link_timeout` Failure Rollback**
When `link_timeout` failed (SQ full), `errdefer data_ptr.discard()` recycled the task slot, but the main SQE remained in the ring buffer pointing to the recycled slot. The kernel processed the dangling SQE on next flush, delivering CQEs to a potentially reused slot.
- **Fix:** Wrapped `link_timeout` calls in `catch` blocks. On failure, decrement `ring.sq.sqe_tail` by 1 to roll back the main SQE allocation before propagating the error.
- **Lesson:** When allocating sequential resources that must be submitted or updated atomically, always handle errors by rolling back any partially completed allocations in the sequence.

---

### Kernel Feature Gating

**Lesson 13 — Environment-Dependent Kernel Feature Failures**
`register_files_sparse(8192)` fails under SSH (`ulimit -n 1024`) but succeeds under tmux (ulimit 524288). The graceful fallback set `fixed_files_enabled = false`, but `register_eventfd_callback()` still used `fixed_file_index = 0` with `IOSQE_FIXED_FILE` — the kernel rejected the SQE (`-EBADF`) and the eventfd read never completed. The loop blocked forever in `submit_and_wait(1)` waiting for a CQE that would never arrive.
- **Fix:** `register_eventfd_callback()` branches on `self.fixed_files_enabled` — when disabled, uses raw `self.eventfd` fd with `fixed_file_index = null`.
- **Lesson:** Every kernel-dependent feature gate **must** have a COMPLETE fallback. Check every call site that uses the feature — a single missed path that hardcodes feature-on behavior will silently break. Test fallback paths explicitly: `ulimit -n 1024 bash scripts/test_all.sh`.

**Lesson 48 — Datagram Close Doesn't Cancel Pending io_uring Operations**
`datagram_close` closed the fd immediately without cancelling pending read/write io_uring operations. If the closed fd was reused by the OS before the kernel processed the pending SQEs, those operations ran on the wrong fd.
- **Fix:** Track `read_task_id`. In `datagram_close`, cancel the pending read by task_id and all pending operations for the fd via `IORING_ASYNC_CANCEL_FD`. Flush pending SQEs before closing.
- **Lesson:** When an io_uring-based transport closes its fd, it **must** first cancel any pending operations referencing that fd. Use `IORING_OP_ASYNC_CANCEL` with `IORING_ASYNC_CANCEL_FD` to cancel all operations for a given fd in one shot. Always flush pending SQEs before closing.

**Lesson 105 — Defensive `CancelByFd` Overhead on Socket Teardown**
Unconditionally queuing `CancelByFd` and flushing the submission queue on every socket close/teardown introduces severe performance overhead. While canceling pending operations on close is necessary to prevent use-after-free or fd-reuse issues (Lesson 48), doing so unconditionally (even when no operations are pending) triggers expensive `CancelByFd` calls and submission queue flushes.
- **Fix:** Check if the transport has active pending read or write tasks (`blocking_task_id > 0`) before queuing `CancelByFd`.
- **Lesson:** Defensive safety measures (like cancellation on teardown) must be conditioned on actual resource state. Unconditional operations (especially those involving syscalls or queue flushes) can degrade performance by orders of magnitude under high throughput.

---


### Registration & Fixed Files

**Lesson 12 (cross-reference)** — `ring.fd >= 0` guard before any `register_files_update` call. See [Event Loop Lifecycle](03-event-loop-lifecycle.md).

---

### Syscall & FD Hardening

**Lesson 108 — `pidfd_open` Syscall Flags Strictness**
Passing `PIDFD_CLOEXEC` (`0x80000`) directly to the `pidfd_open` syscall's `flags` argument results in `EINVAL`. The kernel's `sys_pidfd_open` validates flags and only allows `PIDFD_NONBLOCK`.
- **Fix:** Pass `0` to the `pidfd_open` syscall, then use `std.os.linux.fcntl(fd, F_SETFD, FD_CLOEXEC)` to apply `CLOEXEC` to the returned descriptor.
- **Lesson:** Syscall flag arguments are validated strictly in the kernel. Never assume standard file creation flags (like `O_CLOEXEC`) are accepted by specialized descriptor creation syscalls unless explicitly supported in their syscall interface.

**Lesson 109 — Undefined Behavior Optimization on Syscall Integer Casts**
Casting the raw `usize` return value of a syscall (like `pidfd_open`) directly to a signed type like `i32` (`std.posix.fd_t`) to check for `< 0` caused the compiler to optimize the check away in `ReleaseFast` mode, because it assumed `@intCast` would not overflow.
- **Fix:** Check raw syscall returns using `std.posix.errno(rc)` or by casting to `isize` first.
- **Lesson:** Always use `std.posix.errno` to decode syscall return values or check for errors on the raw `usize`/`isize` before performing any `@intCast` casts to smaller signed types. In optimized release modes, overflow UB will cause the compiler to optimize out negative error checks.

**Lesson 110 — DNS Resolver and Inotify `CancelByFd` Requirements**
Closing UDP sockets in the DNS resolver or inotify fds in `FSWatcher` without issuing `CancelByFd` or `.Cancel` in io_uring allowed pending SQEs to run on reused fd numbers.
- **Fix:** Issued `CancelByFd` on socket closure in DNS resolver and `.Cancel` for `inotify_task_id` in `FSWatcher.deinit()`.
- **Lesson:** Any custom transport, watcher, or resolver that queues io_uring operations and manages its own file descriptors must issue explicit cancellation commands before closing fds, preventing fd-reuse race vulnerabilities.
