[⬅️ Back to Lessons Index](../lessons-learned.md)

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

---

### Registration & Fixed Files

**Lesson 12 (cross-reference)** — `ring.fd >= 0` guard before any `register_files_update` call. See [Event Loop Lifecycle](03-event-loop-lifecycle.md).
