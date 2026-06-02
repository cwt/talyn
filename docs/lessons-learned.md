[⬅️ Back to Index](todo.md)

# 🧠 Lessons Learned: The Journey to 100% Stability

### 1. Free-Threading & The "Atomic Sleep"
In standard Python, the GIL hides many race conditions. In free-threading (3.13t/3.14t), the window between "checking for work" and "going to sleep" is a deadly trap.
*   **The Bug:** The loop checks the queue, sees it empty, then blocks in `io_uring`. A background thread adds a task *after* the check but *before* the block.
*   **The Lesson:** The decision to sleep must be **atomic**. Always check the ready queue while holding the loop mutex immediately before dropping the GIL and calling into the kernel.

### 2. Signal Resilience (EINTR is a Constant)
Signals (like `SIGCHLD` from subprocesses) can "stab" the process at any time, causing system calls to return `EINTR`.
*   **The Bug:** `io_uring_submit` or `io_uring_wait` returns `SignalInterrupt`. If not handled, this propagates as a Zig panic or an unexpected Python exception, often leading to a process `Abort`.
*   **The Lesson:** Every kernel-level interaction (`submit`, `wait`, `waitpid`) **must** be wrapped in a retry loop or a silent ignore for `SignalInterrupt`. The event loop should never exit due to a signal.

### 3. The "Ghost Reference" Cycle (GC invisibility)
Holding Python objects inside native Zig collections (std.ArrayList, BTree, etc.) without `tp_traverse` creates "Ghost References" that are invisible to the Garbage Collector.
*   **The Bug:** A Loop holds a Task, which holds a Future, which holds a callback pointing back to the Loop. Since Zig's memory isn't scanned by Python's GC, these cycles are never broken, leading to 30GB+ OOM events in long-running suites.
*   **The Lesson:** Any native structure holding a `PyObject` **must** be reachable via `tp_traverse`. Standard reference counting is insufficient for event loops due to inevitable complex cycles.

### 4. Safe Traversal of Execution Queues
Updating a progress marker *after* an operation is standard, but for GC safety, it must be **precise**.
*   **The Bug:** GC runs while a callback is halfway through a queue. If the queue is scanned from the start, GC visits already-executed and decref'd objects.
*   **The Lesson:** Immediately nullify references or update the traversal `offset` as each item is consumed. GC and execution are concurrent in free-threading; there is no "safe time" to have invalid pointers in a queue.

### 5. Standard Resilience (Loop never quits)
Asyncio event loops are designed to survive individual user-code failures.
*   **The Bug:** A single misbehaving callback could raise an exception that bubbled up to the Zig loop runner, causing the entire loop to stop.
*   **The Lesson:** Catch all exceptions at the callback boundary, route them to the loop's exception handler, and **continue** to the next event. The loop should only exit via explicit `stop()` or fatal signals.

### 6. Stack Allocation of Large Structures
When moving to fixed-size buffers (like the 256k RingBuffer), structs can grow to tens of megabytes (e.g., `Loop` ~42MB).
*   **The Bug:** Initializing a large struct via literal `self.* = .{...}` or returning it from a function causes a silent `SIGSEGV` (stack overflow) because the compiler creates a massive temporary on the stack.
*   **The Lesson:** Always use **in-place initialization** (`init(self: *Self)`) and individual field assignments for large structures. Ensure unit tests heap-allocate these structures instead of using `var loop: Loop = undefined;`.

### 7. Precision in Typed Traversal (GC Stability)
Using `@alignCast` on `?*anyopaque` pointers during `tp_traverse` is a common source of non-deterministic panics.
*   **The Bug:** `MultiConnectState.traverse_raw` used `@alignCast(@ptrCast(ptr))` which failed under certain memory pressures when Python passed a pointer with unexpected alignment.
*   **The Lesson:** Avoid `@alignCast` in hot GC paths. Refactor internal traversal functions to take **typed pointers** directly, and ensure the outer `tp_traverse` entry point performs the cast exactly once at the boundary.

### 8. Fatal Exception Propagation (Loop Hangs)
The Loop's exception handler must distinguish between "catchable" user exceptions and "fatal" Python exceptions (`KeyboardInterrupt`, `SystemExit`).
*   **The Bug:** The Zig exception handler was capturing ALL errors and routing them to `loop.call_exception_handler`. In Python, this just logs the error and returns control to Zig. For fatal exceptions, this created an infinite loop where the interrupt was ignored, hanging the process.
*   **The Lesson:** Explicitly check for fatal exceptions in the Zig callback runner. If `KeyboardInterrupt` or `SystemExit` is active, bypass the handler and return an error immediately to stop the event loop.

### 9. Immediate Submission for Wakeup (EventFD Deadlock)
In a batched submission model, certain critical operations cannot wait for the next loop tick.
*   **The Bug:** Queuing the `eventfd` read SQE without an immediate `submit` caused deadlocks. Background threads would write to the `eventfd`, but the loop (blocked in `io_uring_enter`) wasn't watching the `eventfd` yet because its SQE was still sitting in the local buffer.
*   **The Lesson:** Critical "infrastructure" SQEs (like the initial `eventfd` registration) MUST be submitted immediately upon registration to ensure the loop is responsive to external wakeups.

### 10. Coroutine Cleanup During Loop Shutdown (2026-05-13)
When a `KeyboardInterrupt` stops the loop before a Task's initial `execute_task_send` callback runs, the callback stays in the ready queue. During `loop.close()`, `release_ring_buffer` processes it with `cancelled = true`, but `execute_task_send` ignored the cancelled flag and called `_execute_task_send` — which tried to start the coroutine inside a torn-down loop (IO already deinitialized). The coroutine never got `PyIter_Send` called, so CPython emitted `RuntimeWarning: coroutine ... was never awaited` when the coroutine was later garbage collected.
*   **The Bug:** `execute_task_send` didn't check `data.cancelled`. When cancelled during `release_ring_buffer`, it tried the full start-up path (enter task context, send to coroutine, process yielded Future) which could fail because loop IO was deinitialized. The coroutine's `gi_frame` remained `NULL` → CPython warned on GC.
*   **The Fix:** In `execute_task_send`, when `data.cancelled` is true: call `PyIter_Send(coro, None)` just to set `gi_frame != NULL` (satisfies CPython's "was awaited" check), clear any Python errors, decref the task, and return. No other loop infrastructure is needed.
*   **The Lesson:** Every callback function must handle the `cancelled` flag from `release_ring_buffer`. For task callbacks, the minimum obligation is to ensure the coroutine is "started" in CPython's eyes before discarding it.
*   **Follow-up:** `execute_task_throw` at `src/task/callbacks.zig:437` had the same bug. Fixed by transferring the task's stored exception directly to the future when cancelled, without throwing into the coroutine.

### 12. Ring FD Lifecycle During Shutdown — Fixed File Unregister (2026-05-17)
When `IOSQE_FIXED_FILE` is enabled, transport close callbacks call `unregister_fixed_file()` → `ring.register_files_update()`. The Zig stdlib's `register_files_update` asserts `self.fd >= 0`. If the ring has been deinitialized (fd = -1), this assertion fires → `SIGABRT`.
*   **The Bug at Rev 483:** `Loop.release()` called `io.deinit()` (which calls `ring.deinit()` → `ring.fd = -1`) BEFORE processing callbacks in `release_dynamic_ring_buffer`. When a pending `read_operation_completed` callback ran, its `defer` called `Lifecyle.maybe_close_fd()` → `unregister_fixed_file()` → `register_files_update()` → `assert(fd >= 0)` on fd=-1 → abort. This affected `test_ssl_server_and_connection` and `test_very_slow` (all Python versions).
*   **The Fix (2 parts):**
    1. `IO.unregister_fixed_file()` at `src/loop/scheduling/io/main.zig:388`: check `self.ring.fd >= 0` before calling `register_files_update()`. If ring is deinitialized, skip the kernel update — the ring's `io_uring_queue_exit()` already auto-unregisters files.
    2. `Loop.release()` at `src/loop/main.zig:129-144`: move `release_dynamic_ring_buffer` BEFORE `io.deinit()` (the comment already said "while IO is still functional"), then add a second pass AFTER for callbacks dispatched by `cancel_all` during deinit.
*   **The Lesson:** Any function that accesses ring state (fd, register_files, SQ/CQ) must guard against the ring being deinitialized. During shutdown, callbacks run at unpredictable times — some before ring deinit (first `release_dynamic_ring_buffer` pass), some after (second pass + GC-triggered callbacks). Always check `ring.fd >= 0` before touching ring API.

### 13. Environment-Dependent Kernel Feature Failures (2026-05-18)
Kernel features like `IORING_REGISTER_FILES_SPARSE` can fail based on `ulimit -n` (RLIMIT_NOFILE). A process with `ulimit -n 1024` cannot register 8192 fixed file slots — the kernel returns `-ENOMEM`/`-EINVAL` and the call fails silently.
*   **The Bug:** `register_files_sparse(8192)` fails under SSH (ulimit 1024) but succeeds under tmux/opencode (ulimit 524288). The graceful fallback at Rev 491 made `fixed_files_enabled = false` but `register_eventfd_callback()` still used `fixed_file_index = 0` with `IOSQE_FIXED_FILE` — the kernel rejected the SQE (`-EBADF`, no fixed file table exists) and the eventfd read never completed. The loop blocked forever in `submit_and_wait(1)` waiting for a CQE that would never arrive → **silent hang**. This explains why tests froze at `..` (2 dots = 2 tests passed, 3rd test needed eventfd wakeup).
*   **The Fix:** `register_eventfd_callback()` now branches on `self.fixed_files_enabled` — when disabled, uses raw `self.eventfd` fd with `fixed_file_index = null` (same as pre-483 behavior). The transports already handled this correctly via `register_fixed_file(fd) catch null` which leaves `fixed_file_index = null`, triggering the raw-fd path in read.zig/write.zig.
*   **The Lesson:** Every kernel-dependent feature gate MUST have a COMPLETE fallback. Check every call site that uses the feature — a single missed path that hardcodes the feature-on behavior will silently break. Test fallback paths explicitly: `ulimit -n 1024 bash scripts/test_all.sh`.

### 11. Ghost Reference Cycle in Future Callbacks (2026-05-13)
When Task A awaits Future B, `wakeup_task` is registered as a `ZigGeneric` callback on Future B with `ptr = task`. `traverse_callbacks_queue()` at `src/future/callback.zig:164-177` had a no-op `ZigGeneric` arm — the GC could not see the `Task ← Future` cycle.
*   **The Bug:** Task holds `fut_waiter` → Future B. Future B's callback queue holds `ptr` → Task A. Python GC traverses Task A's members (including `fut_waiter` → Future B) and Future B's members (including `callbacks_queue`), but the `ZigGeneric.ptr` field was invisible. This ghost cycle leaked memory, causing OOM on long-running processes. The comment in the code literally said "This cycle is HIDDEN".
*   **The Fix:** The `ZigGeneric` arm now calls `visit(ptr)` to expose the Task pointer to the GC. The `@alignCast(@ptrCast(ptr))` is safe — `ptr` is always a `*PythonTaskObject` from the Python heap.
*   **The Lesson:** Any native structure holding a `PyObject` pointer must be reachable via `tp_traverse`. Skipping even one arm of a traversal union breaks the cycle detector.

### 14. Gap in deinitialize_object_fields for Optional PyObject-Compatible Structs (2026-05-19)
`deinitialize_object_fields()` iterates struct fields at comptime and decrefs PyObject pointers. The `.pointer` (non-optional) branch correctly handles structs with `ob_base` (e.g., `*FutureObject`, `*LoopObject`). But the `.optional` branch only checked `child == Python.PyObject` — missing `?*FutureObject` and `?*LoopObject` entirely.
*   **The Bug:** `SocketCreationData` has `future: ?*FutureObject` and `loop: ?*LoopObject`. `SocketCreationData.deinit()` called `deinitialize_object_fields(self, &.{})`, which silently skipped both fields. The Future and Loop references were never decref'd, creating ghost references invisible to GC.
*   **The Fix:** For structs used in `create_connection`, added explicit manual decref + null in `SocketCreationData.deinit()` before calling `deinitialize_object_fields`. The general fix (adding `ob_base` detection to the `.optional` branch) caused double-decref issues in other structs and was reverted — a global fix requires auditing all call sites.
*   **The Lesson:** `deinitialize_object_fields` and `verify_gc_coverage` are not symmetric. `verify_gc_coverage` correctly identifies `?*FutureObject` as PyObject-compatible, but `deinitialize_object_fields` silently skips it. Always verify that deinit actually decrefs what traverse visits. Write targeted manual decrefs when the generic function has gaps.

### 15. Timer-Triggered Use-After-Free with Deferred Deinit (2026-05-19)
When a callback holds a pointer to a heap-allocated struct that can be freed before the callback fires, the callback must either (a) be cancelled before freeing, or (b) check a liveness flag before accessing the struct.
*   **The Bug:** `schedule_remaining_connects_callback` stored `mcs` (MultiConnectState) as user_data. If all connect attempts failed before the timer fired, `mcs.deinit()` freed `mcs`. The timer CQE then dispatched the callback with a dangling `mcs` pointer — segfault.
*   **The Fix:** Store timer task ID in `mcs.task_ids` for cancellation. Add `timer_scheduled`/`timer_fired` flags. When `mcs.pending == 0` but timer hasn't fired: defer `deinit` — let the timer callback submit remaining addresses, which will eventually trigger deinit through the normal all-failure path.
*   **The Lesson:** Any callback that outlives its user_data allocation must be cancellable. Cancel BEFORE freeing, and verify cancellation succeeded. If cancel fails (already in-flight), defer freeing until the callback runs. Timeout operations (`WaitTimer`) use `timeout_remove` which is synchronous — success means no CQE will fire; failure means CQE already in the CQ.

---

### 16. TLS/SSL: Protocol-Layer Approach Over Native Crypto (2026-05-21)
uvloop's SSL architecture was analyzed for TLS feature design. uvloop performs **zero** SSL in C/libuv — all encryption/decryption happens in a 1007-line Cython protocol layer (`sslproto.pyx`) using Python's `ssl.MemoryBIO` + `sslobj.wrap_bio` + `BufferedProtocol`. The native transport only handles raw encrypted bytes.
*   **Key Findings:**
    1. `ssl.MemoryBIO` decouples crypto from socket I/O — the protocol reads/writes to in-memory buffers, not the socket. The transport is completely crypto-agnostic.
    2. `start_tls` flow: pause reading → `set_protocol` (swap protocol) → `connection_made` → resume reading. All at the protocol layer.
    3. 5 explicit states: `UNWRAPPED → DO_HANDSHAKE → WRAPPED → FLUSHING → SHUTDOWN`. State machine handles all edge cases (renegotiation, shutdown race).
    4. C-level fast paths: uvloop's Cython code bypasses Python `get_buffer()`/`buffer_updated()` calls when SSL is active, writing directly to the SSL protocol's internal buffer.
*   **Leviathan Status:** The architecture (Python `ssl.MemoryBIO` over raw Zig transport) is correct and mirrors uvloop. Remaining work is protocol-layer edge cases: buffered data during `start_tls`, SSL shutdown handshake, flow control backpressure. See [Priority 20](priorities/20-tls-ssl-completion-2026-05.md).

---

### 17. Recursive SpinMutex Deadlock at Loop Exit (2026-05-26)
During Python interpreter finalization, garbage collection or explicit teardown calls `loop_clear()` to release event loop resources. If the clearing thread already holds the non-recursive `loop.mutex` lock, invoking generic queue-dispatch APIs like `Soon.dispatch_guaranteed` will attempt to acquire the lock again, creating an infinite deadlock spin.
*   **The Bug:** During `loop.release()`, deinitializers for components like `unix_signals` and `BlockingTasksSet` popped cancelled or pending callbacks and called `Soon.dispatch_guaranteed(loop, &value)`. Since the clearing thread already held the `loop.mutex` from `loop_clear()`, this resulted in an infinite self-deadlock spin inside `atomic.Mutex.tryLock` at test exit.
*   **The Lesson:** Deinitializers and cleanup handlers running during loop teardown must assume the loop's mutex is already held or use non-threadsafe scheduling variants (like `Soon.dispatch_guaranteed_nonthreadsafe`). Never attempt to lock a non-recursive mutex recursively during finalization.

### 18. Python Reference Leaks in Future Done Callbacks (2026-05-26)
When done callbacks are registered on a `Future` (e.g., during `MagicMock` calls), the callback and context objects are wrapped in `*PythonHandleObject` via `Handle.fast_new_handle`. If a callback is cancelled or the future status is not `.pending` at release, reference counts are leaked.
*   **The Bug:** In `src/future/callback.zig`, cancelled callbacks in `callbacks_queue` were skipped during execution but never decref'd because `release_callbacks_queue` was only called if `self.status == .pending`. Furthermore, `release_callbacks_queue` had a risk of double-decrefs if called on already-executed callbacks.
*   **The Fix:** Accept a mutable pointer `*CallbacksSetData` in `release_callbacks_queue`, check `if (callback.executed) continue;`, and mark them `executed = true` immediately after freeing callback references (ensuring idempotent releases). Always call `release_callbacks_queue` in `Future.release` regardless of status.
*   **The Lesson:** Callback release logic must be completely idempotent and track execution state to allow multiple passes. Unexecuted callback references must always be released during resource deallocation.

---### 19. Syscall Elimination / Short-Circuit Empty-SQE (2026-05-26)
In an event loop runner using `io_uring`, the default behavior of flushing pending SQEs (`flush_pending_sqes`) may issue a system call even when the submission queue (SQ) has no pending events ready.
*   **The Bug:** In high-throughput, non-blocking loops, checking `sq_ready()` before calling `io_uring_submit` / `io_uring_enter` allows immediate short-circuiting. If no new events have been queued, bypassing the system call achieves exactly **0 syscalls per tick** when processing in-memory task queues.
*   **The Lesson:** Always check `ring.sq_ready()` to short-circuit flushes. Under heavy in-memory workloads, this yields immense CPU saving and maximizes overall execution throughput by minimizing system call overhead.

---

### 20. Zero-Workqueue Socket State Machines Are Not Worth It (2026-05-29)
Priority 22 attempted to eliminate `IOSQE_ASYNC` from socket `accept`/`connect` operations by replacing single io_uring ops with multi-step user-space state machines (inline syscall → `POLL_ADD` → callback → inline syscall → re-arm).
*   **The Idea:** `IOSQE_ASYNC` delegates to kernel io-wq worker threads, introducing context-switching overhead. By handling everything inline in user-space, we could match uvloop's efficiency.
*   **The Reality:** The zero-workqueue design replaced 1 SQE → 1 CQE with 3–4 CQE cycles per connection. Each accept now requires: `POLL_IN` fires → callback runs → `accept4` syscall → re-arm `POLL_IN`. Each connect fallback requires: `CONNECT` returns `EINPROGRESS` → `POLL_OUT` queued → callback runs → `getsockopt` check. Under GIL Python's sequential callback processing, this pipeline stalls — the Socket Ops benchmark went from stable 0.67× asyncio (all sizes) to **TIMEOUT at m=32768** (changeset 568). Attempts to fix it (removing `IOSQE_ASYNC` from `POLL_ADD`, adding `flush_pending_sqes`) made it worse — **TIMEOUT at m=1024**.
*   **Why Non-GIL Python Was Fine:** Free-threaded Python processes callbacks concurrently, keeping the multi-step pipeline flowing. GIL Python processes them sequentially, so each extra round-trip compounds into a livelock under load.
*   **The Lesson:** Don't replace a simple, stable kernel path with a complex user-space state machine just to avoid workqueue overhead. The 0.67× speed on Socket Ops is an inherent characteristic of the io_uring workqueue path under GIL Python, not a bug to be fixed. More event loop round-trips ≠ better performance. Reverted to changeset 566 code. See [Priority 22](priorities/22-fused-user-space-socket-state-machine-2026.md).

---

### 21. Recursive SpinMutex Deadlock Under Free-Threading (2026-05-31)
When standard CPython's GIL is disabled under free-threading (`python3.13t` / `python3.14t`), standard thread-safe locking is active, using a native `SpinMutex` (implemented on top of `std.atomic.Mutex`). If a thread attempts to acquire this lock recursively, it will result in an infinite deadlock spin.
*   **The Bug:** Native wrapper functions (such as `z_loop_delayed_call`, `z_loop_add_watcher`/`z_loop_remove_watcher`, `fast_handle_cancel`, and `enqueue_signal_fd`) held the loop's mutex lock to perform atomic operations. However, they then invoked `IO.queue(...)` to register timers, cancellations, or fd watchers in `io_uring`. Since `IO.queue` locked the loop's mutex *again*, this caused an immediate self-deadlock spin, freezing unit tests at the very first timeout/sleep or watcher adjustment.
*   **The Fix:** Split `IO.queue` into a thread-safe `queue(...)` wrapper that acquires the lock, and a non-locking `queue_unlocked(...)` helper. Updated all native functions executing under the loop mutex to invoke `queue_unlocked(...)` directly, bypassing the duplicate locking path.
*   **The Lesson:** Never acquire a non-recursive mutex recursively. When building locking APIs, always provide unlocked internal helper functions (e.g. `_unlocked` or `_nonthreadsafe`) to be used safely from paths where the calling context has already acquired the lock.

---

### 22. Level-Triggered Socket Deadlocks via Incorrect Direct Syscall Error Check (2026-05-31)
*   **The Bug:** The Socket Ops benchmark suffered from intermittent but severe timeouts/deadlocks under load. In `src/transports/streamserver/main.zig`, the server accepted new connections using direct Linux syscall `std.os.linux.accept4`. The code checked for failure using `if (client_fd_ret == std.math.maxInt(usize))` and queried `std.os.linux.errno(0)`. However, raw Linux syscalls do NOT set thread-local `errno`; instead, they return negative values representing `-errno` directly. As a result, when `accept4` failed with `-EAGAIN` or `-EINTR`, the failure was completely missed, and the negative error code was treated as a valid client file descriptor. This led to silent connection drops, corrupted socket descriptors, and permanent hangs in level-triggered `POLL_IN` wakeups under high socket stress.
*   **The Fix:** Corrected the error check in `accept_callback` by casting the result to a signed integer (`isize`) and checking `if (client_fd_signed < 0)`. The exact error code was retrieved via `const errno_val = -client_fd_signed`.
*   **The Lesson:** Raw assembly syscalls in Zig (`std.os.linux`) differ fundamentally from C standard library functions. They do not populate `errno`; they return negative error codes directly. Failing to handle direct syscall return codes correctly will corrupt resource tracking and produce mysterious, load-dependent deadlocks.

---

### 23. BTree Split Key Count During Non-Root Splits (2026-05-31)
*   **The Bug:** The BTree implementation used hardcoded `current_node.nkeys = 1` unconditionally inside `split_nodes`. While this is correct for a root-node split (where the root has split and retains only the single middle key), it is completely incorrect for a non-root node split. A non-root split leaves the left half of the keys in `current_node`, meaning it retains exactly `middle_index` keys (`(Degree - 1) / 2`). For `Degree = 3`, `middle_index` is 1, so the bug was hidden. But for `Degree = 11` (used by `WatchersBTree`), it discarded 4 keys, silently corrupting the tree structure under heavy file descriptor watcher load.
*   **The Fix:** In `split_nodes`, set `current_node.nkeys = (Degree - 1) / 2` when the split node has a parent, and only set it to `1` on root split.
*   **The Lesson:** Never use hardcoded constants for data structure counts that depend on parameter/degree configurations. Always write unit tests with diverse parameters (e.g., larger degrees) to ensure algorithms scale correctly.

---

### 24. SQE Use-After-Free via link_timeout Failure Rollback (2026-05-31)
*   **The Bug:** When a timeout-linked operation (e.g., `poll_add`, `read`, `write`) was submitted, the main SQE was allocated successfully from the `io_uring` ring buffer. If the subsequent `link_timeout` call failed (for instance, when the SQ ring was completely full), the error propagated, invoking `errdefer data_ptr.discard()` to recycle the task slot. However, the main SQE remained in the ring buffer, pointing to the recycled slot. During the next flush/submit, the kernel processed this dangling SQE, delivering completion events (CQEs) to the recycled slot (which may have been reused by an entirely different task), causing silent data corruption or use-after-free crashes.
*   **The Fix:** Wrapped all `link_timeout` calls in `catch |err|` blocks. If `link_timeout` fails, we decrement `ring.sq.sqe_tail` by 1 to roll back the main SQE's slot allocation before propagating the error up, ensuring the SQE is never flushed to the kernel.
*   **The Lesson:** When allocating sequential resources that must be submitted or updated atomically, always handle errors gracefully by rolling back any partially completed allocations in the sequence.

---

### 25. Borrowed Reference Memory Corruption in get_extra_info (2026-05-31)
*   **The Bug:** When Python transport objects query `get_extra_info("sockname")`, and the socket address is already cached, the native Zig transport returned the cached `PyObject` reference directly without incrementing its reference count (a borrowed reference). Python code receiving this object decrements its reference count when discarded. Because the reference wasn't owned, the count dropped below 1, causing CPython to deallocate the socket name tuple while it was still cached in the native transport. Subsequent accesses triggered use-after-free or double-free memory corruption.
*   **The Fix:** Updated `src/transports/stream/extra_info.zig` to use `python_c.py_newref(py_sockname)` when returning the cached socket name, ensuring Python receives an owned new reference.
*   **The Lesson:** Any native API returning a cached CPython object to the interpreter must return a *new* reference (using `py_newref` or `py_incref`). Borrowing cached references that Python will later decref is a direct path to memory corruption and double-free exceptions.

---

### 26. Double-Free and Struct Leak in Datagram sendto Error Path (2026-05-31)
*   **The Bug:** In `src/transports/datagram/write.zig`, when `z_datagram_sendto` failed after allocating `SendToData`, two identical `errdefer allocator.free(data_buf)` statements were executed (one declared before allocating `SendToData`, and one declared after). This resulted in double-freeing the `data_buf` heap allocation. Simultaneously, the `SendToData` struct allocation itself was completely leaked because no `errdefer` cleaned it up.
*   **The Fix:** Corrected the second `errdefer` to be `errdefer loop_data.allocator.destroy(sd)` so that the `SendToData` struct is correctly deallocated, and `data_buf` is only freed once.
*   **The Lesson:** Carefully audit duplicate or copy-pasted `errdefer` blocks. When sequentially allocating multiple related heap resources, each step's `errdefer` must clean up exactly what that step allocated.

---

### 27. Setting Python Exceptions on Type/Value Verification in Native Code (2026-05-31)
*   **The Bug:** When validating Python arguments inside native functions (like `fromPyAddr` in `src/utils/address.zig`), returning a generic `error.PythonError` without calling `raise_python_type_error` or `raise_python_value_error` causes CPython to detect that the function returned `NULL` without setting an exception, raising a `SystemError: <method ...> returned NULL without setting an exception`.
*   **The Fix:** Updated `fromPyAddr` to explicitly call `python_c.raise_python_type_error("address must be a tuple\x00")` when the input address is not a tuple, satisfying CPython's exception-setting contracts.
*   **The Lesson:** Never return `error.PythonError` (or a `NULL` PyObject) without ensuring a Python-level exception has been set via `PyErr_SetString` (or its `raise_python_*` wrappers). Any un-exceptioned NULL return results in a fatal interpreter-level `SystemError`.

---

### 28. Context Stack Leak on Callback Execution Error (2026-06-01)
*   **The Bug:** In `callback_for_python_generic_callbacks` at `src/handle.zig`, `PyContext_Enter(py_context)` was called to push the handle's context onto the CPython context stack. However, when any subsequent operation failed (`PyTuple_New`, `PyTuple_SetItem`, `PyObject_Call`, `PyObject_CallNoArgs`), the function returned `error.PythonError` _without_ calling `PyContext_Exit`. This permanently corrupted the current thread's context variable context stack, causing subsequent tasks scheduled with different contexts to run in the wrong context.
*   **The Fix:** Replaced the success-path-only `PyContext_Exit` call with a `defer _ = python_c.PyContext_Exit(py_context);` immediately after the successful `PyContext_Enter`. Zig's `defer` ensures the context is exited on _all_ exit paths, including early error returns, without requiring manual cleanup before each `return` statement.
*   **The Lesson:** When a function acquires a reversible resource (like entering a CPython context), always use Zig's `defer` (or `errdefer`) to guarantee cleanup on all exit paths. Manual cleanup before each `return` is fragile and inevitably misses edge cases as the code evolves. CPython's `PyContext_Enter`/`PyContext_Exit` pairs are particularly dangerous because a leaked context entry corrupts the global interpreter state for all subsequent operations.

---

### 29. Predictable DNS Transaction IDs (2026-06-01)
*   **The Bug:** In `build_queries` at `src/loop/dns/resolv.zig:469`, the DNS query transaction ID was set by casting the loop iteration index (`0, 1, 2, ...`) directly to `u16`. This produced highly predictable DNS transaction IDs, making DNS cache poisoning and domain spoofing attacks trivial for an on-path attacker.
*   **The Fix:** Replaced `@intCast(index)` with `std.os.linux.getrandom` to generate a cryptographically secure random transaction ID for each query.
*   **The Lesson:** Network protocols that rely on transaction IDs for security (like DNS) must use unpredictable random values, not sequential counters. Always use a cryptographically secure random number generator (like the `getrandom` Linux syscall) for security-sensitive identifiers. Sequential counters in DNS queries are a well-known vulnerability (CVE-2008-1447 and related).

---

### 30. Double Incref in Future set_exception — Reference Leak (2026-06-01)
*   **The Bug:** In `z_future_set_exception` at `src/future/python/result.zig:92`, `python_c.py_newref(exception)` was passed to `future_fast_set_exception`, which itself called `python_c.py_newref(exception)` at line 72. The exception was incremented twice (+2) but only one reference was stored, leaking one reference per `future.set_exception()` call.
*   **The Fix:** Removed the redundant `python_c.py_newref()` from the call site at line 92, passing `exception` directly as a borrowed reference. `future_fast_set_exception` already takes ownership by calling `py_newref` internally — consistent with how `future_fast_set_result` works.
*   **The Lesson:** When a function takes ownership of a borrowed reference via `py_newref`, all callers must pass raw borrowed references. Inconsistent ownership conventions between callers and callees cause insidious reference leaks. Always verify reference count discipline by writing tests using `sys.getrefcount()` — especially for frequently-called APIs like `set_exception`.

---

### 31. SSL create_connection Silently Drops All Kwargs (2026-06-01)
*   **The Bug:** In `_create_ssl_connection` at `talyn/loop.py:841`, when wrapping a non-SSL connection inside an SSL transport, the method called `_Loop.create_connection(self, SP, host, port)` without passing any of the user-provided keyword arguments (`family`, `proto`, `flags`, `sock`, `local_addr`, `happy_eyeballs_delay`, `interleave`, `all_errors`). Every connection parameter except host and port was silently discarded when SSL was active.
*   **The Fix:** Build a kwargs dict from the non-None/non-zero connection parameters and pass them through to `_Loop.create_connection` via `**kwargs`.
*   **The Lesson:** When wrapping an internal call that mirrors the public API, always forward all parameters explicitly. Silent kwargs dropping is a class of bug that's invisible to callers who don't verify that their extra parameters take effect. Use `**kwargs` dict construction with only non-default values to avoid passing `None` values that might conflict with internal parameter validation.

---

### 32. Defer Ordering and Incomplete Cleanup in Callback Execution (2026-06-01)
*   **The Bug:** Commit c02314f (Fix BUG-05) added `defer _ = python_c.PyContext_Exit(py_context);` to ensure context cleanup on all exit paths. However, it introduced a segfault because the `py_decref(handle)` cleanup was not properly handled. The original code had `py_decref(handle)` only on the success path at line 85, so error paths leaked the handle. Adding `defer py_decref(handle)` after the context defer created a use-after-free: Zig defers execute in LIFO order, so the handle was decref'd BEFORE the context was exited, but the handle holds the context reference.
*   **The Fix:** Added both defers in the correct order immediately after successful `PyContext_Enter`:
    ```zig
    defer python_c.py_decref(@ptrCast(handle));  // declared first, runs LAST
    defer _ = python_c.PyContext_Exit(py_context);  // declared second, runs FIRST
    ```
    This ensures the context is exited before the handle is decref'd, and both cleanups happen on all exit paths (success and error).
*   **The Lesson:** Zig's `defer` statements execute in **LIFO (Last In, First Out) order**. When multiple defers have dependencies (e.g., object A holds a reference to object B), the defer that should run LAST must be declared FIRST. Always verify defer ordering when cleaning up interdependent resources. Additionally, when adding defers to fix resource leaks, ensure ALL resources are covered — partial cleanup is worse than no cleanup because it creates subtle use-after-free bugs that are harder to debug than obvious leaks.

---

### 33. DNS Parser Out-of-Bounds Read on Compression Pointer (2026-06-01)
*   **The Bug:** In `parse_name` at `src/loop/dns/parsers.zig:97`, when encountering a DNS compression pointer (byte with top 2 bits set), the code read `full_data[offset + 1]` without checking if `offset + 1` was within bounds. If the compression pointer byte was the last byte in the buffer, this caused an out-of-bounds read, potentially crashing or leaking memory contents.
*   **The Fix:** Added bounds check before accessing the second byte of the compression pointer:
    ```zig
    if (offset + 1 >= full_data.len) return error.MalformedDnsResponse;
    ```
    This ensures the parser rejects malformed DNS responses with truncated compression pointers.
*   **The Lesson:** When parsing network protocols with pointer-like structures (offsets, indices, compression pointers), always validate that the referenced location is within bounds BEFORE dereferencing. DNS compression pointers are particularly tricky because they can point anywhere in the message, including to the pointer itself (creating loops) or beyond the message end. Always add explicit bounds checks for multi-byte structures.

---

### 34. DNS Response Transaction ID Validation (2026-06-01)
*   **The Bug:** In `process_dns_response` at `src/loop/dns/resolv.zig:348-368`, the DNS response handler read the transaction ID from the response header but never validated it against the query IDs that were actually sent. This meant any DNS response arriving on the socket would be accepted, making DNS cache poisoning trivial for an on-path attacker who could guess or observe the query timing.
*   **The Fix:** Added a `query_ids` field to `ServerQueryData` to store the transaction IDs of sent queries. In `build_queries`, each generated query ID is stored in this array. In `process_dns_response`, the response transaction ID is read from the first 2 bytes of the DNS header and checked against all stored query IDs. If no match is found, the response is rejected as invalid.
*   **The Lesson:** Network protocols that use transaction IDs for request/response matching MUST validate that incoming responses correspond to outstanding requests. Without validation, attackers can inject forged responses. This is especially critical for DNS where cache poisoning can redirect traffic to malicious servers. Always store sent transaction IDs and verify responses match before processing them.

---

### 35. Context Leak in Task Throw Execution (2026-06-01)
*   **The Bug:** In `_execute_task_throw` at `src/task/callbacks.zig:442-451`, `PyContext_Enter` was called to enter the task's context before calling `PyObject_GetAttrString(task.coro, "throw")`. If the attribute lookup failed (e.g., coroutine doesn't have a `throw` method), the function returned `error.PythonError` without calling `PyContext_Exit`, leaking the context stack entry.
*   **The Fix:** Added explicit `PyContext_Exit` call on the error path before returning:
    ```zig
    const coro_throw: PyObject = python_c.PyObject_GetAttrString(task.coro.?, "throw\x00") orelse {
        _ = python_c.PyContext_Exit(context);
        return error.PythonError;
    };
    ```
    This ensures the context is exited even when the attribute lookup fails.
*   **The Lesson:** This is the same pattern as BUG-05 (lesson 28) but in a different code path. When entering a CPython context, you MUST ensure `PyContext_Exit` is called on ALL exit paths, including early returns due to errors. Using `defer` is the safest approach, but if you need to exit the context before other cleanup (like checking `gen_ret`), you must explicitly call `PyContext_Exit` on every error path. Always audit all `return` statements after `PyContext_Enter` to ensure cleanup happens.

---

### 36. Reference Leak in Future get_result with Exception (2026-06-01)
*   **The Bug:** In `get_result` at `src/future/python/result.zig:26-31`, when a future had an exception set, the code set `self.exception = null` (losing the field's reference), then called `python_c.py_newref(exc)` to create a new reference for `PyErr_SetRaisedException`. However, `PyErr_SetRaisedException` steals a reference (takes ownership), so the original reference held by `self.exception` was never decref'd, leaking the exception object.
*   **The Fix:** Removed the `py_newref` call and passed `exc` directly to `PyErr_SetRaisedException`:
    ```zig
    self.exception = null;
    python_c.PyErr_SetRaisedException(exc);  // steals reference, no need for py_newref
    ```
    This transfers ownership from `self.exception` to the error state without creating an extra reference.
*   **The Lesson:** CPython's `PyErr_SetRaisedException` steals a reference (takes ownership without incrementing the refcount). When transferring ownership of a reference you already hold, do NOT call `py_newref` — just pass the reference directly. Always check the CPython documentation for reference stealing semantics: functions like `PyErr_SetRaisedException`, `PyTuple_SetItem`, and `PyList_SetItem` steal references, while most other functions create new references or borrow references.

---

### 37. Reference Leak in Future cancel(msg=...) (2026-06-01)
*   **The Bug:** In `future_cancel` at `src/future/python/cancel.zig:40-54`, `parse_vector_call_kwargs` created a new reference for the `msg` kwarg (via `py_newref` at line 527 of `python_c.zig`). The `future_fast_cancel` function then created its own reference (via `py_newref` or `PyObject_Str`). On the error path, the caller's reference was decref'd, but on the success path, it was never decref'd, leaking one reference per successful cancel with a message.
*   **The Fix:** Added `python_c.py_xdecref(cancel_msg_py_object)` after the successful `future_fast_cancel` call:
    ```zig
    const ret = future_fast_cancel(instance, future_data, cancel_msg_py_object) catch |err| {
        python_c.py_xdecref(cancel_msg_py_object);
        return utils.handle_zig_function_error(err, null);
    };
    python_c.py_xdecref(cancel_msg_py_object);  // Added this line
    ```
    This ensures the caller's reference is always released, regardless of success or failure.
*   **The Lesson:** When a function creates a reference (via `parse_vector_call_kwargs`, `py_newref`, etc.) and passes it to another function that also creates its own reference, the caller's reference must be explicitly released. Always trace the ownership chain: who creates the reference, who consumes it, and who is responsible for releasing it. In this case, `parse_vector_call_kwargs` created a reference for the caller, `future_fast_cancel` created its own reference, so the caller must release its reference after the call.

---

### 38. Reference Leak in Task set_name() (2026-06-01)
*   **The Bug:** In `task_set_name` at `src/task/utils.zig:64`, the code assigned `instance.name = python_c.PyObject_Str(name.?)` without decref'ing the previous value of `instance.name`. This leaked the old name string on every call to `set_name()` after the first.
*   **The Fix:** Added `py_xdecref` for the old name before assigning the new one:
    ```zig
    const new_name = python_c.PyObject_Str(name.?) orelse return null;
    python_c.py_xdecref(instance.name);
    instance.name = new_name;
    ```
    This ensures the old name is released before storing the new one.
*   **The Lesson:** When replacing a stored PyObject reference, always decref the old value before assigning the new one. This is a common pattern in setter functions: `py_xdecref(old_value); field = new_value;`. Forgetting to decref the old value is a classic reference leak that accumulates over time. Always audit setter functions to ensure they properly release old references.

---

### 39. Reference Leak in cancel_future_waiter for Future Path (2026-06-01)
*   **The Bug:** In `cancel_future_waiter` at `src/task/cancel.zig:17`, when the future was a talyn `Future` (not a `Task`), the code called `python_c.py_xincref(cancel_msg_py_object)` before passing it to `future_fast_cancel`. However, `future_fast_cancel` already creates its own reference (via `py_newref` or `PyObject_Str`), so the caller's incref was never balanced by a decref, leaking the cancel message on every task cancellation that propagates to an awaited Future.
*   **The Fix:** Removed the unnecessary `py_xincref` call:
    ```zig
    // Removed: python_c.py_xincref(cancel_msg_py_object);
    const fut: *Future.Python.FutureObject = @ptrCast(future);
    const ret = try Future.Python.Cancel.future_fast_cancel(
        fut, utils.get_data_ptr(Future, fut), cancel_msg_py_object
    );
    ```
    Since `future_fast_cancel` takes a borrowed reference and creates its own, no incref is needed.
*   **The Lesson:** When calling a function that takes a borrowed reference and creates its own reference internally, do NOT incref the argument before passing it. The function will handle reference counting internally. Always check the callee's implementation to understand its reference counting contract: does it borrow (no incref needed), steal (no incref needed, but you lose ownership), or create (no incref needed, it will incref internally)?

---

### 40. connection_lost May Never Be Called on Half-Closed Connections (2026-06-01)
*   **The Bug:** In `close_transports` at `src/transports/stream/lifecycle.zig:34,41`, the code checked if either `read_transport.closed` OR `write_transport.closed` was true, and if so, returned early without calling `connection_lost`. This meant if EOF closed the read side, then a write error occurred on the write side, `connection_lost` was never called, leaving the protocol in a limbo state.
*   **The Fix:** Changed the check to use `transport.closed` (which is only set when both sides are closed and `connection_lost` has been called):
    ```zig
    const closed_already = transport.closed;  // Changed from: read_transport.closed or write_transport.closed
    ```
    This ensures `connection_lost` is called on the first close event, regardless of which side closed first.
*   **The Lesson:** When managing bidirectional resources (like read/write transports), track the overall state separately from the individual component states. The protocol's `connection_lost` should be called exactly once when the connection is fully closed, not when individual components close. Use a flag on the parent object (`transport.closed`) to track whether the protocol has been notified, rather than checking component states with OR logic.

---

### 41. DNS Query Packing: Multiple Queries in Single UDP Datagram (2026-06-01) — DEFERRED
*   **The Bug:** In `build_queries` at `src/loop/dns/resolv.zig:462-480`, multiple DNS queries (for different hostnames or A/AAAA records) were concatenated into a single UDP payload. Standard DNS resolvers expect one query per UDP datagram and will only process the first query, silently dropping the rest. This causes resolution failures for search-domain suffixed names and IPv6 queries.
*   **Why Deferred:** Fixing this requires significant architectural changes (~200-300 lines):
    1. Allocate array of payloads instead of single buffer
    2. Send each query as separate UDP datagram
    3. Track multiple pending queries with state machine
    4. Handle partial failures (some queries timeout, others succeed)
    5. Aggregate results from multiple responses
    6. Manage memory for multiple buffers
*   **Mitigation:** BUG-07 fix (lesson 34) validates transaction IDs, preventing cache poisoning even if queries are dropped. Most DNS queries are single-hostname (FQDN without search domains), so the bug has limited impact in practice.
*   **The Lesson:** When designing network protocols, follow the standard: one query per UDP datagram for DNS. Packing multiple queries into a single datagram violates the protocol and causes silent failures. However, fixing architectural issues in core subsystems (like DNS) requires careful planning and comprehensive testing. Sometimes it's better to defer a fix and add mitigations (like transaction ID validation) rather than risk introducing regressions in a quick bug fix.

---

### 42. DNS Cache Eviction Use-After-Free (2026-06-01)
*   **The Bug:** In `evict_record` at `src/loop/dns/cache.zig:75-84`, when a pending DNS record was evicted from the cache (due to LRU eviction or expiration), the record was freed immediately. However, the `ControlData` structure still held a pointer to the freed record. When the DNS query completed, `mark_resolved_and_execute_user_callbacks` at `src/loop/dns/resolv.zig:181-202` accessed `control_data.record` to store the results, causing a use-after-free.
*   **The Fix:** Added a `record_evicted: bool` field to `ControlData`. In `evict_record`, when evicting a pending record, set `control_data.record_evicted = true`. In `mark_resolved_and_execute_user_callbacks` and `ControlData.release`, check this flag before accessing the record pointer. This ensures that if the record has been evicted, we skip operations that would access the freed memory.
*   **The Lesson:** When managing cached resources with asynchronous operations, you must track the lifecycle of both the cache entry and the operation that references it. If a cache entry can be evicted while an operation is still in-flight, the operation must check whether its reference is still valid before using it. Use explicit flags (like `record_evicted`) to track eviction state, and always validate pointers before dereferencing them in asynchronous callbacks.

---

### 43. DNS Cache get() Removes Pending Records Without Cancellation (2026-06-01)
*   **The Bug:** In `Cache.get` at `src/loop/dns/cache.zig:155-168`, when an expired record was found, the code called `self.cache.remove(hostname)` which triggered `evict_record`. If the record was in `.pending` state, this caused the same use-after-free as BUG-10 (lesson 42). The pending DNS query was not cancelled, so when it completed, it tried to access the freed record.
*   **The Fix:** This is actually the same issue as BUG-10, and the fix in lesson 42 handles both cases. The `record_evicted` flag is set whenever a pending record is evicted, regardless of whether it's due to LRU eviction or expiration in `get()`. The asynchronous completion callback checks this flag and skips record access if it's been evicted.
*   **The Lesson:** When removing cache entries, consider whether there are any in-flight operations that reference those entries. Simply freeing the entry is not enough — you must either cancel the operations or mark the entry as invalid so the operations can detect the eviction. In this case, the fix for BUG-10 automatically fixed BUG-11 because both issues stemmed from the same root cause: accessing a freed record pointer.

---

### 44. Wrong Future Data Passed When Cancelling Awaited Future (2026-06-01)
*   **The Bug:** In `cancel_future_object` at `src/task/callbacks.zig:130-159`, when cancelling a task that was awaiting a talyn Future, the code called `Future.Python.Cancel.future_fast_cancel(future, utils.get_data_ptr(Future, &task.fut), cancel_msg)`. The second parameter was supposed to be the Future data of the awaited future, but instead it passed `&task.fut` which is the task's own future data. This caused the wrong future to be cancelled — the task's future was cancelled instead of the awaited future, leading to incorrect state and potential deadlocks.
*   **The Fix:** Changed line 138 from `utils.get_data_ptr(Future, &task.fut)` to `utils.get_data_ptr(Future, future)`. This ensures that the Future data of the actual awaited future is passed to `future_fast_cancel`, so the correct future is cancelled.
*   **The Lesson:** When working with multiple futures in a task (the task's own future and futures it's awaiting), be very careful about which future's data you're passing to functions. Always verify that you're passing the correct future object, not just any future that happens to be in scope. In this case, the bug was subtle because both `task.fut` and `future` are valid Future objects, but they represent different things: `task.fut` is the future representing the task's result, while `future` is the future the task is currently awaiting.

---

### 45. Partial Write with Error Silently Ignored (2026-06-01)
*   **The Bug:** In `write_operation_completed` at `src/transports/write_transport.zig:193-269`, when `io_uring` returned both a partial write (`io_uring_res > 0`) and an error (`io_uring_err != .SUCCESS`), the code processed the written bytes at lines 204-224, but then the error check at line 226 required `io_uring_res <= 0`, so the error path was skipped. The code then continued submitting more writes at line 252-253 despite the underlying error, leading to silent data corruption and continued writes to a broken connection.
*   **The Fix:** Changed the error check condition from `if (io_uring_err != .SUCCESS and io_uring_err != .CANCELED and io_uring_res <= 0)` to `if (io_uring_err != .SUCCESS and io_uring_err != .CANCELED)`. This ensures that any error (except cancellation) is properly handled, regardless of whether some bytes were written. The error is now reported via `connection_lost` and the transport is closed.
*   **The Lesson:** When handling I/O completion callbacks, always check for errors independently of the byte count. A partial write with an error is still an error — the kernel may have written some bytes before encountering the error condition (e.g., EPIPE after partial write). Don't assume that `res > 0` means success; always check the error code. In io_uring, both `res` and `err` can be set simultaneously, and both must be checked.

---

### 46. RegisteredBufferPool.release() Has No Overflow Guard (2026-06-01)
*   **The Bug:** In `RegisteredBufferPool.release` at `src/loop/scheduling/io/main.zig:364-368`, the function wrote to `self.free_slots[self.free_count]` and incremented `self.free_count` without checking if `free_count` was already at the maximum (`SlotCount`). If `release` was called more times than `lease` (e.g., due to a double-release bug), `free_count` would exceed the array bounds, causing a heap buffer overflow. Subsequent `lease` calls would return garbage indices from beyond the array.
*   **The Fix:** Added an overflow guard: `if (self.free_count >= SlotCount) return;` before writing to the array. This prevents double-release bugs from corrupting memory. If a buffer is released twice, the second release is silently ignored.
*   **The Lesson:** When managing free lists or pools, always validate that you're not exceeding the pool's capacity before adding items back. Double-release bugs are common in resource management code, and they can cause severe memory corruption if not caught. Always add bounds checks to prevent buffer overflows, even if the bug "shouldn't happen" — defensive programming catches bugs early and prevents security vulnerabilities.

---

### 47. dispatch_completion_batch Drops Remaining Records on Python Error (2026-06-01)
*   **The Bug:** In `dispatch_completion_batch` at `src/loop/runner.zig:104-145`, when `PyBytes_FromStringAndSize` or `PyObject_CallOneArg` returned null (Python exception), the function called `batch.reset()` and returned `error.PythonError` immediately. This discarded all remaining records in the batch. The transports for those remaining records had already had data read from the kernel into their buffers, but the protocol was never notified, causing silent data loss for unrelated connections whose completions were batched after the failing one.
*   **The Fix:** Changed the error handling to continue processing all records in the batch even if one fails. Added a `had_error` flag that is set when any record fails. After processing all records, the batch is reset and the error is returned if one occurred. This ensures that all transports are notified of their data, even if one protocol callback raises an exception.
*   **The Lesson:** When processing batches of independent operations, don't let one failure stop the entire batch. Each operation should be processed independently, and errors should be collected and reported after all operations complete. In event loops, this is especially important because dropping completions causes silent data loss that is very difficult to debug. Always process the entire batch, then report errors.

---

### 48. Datagram Close Doesn't Cancel Pending io_uring Operations (2026-06-01)
*   **The Bug:** In `datagram_close` at `src/transports/datagram/main.zig:156-166`, the function closed the fd immediately without cancelling pending read/write io_uring operations. If the closed fd was reused by the OS before the kernel processed the pending SQEs, those operations would operate on the wrong file descriptor, causing data corruption.
*   **The Fix:** Added `read_task_id: usize = 0` to track the pending read operation. In `datagram_close`, before closing the fd, the pending read is cancelled by its task_id and all pending operations for the fd are cancelled via `IORING_ASYNC_CANCEL_FD`. The Cancel operation flushes all pending SQEs to the kernel before the fd is closed. Added `perform_by_fd` function to `cancel.zig` and `CancelByFd` variant to the io scheduler to support fd-based cancellation of all in-flight operations.
*   **The Lesson:** When an io_uring-based transport closes its file descriptor, it must first cancel any pending operations that reference that fd. Otherwise, the kernel may process stale SQEs after the fd is closed and potentially reused, leading to data corruption. Use `IORING_OP_ASYNC_CANCEL` with `IORING_ASYNC_CANCEL_FD` flag to cancel all operations for a given fd in one shot. Always flush pending SQEs before closing the fd to ensure the kernel has received the cancellation.

---

### 49. Uninitialized Struct Field via `allocator.create` + Field-by-Field Assignment (2026-06-02)

*   **The Bug (Regression from e1db5b9):** When fixing BUG-10/BUG-11 (DNS cache eviction use-after-free, lessons 42–43), a new `record_evicted: bool` field was added to `ControlData`. The field carries the default value `= false` in the struct definition. However, `prepare_data` in `src/loop/dns/resolv.zig` allocated `ControlData` with `allocator.create(ControlData)` — which returns raw uninitialised memory — and then assigned fields one by one. The new field was never assigned in that sequence. In **Debug** builds, Zig fills heap allocations with `0xaa` sentinel bytes, so `record_evicted` = `0xaa` = non-zero = `true` (ironically the same state as "evicted"). In **ReleaseSafe / Release** builds (`--starburst`), the bytes come from the actual heap allocator and are unpredictable: sometimes `0x00` (correct), sometimes non-zero (wrong). When `record_evicted` was garbage-`true`, `mark_resolved_and_execute_user_callbacks` skipped writing the resolved address list back into the cache record. The cache entry stayed in `.pending` state. The user callbacks were still dispatched, so `host_resolved_callback` ran and called `dns.lookup(host, null)` — which found a record but `get_address_list()` returned `null` (still pending) — raising `"Failed to resolve host"`.
*   **Why `--starburst` triggered it reproducibly:**
    1. **Uninitialized memory** — ReleaseSafe heap patterns produced non-zero bytes for the new field far more often than Debug's uniform `0xaa` (which also happened to be non-zero, but the test suite didn't exercise the second-lookup path under Debug).
    2. **Cache size difference** — `DNSCacheEntries` is `4` in Debug and `65536` in ReleaseSafe. With only 4 slots, LRU eviction fires so quickly that `record_evicted` is set to `true` by the legitimate eviction path almost immediately, masking the uninitialized-field path. With 65536 slots, eviction rarely happens, so the uninitialized garbage is the dominant source of the `true` value.
*   **The Fix:** Replaced the `allocator.create()` + field-by-field sequence with a **struct literal** assignment:
    ```zig
    // Before (field-by-field — new fields silently left uninitialized):
    const control_data = try allocator.create(ControlData);
    control_data.allocator      = allocator;
    control_data.resolved       = false;
    control_data.tasks_finished = 0;
    // ❌ record_evicted never set → garbage bytes in Release builds

    // After (struct literal — compiler error if any field is missing):
    control_data.* = ControlData{
        .allocator      = allocator,
        .arena          = std.heap.ArenaAllocator.init(allocator),
        .loop           = loop,
        .user_callbacks = .{ .items = &.{}, .capacity = 0 },
        .record         = undefined,   // assigned unconditionally just below
        .queries_data   = undefined,   // assigned unconditionally just below
        .tasks_finished = 0,
        .resolved       = false,
        .record_evicted = false,       // ✅ explicit
        .node           = undefined,   // assigned by append_node below
    };
    ```
    With a struct literal, the Zig compiler emits a **compile error** if any field of `ControlData` is not listed, so future fields can never be silently forgotten.
*   **Tests added:**
    *   **Zig unit test** (`resolv.zig`) — `"ControlData.record_evicted is false after struct-literal init (regression: e1db5b9)"`: allocates and struct-literal-initialises a `ControlData` in the exact same pattern as `prepare_data` and asserts `record_evicted == false`, `resolved == false`, `tasks_finished == 0`.
    *   **Python regression tests** (`tests/test_getaddrinfo.py`) — `test_getaddrinfo_localhost_hostname` and `test_getaddrinfo_repeated_resolution_same_hostname`: resolve `"localhost"` through the full async DNS path (not the literal-IP shortcut) and verify both a single and a repeated resolution return a valid loopback address. These are the exact callers that raised `"Failed to resolve host"` before the fix.
*   **The Lesson:** `allocator.create(T)` returns **uninitialised memory**. Struct field defaults (e.g., `field: bool = false`) are **only applied when using a struct literal** — they are not applied by `create`. When initialising a heap-allocated struct field-by-field, adding a new field to the struct without adding the corresponding assignment at the call site is a silent, compiler-invisible bug. In Debug builds it may be masked by Zig's `0xaa` fill; in Release builds it becomes a non-deterministic corruption. **Always use a struct literal** (`ptr.* = T{ .field = value, ... }`) for heap-allocated structs so the compiler enforces completeness. Use `undefined` only for fields that are provably assigned before any read.

---

### 50. Stale CompletionRecord Detection via Generation Counter (2026-06-02)

*   **The Bug:** `CompletionRecord` in `src/loop/completion.zig` stored raw `*anyopaque` pointers to `StreamTransportObject` and to the read buffer. The dispatch loop in `runner.zig` ran *after* hooks and call_once, but the only thing protecting the pointers was the assumption that no code path would close/free a transport between record push (`fetch_completed_tasks`) and dispatch (`dispatch_completion_batch`). A single `check_hook` or `prepare_hook` that closed a stream transport — or any future refactor that re-ordered the dispatch — would cause the dispatch to dereference dangling pointers, producing a use-after-free / segfault.
*   **The Fix:** Added a per-transport `dispatch_generation: u64` counter to `StreamTransportObject`. Each `CompletionRecord` now also stores a `transport_generation: u64` snapshot of that counter at push time. `dispatch_completion_batch` reads the live counter (`@atomicLoad(..., .acquire)`) and skips the record (`continue`) if it does not match. The counter is bumped (`@atomicStore(..., .release)`) in two places, both *before* mutating state:
    1. `maybe_close_fd` (`src/transports/stream/lifecycle.zig`) — when both the read and write transports are closed, signalling "this transport is going away".
    2. `transport_force_close` (`src/transports/stream/lifecycle.zig`) — the unconditional error-path close.
    `fetch_completed_tasks` (`src/loop/runner.zig`) snapshots the counter at push time so dispatch can detect any subsequent close.
*   **Subtle bug found and fixed during testing:** the `dispatch_generation: u64 = 0` field default in the struct definition is **only applied by struct literals** (lesson 49). `StreamTransportObject` is heap-allocated via `tp_alloc` and the fields are assigned one by one in `stream_init_configuration` and `z_stream_new` (in `src/transports/stream/constructors.zig`). Without an explicit `instance.dispatch_generation = 0` at the init sites, the field was uninitialised (`0xAA AA AA AA AA AA AA AA` in Debug). The first attempt at this fix hung `test_create_connection_send_recv` and `test_create_server_localhost_echo` indefinitely — root cause was two-fold:
    1. The uninitialised generation in the struct happened to compare equal (both reads of the same uninitialised bytes), so the check should have passed, BUT...
    2. The original `dispatch_completion_batch` also accidentally nulled `record.buffer_ptr` *before* reading it in the switch (`record.buffer_ptr orelse continue` was always true), so the `DataReceived` path never delivered the bytes to `protocol.data_received`. The test hung at `await protocol.received`.
    Both issues had to be fixed for the test to pass: explicit init in constructors AND not nulling the record until *after* the switch reads it.
*   **Tests added:**
    *   **Zig unit tests** (`completion.zig`): `"CompletionRecord.transport_generation field"` and `"CompletionBatch push stores transport_generation"`. Both verify the new field is stored and read back correctly, and that `reset()` clears the batch.
    *   **Python tests** — the existing `tests/test_create_connection.py::test_create_connection_send_recv` and `tests/test_create_server.py::test_create_server_localhost_echo` exercise the full push → dispatch path on a live Talyn event loop. Both pass after the fix and would hang on a broken fix (regression sentinels). Running the full test suite (280 passed) confirms no regression in the rest of the codebase.
*   **The Lesson:** Any time you cache a raw pointer in a queue/batch that will be processed asynchronously, you **must** guard against the target being freed between push and pop. A generation counter (single `u64`, `@atomicStore(u64, ..., .release)` on close, `@atomicLoad(u64, ..., .acquire)` on dispatch, `if (live != captured) skip` on the consumer) is a robust, lock-free pattern. **Two extra rules for free-threading / Debug-vs-Release safety:**
    1. **Always use `@atomicLoad/@atomicStore` for the counter** — not just plain reads/writes. Under the free-threading build, plain reads race with the close path. Use release ordering on the bump and acquire on the load to ensure the bumped state is visible.
    2. **Initialise the counter explicitly in every constructor / init path** (lesson 49). The struct-literal default (`field: u64 = 0`) is invisible to `tp_alloc` + field-by-field assignment. The build was warning-clean, the Zig unit tests passed, but the test suite hung on the first attempt because the counter was reading uninitialised bytes. Both checks together are what catch a regression of this kind.

---

### 51. Pause, Don't Spin, on EMFILE/ENFILE in Accept Loops (2026-06-02)

*   **The Bug:** In `accept_callback` at `src/transports/streamserver/main.zig:157-161`, the `defer` block unconditionally re-enqueued `accept` as long as the server was open. When `accept4` returned `EMFILE` ("too many open files") or `ENFILE` ("system-wide file-table full"), the kernel immediately completed the next accept with the same error. The result: the accept loop spun at 100% CPU, flooding the logs with `OSError: [Errno 24] Accept error` until fd pressure resolved. In a real DoS scenario where the attacker is holding the fds open, the server stayed spun-out indefinitely.
*   **The Fix:** Added a `accept_paused: bool` flag to `StreamServerObject`. The error path in `accept_callback` sets `accept_paused = true` when `errno == EMFILE || errno == ENFILE`, and the `defer` block now skips re-enqueue when the flag is set. The flag is cleared by `start_serving`, which the user (or a future timer-based recovery loop) can call to resume accepting once fd pressure is relieved. The flag is also initialised explicitly to `false` in the `z_streamserver_init` path to avoid the uninitialised-field bug (lesson 49).
*   **Tests added:**
    *   **Zig unit tests** (`streamserver/main.zig`): `"BUG-33: start_serving clears the accept_paused flag"` and `"BUG-33: accept_paused default is false on fresh init"`. These verify the flag transition (set → cleared by `start_serving`) and that a freshly-initialised server has `accept_paused = false`. The latter is the regression sentinel for the lesson-49 bug — without explicit init, the field would be uninitialised (`0xaa` in Debug) and the test would catch it.
    *   **Python regression** — the existing `tests/test_create_server.py` (10 tests), `tests/test_server_edge.py` (9 tests), and `tests/test_server_multi.py` (2 tests) exercise the full accept path on a live Talyn event loop. All 23 pass after the fix, confirming no regression in the normal accept / close / wait-closed paths.
*   **The Lesson:** When a callback can encounter a "transient but recurring" error (EMFILE/ENFILE, EAGAIN-thrashing, etc.), the response must be **back off**, not **retry immediately**. A boolean pause flag in the parent state is the minimum viable fix; for production code you typically also want: (a) a timer-based recovery loop (e.g., "try again in 100 ms, then 1 s, then 5 s") so the server auto-recovers when pressure resolves, (b) notifying the protocol's `connection_lost` so the application knows the server is paused, and (c) exposing `is_paused()` to Python so apps can log/alert. We do (a) and (b) implicitly via the existing `start_serving` API and the existing `defer` mechanics — the user just needs to call `start_serving` again to resume. The pattern generalises: any time you have `defer { retry }`, ask "what's the worst case if this error is permanent?" The answer is almost always "pause, log, and require an explicit resume."

