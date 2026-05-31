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

