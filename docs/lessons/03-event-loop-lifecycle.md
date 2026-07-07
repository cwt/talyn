---
type: lessons_learned
title: Event Loop Lifecycle Lessons
description: Shutdown ordering, teardown, coroutine cleanup, and event loop lifecycle management.
tags: [event-loop, lifecycle, shutdown, asyncio, zig]
timestamp: 2026-07-07T15:35:00Z
---

[⬅️ Back to Lessons Index](./index.md)

# Event Loop Lifecycle

Lessons about startup/shutdown ordering, callback execution semantics, exception handling in the loop, and safe teardown.

---

### Shutdown & Teardown Order

**Core rule:** Destroy in the reverse order of acquisition, and drain live observers **before** destroying the resource they observe.

**Lesson 10 — Coroutine Cleanup During Loop Shutdown**
When `KeyboardInterrupt` stops the loop before a Task's initial `execute_task_send` callback runs, the callback stays in the ready queue. During `loop.close()`, `release_ring_buffer` processed it with `cancelled = true`, but `execute_task_send` ignored the cancelled flag and tried to start the coroutine inside a torn-down loop — leading to `RuntimeWarning: coroutine was never awaited`.
- **Fix:** In `execute_task_send`, when `data.cancelled` is true: call `PyIter_Send(coro, None)` to set `gi_frame != NULL` (satisfies CPython's "was awaited" check), clear any Python errors, decref the task, and return.
- **Follow-up:** `execute_task_throw` had the same bug. Fixed by transferring the task's stored exception directly to the future when cancelled, without throwing into the coroutine.
- **Lesson:** Every callback function must handle the `cancelled` flag from `release_ring_buffer`. For task callbacks, the minimum obligation is to ensure the coroutine is "started" in CPython's eyes before discarding it.

**Lesson 12 — Ring FD Lifecycle During Shutdown — Fixed File Unregister**
`Loop.release()` called `io.deinit()` (which sets `ring.fd = -1`) BEFORE processing callbacks in `release_dynamic_ring_buffer`. When a pending callback ran and called `unregister_fixed_file()` → `register_files_update()`, the ring's `assert(fd >= 0)` fired on fd=-1 → `SIGABRT`.
- **Fix (2 parts):**
  1. `IO.unregister_fixed_file()`: check `self.ring.fd >= 0` before calling `register_files_update()`. If ring is deinitialized, skip — `io_uring_queue_exit()` auto-unregisters files.
  2. `Loop.release()`: move `release_dynamic_ring_buffer` **before** `io.deinit()`, then add a second pass after for callbacks dispatched by `cancel_all` during deinit.
- **Lesson:** Any function accessing ring state must guard against the ring being deinitialized. During shutdown, callbacks run at unpredictable times — some before ring deinit, some after. Always check `ring.fd >= 0` before touching ring API.

**Lesson 56 — Teardown Order: Drain Live Resources Before Destroying the I/O Backend**
In `Loop.deinit`, `reader_watchers` and `writer_watchers` were drained **after** `io.deinit()`. The `FDWatcher` structs hold `blocking_task_id` values referencing io_uring SQEs, but the ring was already destroyed.
- **Fix:** Moved watcher drain to before `io.deinit()`.
- **Lesson:** Teardown order matters and is the **inverse of setup order**:
  1. Acquire: A, then B (B depends on A).
  2. Release: drain B's observers → deinit B → deinit A.
  3. Drain observers **before** deiniting what they observe.
  This applies to DB connections, GUI frameworks, network services, and RAII in C++.

**Lesson 84 — Container Cleanup Needs Domain-Specific Knowledge**
`Loop.deinit` cleared `prepare_hooks`, `check_hooks`, and `idle_hooks` with `LinkedList.clear()`, which only destroys linked-list nodes but doesn't call `Callback.cleanup`. Python references held in callback data leaked.
- **Fix:** Added `clear_with_cleanup` method to `LinkedList` that invokes the cleanup function on each node before destroying. Used in `Loop.deinit`.
- **Lesson:** Generic containers can't know about domain-specific cleanup. Provide a "domain-aware cleanup" variant (e.g., `clear_with_cleanup`) and let the caller choose. The "caller handles all cleanup" pattern is easy to forget for domain objects that hold resources.

**Lesson 104 — Watcher Re-arming Races on Stopping Loop**
A modified loop runner that attempted to completely drain both swap queues before exiting would hang indefinitely with active, self-re-arming watchers (level-triggered fd readers that trigger and re-arm immediately in `ReleaseFast`).
- **Fix:** Reverted shutdown logic to the standard Python AsyncIO spec: break at the end of the current iteration when `stopping` is true, not on empty queues.
- **Lesson:** Align runner loop conditions strictly with standard runtime behaviors. A "thorough cleanup drain" on an event loop can cause infinite loops if active watchers continuously re-arm. Exit immediately; handle remaining watcher cleanup during loop deinitialization instead.

---

### Callback Execution Semantics

**Lesson 2 — Signal Resilience (EINTR is a Constant)**
Signals can interrupt system calls at any time, returning `EINTR`. If not handled, this propagates as a Zig panic or unexpected Python exception.
- **Lesson:** Every kernel-level interaction (`submit`, `wait`, `waitpid`) **must** be wrapped in a retry loop or silent ignore for `SignalInterrupt`. The event loop should never exit due to a signal.

**Lesson 5 — Standard Resilience (Loop Never Quits)**
A single misbehaving callback could raise an exception that bubbled up to the Zig loop runner, stopping the entire loop.
- **Lesson:** Catch all exceptions at the callback boundary, route them to the loop's exception handler, and **continue** to the next event. The loop should only exit via explicit `stop()` or fatal signals.

**Lesson 8 — Fatal Exception Propagation (Loop Hangs)**
The Zig exception handler was capturing ALL errors and routing them to `loop.call_exception_handler`. For `KeyboardInterrupt`/`SystemExit`, this just logged the error and returned control to Zig — creating an infinite loop where the interrupt was ignored.
- **Lesson:** Explicitly check for fatal exceptions in the Zig callback runner. If `KeyboardInterrupt` or `SystemExit` is active, bypass the handler and return an error immediately to stop the event loop.

**Lesson 47 — `dispatch_completion_batch` Drops Remaining Records on Python Error**
When `PyBytes_FromStringAndSize` or `PyObject_CallOneArg` returned null, the function immediately reset the batch and returned, discarding all remaining records — silent data loss for unrelated connections.
- **Fix:** Continue processing all records even if one fails. Set a `had_error` flag, then return the error after processing the entire batch.
- **Lesson:** When processing batches of independent operations, don't let one failure stop the entire batch. In event loops, dropping completions causes silent data loss that is very difficult to debug.

**Lesson 57 — Silent Failure is the Worst Kind of Failure**
`WriteTransport.submit_next_chunk` silently returned on an out-of-sync invariant violation, dropping outstanding bytes and causing a CPU spin as the upper layer kept calling it.
- **Fix:** Detect the out-of-sync state explicitly and surface it as a hard error (`return error.WriteBufferIndexOverflow`), propagating up to `connection_lost`.
- **Lesson:** When you detect an invariant violation, the worst thing is to silently return. Fix hierarchy:
  1. Detect it.
  2. Surface it loudly (`std.log.err` + return error).
  3. Make the failure recoverable (tear down connection, propagate to exception handler).
  If you write `if (something_that_should_be_impossible) { return; }` — you're hiding a bug. Either prove it's impossible (use `unreachable`/`assert`), or handle it explicitly.

**Lesson 85 — Make `else` Branches Visible**
`dispatch_completion_batch` had a bare `else => {}` that silently dropped 6 unhandled operation variants with no warning.
- **Fix:** Replaced `else => {}` with explicit cases that log a `std.log.warn` naming the dropped op.
- **Lesson:** Bare `else => {}` branches are silent bugs waiting to happen. Make default branches **loud**: log the dropped op. This applies to switch statements on enums, protocol message handlers, and syscall return codes.

**Lesson 86 — Distinguish Expected From Unexpected Outcomes**
Cancel operations had empty handlers — unexpected error codes (EINVAL, EBADF) from cancel were silently dropped.
- **Fix:** Added explicit handling: SUCCESS and NOENT are expected; any other result is logged as a warning.
- **Lesson:** Even for fire-and-forget operations, distinguish "expected outcome" from "unexpected outcome". If you can't enumerate the expected codes, log anything unexpected. "Fire-and-forget with silent result" hides bugs.

---

### Event Loop Configuration & Optimization

**Lesson 19 — Syscall Elimination / Short-Circuit Empty-SQE**
The default `flush_pending_sqes` would issue a system call even when the submission queue had no pending events.
- **Lesson:** Always check `ring.sq_ready()` to short-circuit flushes. Under heavy in-memory workloads, this yields immense CPU savings — **0 syscalls per tick** when processing in-memory task queues.

**Lesson 20 — Zero-Workqueue Socket State Machines Are Not Worth It**
Replacing `IOSQE_ASYNC` with a user-space multi-step state machine (inline syscall → `POLL_ADD` → callback → inline syscall → re-arm) produced 3-4 CQE cycles per connection. Under GIL Python's sequential callback processing, this stalled and caused timeouts.
- **Lesson:** Don't replace a simple, stable kernel path with a complex user-space state machine just to avoid workqueue overhead. More event loop round-trips ≠ better performance. The 0.67× Socket Ops speed under GIL Python is an inherent characteristic of the io_uring workqueue path, not a bug to be fixed.

**Lesson 82 — Never Leave Debug Prints in Hot Paths**
Four `std.debug.print` calls in the event loop's main blocking wait ran on every loop iteration — each was a synchronous stderr write, severely degrading performance.
- **Lesson:** Any code that runs in a loop on a hot path should be O(1) and side-effect-free. "Temporary" debug prints inevitably make it to production. Remove them or guard behind a comptime debug flag.
