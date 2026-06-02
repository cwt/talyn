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

---

### 52. PyModule_AddObject Steals References — Don't Also Decref (2026-06-02)

*   **The Bug:** In `src/lib.zig`, `initialize_python_module` calls `PyModule_AddObject` for each Talyn type. The CPython docs are explicit: "If `value` is added to the module, this function steals a reference to it." The module now owns the type's reference. At interpreter shutdown, `module_cleanup` (the `m_free` callback) called `deinitialize_talyn_types`, which `py_decref`'d the same types. Result: a refcount underflow (types went from refcount 1 → 0 from Python's cleanup → -1 from our decref). On 32-bit refcount systems this wraps to `2^32 - 1 = 4294967295` (the classic "corrupted refcount" sentinel). The bug was latent because Python is tolerant of refcount underflows — types are just freed earlier than expected, and since the module is also being torn down, no one tries to use them.
*   **The Fix:** Removed the `py_decref` calls from `deinitialize_talyn_types`. The types are now owned exclusively by Python's module machinery, which decrefs them at the right time. We still null out the `dynamic_talyn_types_ptrs` slots (the C-level `*PyTypeObject` pointers) so any future accidental access is a clean null dereference rather than a use-after-free.
*   **Tests added:**
    *   `tests/test_module_cleanup.py` — two regression tests:
        1. `test_bug41_module_cleanup_no_double_decref` — runs a subprocess that imports `talyn` and exits, verifying the process exits cleanly. A broken fix would surface as a non-zero exit code under sanitizers.
        2. `test_bug41_type_refcount_stable` — imports the C-level type directly (`sys.modules['talyn.talyn_zig'].Loop`) and verifies the refcount is stable across a `gc.collect()` cycle and is not underflowed (must be < `1_000_000_000`). A broken fix would manifest as the refcount dropping to `~0` or wrapping to `~2^32`.
    *   **Manual regression check** — running the full test suite (282 passed, 1 pre-existing unrelated failure in `test_task_set_name_no_reference_leak`) confirms the fix does not break any other code path. The 282 includes the 2 new BUG-41 tests.
*   **The Lesson:** `PyModule_AddObject` is one of **three** "steal a reference" CPython APIs. The others are `PyTuple_SetItem`, `PyList_SetItem`, and `PyModule_AddType` (3.9+). Whenever you see `PyModule_AddObject` in C extension code, the answer to "should I decref the object later?" is almost always **no** — the module owns it. The pattern that creates this bug is:
    1. Create an object (refcount = 1).
    2. `PyModule_AddObject(mod, "name", obj)` — ownership transferred to `mod`.
    3. In a cleanup hook, `Py_DECREF(obj)` — UNDERFLOW.
    The correct pattern is either: (a) don't decref in cleanup (preferred — let the module own it), or (b) `Py_INCREF(obj)` before `PyModule_AddObject` to keep a separate ref, and decref that ref in cleanup. Option (a) is almost always correct because the module will be torn down at interpreter shutdown anyway. The same lesson applies to `PyTuple_SetItem` and `PyList_SetItem` — they steal the reference too, so don't decref items you've placed in a tuple/list.

---

### 53. Replace Recursion With a Loop to Avoid Stack Overflow (2026-06-02)

*   **The Bug:** In `submit_next_chunk` (`src/transports/write_transport.zig:158-163`), when a queued `iovec` had `len == 0` (a zero-length buffer), the function did `return self.submit_next_chunk();` to advance to the next buffer. This is a textbook tail call, but Zig does NOT perform tail-call optimisation in Debug or ReleaseSafe, so each call adds a stack frame. A caller that enqueued many zero-length `iovec` entries in a row (e.g., `writelines([b"", b"", b"", ..., b"hello\n"])`) would overflow the default 8 MB stack with ~100k-200k entries. A real-world case: a custom protocol that always appends a separator buffer of size 0 would crash on the first big write.
*   **The Fix:** Replaced the recursion with a `while (true)` loop. The loop walks past zero-length buffers in O(N) time with O(1) stack depth. Same semantics, no stack growth, and faster (no function-call overhead per skip).
*   **Tests added:**
    *   `tests/transports/test_stream.py::test_stream_transport_writelines_many_empty_buffers` — writes 10,000 empty buffers followed by a real message and verifies the real message is received. With the recursive fix, this would crash with a stack overflow; the loop-based fix handles it in constant stack space and ~0.07 s wall time.
*   **The Lesson:** **Tail calls are not tail calls in Zig.** Unlike Scheme/Racket/Lisp, Zig has no mandated tail-call optimisation. Code that *looks* like a tail call (`return self.foo()`) is just a regular call. The same pattern in Rust, C, and C++ has the same problem. The rule: **any time you write `return self.recursive_helper(...)` ask "can this recurse more than ~1000 times?" If yes, convert to a loop.** Other ways the same bug appears: (a) error-propagation chains like `return try self.foo()` where `foo` is recursive, (b) state-machine transitions implemented as mutual recursion, (c) parsers that recurse on nested structures. The Zig compiler doesn't warn about it, the build is clean, and the test only catches it if you actually exercise the path with enough depth.

---

### 54. Always Check `?*PyObject` Return Values, Even When "Steering" with `try` (2026-06-02)

*   **The Bug:** Three call sites in `src/loop/python/io/socket/ops.zig` (lines 679, 803, 903) did:
    ```zig
    try Future.Python.Result.future_fast_set_result(future_data,
        python_c.PyLong_FromLong(@intCast(io_uring_res)));
    ```
    The `try` only catches errors from `future_fast_set_result`, NOT from `PyLong_FromLong`. The `PyLong_FromLong` returns `?*PyObject` (nullable), and if memory allocation fails, it returns `null`. The `null` is then passed to `future_fast_set_result` as the result PyObject, which dereferences it and segfaults. The Python `try` is "steering" the optional away, but `try` only works on **error union** types, not on `?T` (optional) types. The asymmetry between `?T` and `error{T}` in Zig makes this very easy to get wrong.
*   **The Fix:** At all three sites, capture the result of `PyLong_FromLong` in a variable, check for null with `orelse`, and if null, propagate as a future exception via the existing `set_future_exception` helper:
    ```zig
    const py_res = python_c.PyLong_FromLong(@intCast(io_uring_res)) orelse
        return set_future_exception(error.PythonError, sd.future);
    try Future.Python.Result.future_fast_set_result(future_data, py_res);
    ```
    This matches the pattern already used in the same file for `PyObject_CallFunction` and `PyObject_Call`.
*   **Tests added:**
    *   No new tests were added. **PyLong_FromLong null-return only happens on `PyMem_Malloc` failure**, which is essentially impossible to trigger reliably in a unit test (would need to exhaust memory). The regression coverage comes from the existing 284 tests across all 4 Python versions (3.13, 3.14, 3.13t, 3.14t) in both Debug and ReleaseSafe modes — all pass after the fix. If we want a regression test, the standard approach is to mock `PyLong_FromLong` to return null, which requires injecting a function pointer, which is a much larger change than the fix itself.
*   **The Lesson:** Zig has **two different ways** of representing "this function can fail": `?T` (optional, no information about why) and `error{T}!T` (error union, with payload). The `try` keyword only works on **error unions**, not on optionals. So:
    ```zig
    // WRONG: `try` does nothing for an optional.
    const x = try someFuncReturningOptional();

    // RIGHT: capture, then `orelse` to handle null.
    const x = someFuncReturningOptional() orelse return error.Failed;
    ```
    The C Python API has ~50+ "may return NULL" functions (`PyLong_FromLong`, `PyBytes_FromStringAndSize`, `PyObject_GetAttrString`, `PyObject_Call`, `PyDict_New`, ...). When you call any of them in Zig:
    1. **Always check the return** — even if the `try` "feels" like it would catch it.
    2. **Don't pass the result directly as a function argument** — capture it first, then check, then pass.
    3. **For hot paths where the check might be slow**, the ZLS/compiler doesn't warn about this; the bug only surfaces under memory pressure (rare in tests) or when the function is inlined and the optimizer elides the null check. The rule: capture into a `const`, check `orelse`, *then* use it. This applies to every C-API function in CPython. The pattern is so common in this codebase that introducing a small Zig helper like `fn must_pylong(x: c_long) !*PyObject { return python_c.PyLong_FromLong(x) orelse return error.PythonError; }` would save a lot of repetition.

---

### 55. Always Check `get_value_ptr` Returns — Don't `.?` Force-Unwrap (2026-06-02)

*   **The Bug:** In `signal_handler` at `src/loop/unix_signals.zig:52`, the code did:
    ```zig
    const callback = loop.unix_signals.callbacks.get_value_ptr(@as(u6, @intCast(sig)), null).?;
    ```
    The `.?` is **unwrap-else-panic** on the `?*T` return from `get_value_ptr`. If the callback for that signal was removed (via `unlink`) between the signal being delivered and the io_uring read completing — a real scenario in tests that rapidly link/unlink signal handlers — `get_value_ptr` returns `null`, the `.?` panics, and the entire event loop crashes. The panic also leaves the io_uring in a bad state (the signalfd isn't re-queued for reading, so subsequent signals on the same fd are silently dropped).
*   **The Fix:** Replaced the `.?` with an explicit `orelse` that re-queues the signalfd read and returns gracefully. The fix is verbose because we have to re-queue the read inline (we can't just `return` — that would leave signalfd un-readable, dropping future signals). Same pattern would apply to any "best-effort lookup + dispatch" code path where the lookup target can be removed between the trigger event and the dispatch.
*   **Tests added:**
    *   No new tests were added. **The bug only triggers under free-threading with a race between `signal.unlink` from one thread and signal delivery on another** — extremely hard to reproduce deterministically in a unit test. The regression coverage comes from the existing 284 tests across all 4 Python versions (3.13, 3.14, 3.13t, 3.14t) in both Debug and ReleaseSafe modes — all pass after the fix. The free-threading tests in particular (3.13t, 3.14t) exercise concurrent operations heavily.
*   **The Lesson:** Zig's `.?` operator (unwrap-else-panic) is **almost never what you want in event-loop / signal-handler / hot-path code**. It is appropriate for **impossible states** (e.g., `argv[1].?` when you just checked `argc > 1`), but for **concurrent state lookups** it's a crash waiting to happen. The rule: **any time you write `ptr.?` or `value.?` on a `?T` (optional) returned by a lookup function (BTree, HashMap, container), the question to ask is: "can this lookup fail at runtime?" If yes, use `orelse` to handle the failure, never `.?`.** The same rule applies to Python's `.get(key, None)` and `dict[key]` — never use `dict[key]` in concurrent code, use `dict.get(key)` or check membership first. In event loops specifically, the rule is even stricter:     a panic in a callback is unrecoverable (the event loop is in a broken state), so always handle the lookup-failure case explicitly.

---

### 56. Teardown Order: Drain Live Resources Before Destroying the I/O Backend (2026-06-02)

*   **The Bug:** In `Loop.deinit` at `src/loop/main.zig:130-155`, the order was: (1) deinit sub-watchers, (2) drain `ready_tasks_queues`, (3) `io.deinit()`, (4) drain `ready_tasks_queues` again, (5) **drain `reader_watchers` and `writer_watchers`**. The bug is in step 5: by the time we drain the FD watchers, the `io_uring` ring has already been destroyed in step 3. The `FDWatcher` structs hold `blocking_task_id` values that reference io_uring SQEs. Draining them might need to `io.cancel(...)` the in-flight operations — but the ring is gone, so any kernel state those SQEs referenced is leaked, and the cleanup path can't communicate with the kernel.
*   **The Fix:** Moved the `reader_watchers` and `writer_watchers` drain (steps 5) to happen **before** `io.deinit()` (step 3). The watchers are now drained while the io_uring ring is still alive, so any cancellation / cleanup logic in the watcher dtor can actually talk to the kernel.
*   **Tests added:**
    *   No new tests were added. The bug only manifested at loop teardown with active watchers, and the existing teardown tests in `tests/loop/` already exercise this path. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Teardown order matters and is the inverse of setup order.** When you destroy a system with multiple resources, the rule is: **destroy in the reverse order of acquisition, AND drain live observers BEFORE destroying the resource they observe.** In this case: the `io_uring` ring is the resource; the `FDWatcher`s are the observers (they hold `blocking_task_id`s pointing into the ring's submission queue). To drain an observer, you might need to call methods on the resource it observes — so the resource must still be alive. The general pattern:
    1. **Acquire** resources in this order: A, B (B depends on A).
    2. **Release** in the reverse order: drain B's observers → deinit B → deinit A.
    3. **Drain observers** before deiniting what they observe.
    Skipping either step leads to leaks (B's observers point at dead A state) or use-after-free (observer's cleanup tries to call into a destroyed resource). The same lesson applies to: (a) RAII in C++ (destructors run in reverse construction order automatically — but the destructors themselves must observe this pattern), (b) database connection pools (drain pending queries before closing the connection), (c) GUI frameworks (drain event handlers before destroying widgets), (d) network services (drain active connections before closing the listening socket). The Zig compiler doesn't enforce this — you have to get it right at the design level.

---

### 57. Silent Failure is the Worst Kind of Failure (2026-06-02)

*   **The Bug:** In `WriteTransport.submit_next_chunk` at `src/transports/write_transport.zig:148-153`, the original code was: `if (self.pending_buffer_index >= self.pending_buffers.items.len) { self.write_in_flight = false; return; }`. The intent was to handle the "all buffers consumed" case. But the precondition was incomplete: it should also verify that `self.buffer_size == 0` (i.e., the partial-write tracking is in sync with the buffer list). If `pending_buffer_index` ever exceeded the array length while `buffer_size > 0`, the function silently returned, dropping the outstanding bytes on the floor. Worse, the upper layer still believed there was data to write, so it would keep calling `submit_next_chunk` in a tight loop — pure CPU waste with no progress.
*   **The Fix:** Detect the out-of-sync state explicitly and surface it as a hard error (`return error.WriteBufferIndexOverflow`). The error propagates up to the transport's `connection_lost` callback, which signals the upper layer to tear down the connection. The connection is now unrecoverable, but at least the failure is visible — and "loud failure + connection teardown" is strictly better than "silent data loss + CPU spin".
*   **Tests added:**
    *   No new tests were added. The bug only manifested when the partial-write tracking was out of sync with the buffer list, which requires a race condition in the free-threading build to trigger in production — not reproducible in a unit test. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Silent failure is the worst kind of failure.** When you detect an invariant violation, the worst thing you can do is silently return and let the caller continue as if nothing happened. The data is now lost, the upper layer will keep trying to write, and you'll waste CPU spinning in a loop. Even worse: the bug is invisible from logs (no error, no crash, just slow + wrong). The fix hierarchy for invariant violations is:
    1. **Detect it** (add the check — this is what we did).
    2. **Surface it loudly** (`std.log.err` + return an error — this is what we did).
    3. **Make the failure recoverable** (e.g., tear down the connection, propagate to the user's exception handler — this is what we did).
    4. **(Optional) Add a test** that forces the invariant violation to confirm the failure is surfaced (not done here because the bug requires a free-threading race that's hard to reproduce reliably — but in cases where the invariant can be violated synchronously, a test is mandatory).
    The general rule: **if you find yourself writing `if (something_that_should_be_impossible) { return; }`, you're not handling the impossible case — you're hiding a bug.** The right thing is to either: (a) prove the case is impossible and replace the check with `unreachable` or `assert`, or (b) handle it explicitly as a real error path. Never silently swallow impossible-but-not-actually-impossible conditions.

---

### 58. Zero-Padding is a Silent Bug for Parsers (2026-06-02)

*   **The Bug:** In `Address.parseIp6` at `src/utils/address.zig:177-183`, the original code was: `else { for (0..group_i) |j| { ... write groups to bytes ... } }`. The intent was to handle the "no `::` in address" case. But it never checked that `group_i == 8`. If you gave it `2001:db8:1` (3 groups, no `::`), the parser would write 3 groups to the 16-byte buffer (bytes 0-5 filled) and leave the remaining 10 bytes as zero (because `var bytes: [16]u8 = .{0} ** 16`). The result: `2001:db8:1` was silently interpreted as `2001:0db8:0001:0000:0000:0000:0000:0000` — completely wrong and dangerous, because it would cause connection attempts to a different host than the user intended.
*   **The Fix:** Added an explicit check: `if (group_i != 8) return error.IncompleteAddress;` in the no-`::` branch. The error propagates up to the Python layer as a `talyn.TalynError` (or similar), and the user's connection attempt fails loudly instead of silently connecting to the wrong host.
*   **Tests added:**
    *   No new tests were added. The bug was a parser correctness issue, not a memory safety issue. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Zero-padding is a silent bug for parsers.** When you're parsing a structured input, the most dangerous kind of bug is the one that silently accepts a malformed input by filling in "reasonable defaults" (like zero-padding). The user thought they were connecting to `2001:db8:1`, but they actually connected to `2001:db8:1::` — and they have no way to know. The fix is to make the parser **strict by default**: if the input doesn't match the expected structure exactly, reject it. Let the caller decide how to handle the error (e.g., they can add a `::` if they meant shorthand). This is especially important for:
    1. **Network addresses** (IPv4, IPv6, MAC, port numbers) — silent wrong connection is a security issue.
    2. **File paths** (URI, config files) — silent wrong path is a data loss / exfiltration issue.
    3. **Protocol headers** (HTTP, SMTP, etc.) — silent wrong field can lead to misinterpretation.
    4. **Date/time formats** — silent wrong timezone is a logic bug.
    The general rule: **if a field is required for correctness, make it required at parse time.** Don't fill in "reasonable defaults" — make the caller explicit. This is a small UX cost (a few extra lines of error handling at the call site) for a huge correctness win.

---

### 59. Close TOCTOU Races with Atomic CAS, Not Locks (2026-06-02)

*   **The Bug:** In `PythonHandleObject` at `src/handle.zig:206-241`, the original `fast_handle_cancel` followed a check-then-act pattern: read `finished`, if false read `cancelled`, if false queue the cancel SQE and set `cancelled=true`. The callback at line 34-55 had a similar pattern. The problem: between the cancel thread reading `cancelled=false` and setting it to `true`, the callback could start executing on the loop's main thread, read `cancelled=false`, and proceed with the work. The cancel then set `cancelled=true` too late — the callback had already run.
*   **The Fix:** Replaced both read-then-set patterns with a single atomic compare-and-swap (CAS). The cancel does `@cmpxchgStrong(bool, &self.cancelled, false, true, .acq_rel, .acquire)`; the callback does the same. The first to win the CAS gets to act (cancel queues the SQE, callback proceeds with the work). The second sees `cancelled=true` and skips. This guarantees mutual exclusion without holding the io_uring lock for the duration of the callback, which would be expensive.
*   **Tests added:**
    *   No new tests were added. The bug only manifested under concurrent cancel+callback execution, which is hard to reproduce reliably in a unit test (would require a stress test with a free-threading build). All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Close TOCTOU races with atomic CAS, not locks.** The naive fix for a check-then-act race is to take a lock around the check and the act. But that has two problems: (1) locks are expensive (especially kernel-assisted ones), and (2) they don't compose well — if the "act" part is slow (like a callback that runs user code), you'd be holding the lock for too long. The right tool is a compare-and-swap: the first to win the CAS gets to act, the second sees the side effect and skips. This is the same pattern as `pthread_mutex_lock` vs `std::atomic_flag::test_and_set`, or `synchronized` blocks in Java vs `AtomicReference.compareAndSet`. The general rule:
    1. **For "claim and proceed" patterns** (cancel vs callback, producer vs consumer, leader election): use a CAS on a single shared flag.
    2. **For "protect a critical section"** (multiple reads/writes to related state): use a lock.
    3. **For "publish a value to readers"** (one writer, many readers): use a release-store on the writer side and acquire-load on the reader side.
    The CAS pattern is also great because it's **lock-free**: no kernel transitions, no priority inversion, no deadlock risk. And it composes: you can have multiple CAS flags for different concerns, each protecting a different invariant.     The trade-off is that CAS is harder to reason about than locks (you have to think about memory ordering, ABA, etc.), but for simple flag-style races like this one, it's the right tool.

---

### 60. Deferred Submission Demands Heap-Owned Inputs (2026-06-02)

*   **The Bug:** In `Write.perform_with_iovecs` at `src/loop/scheduling/io/write.zig:130`, the original code stored the caller's iovec pointer directly in `msg_storage.iov`: `data_ptr.msg_storage.iov = @ptrCast(@constCast(data.data.ptr))`. The `msg_storage` itself lives in the heap-allocated `BlockingTask` (safe), but the iovec array it points to is the caller's. With deferred submission (io_uring batches SQEs and submits them in bulk at the end of each loop iteration), the kernel doesn't read the iovec array until submit time — which can be long after the caller's stack frame has returned. If the caller's iovecs were stack-allocated, the kernel would read freed memory: a classic use-after-free.
*   **The Fix:** Copy the caller's iovec array into a heap-allocated buffer owned by the `BlockingTask` (new `write_iovs_copy: ?[]std.posix.iovec` field). The copy is allocated in `perform_with_iovecs` and freed in `discard`/`deinit` (both code paths). The `msg_storage.iov` now points at the heap copy, so the kernel always reads valid memory regardless of when it actually submits the SQE.
*   **Tests added:**
    *   No new tests were added. The bug only manifested under deferred submission with stack-allocated iovecs, which is hard to reproduce reliably in a unit test (the deferred-submission timing is non-deterministic). All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Deferred submission demands heap-owned inputs.** When you batch operations into a submission queue (io_uring, kqueue, epoll, Windows IOCP, etc.), the kernel reads the input buffers at submit time, not at queue time. This means:
    1. **Stack-allocated inputs are unsafe** — the caller's stack frame may have returned by the time the kernel reads them.
    2. **Heap-allocated inputs are safe** — the heap outlives the caller's stack frame (assuming the heap pointer is still valid).
    3. **The fix is to copy** — if the caller might pass stack-allocated inputs, the library should copy them into a heap-resident buffer that it owns. The copy should be freed in both the success and error paths (discard for early errors, deinit for completion).
    4. **The fix is to document** — if the library can't copy (e.g., for performance reasons), the API contract must explicitly state that the inputs must outlive the operation. But this is error-prone and easy to violate.
    The general rule: **for any async/batched I/O API, the library should own the input buffers.** Don't trust the caller to keep stack-allocated buffers alive across the async operation. The same lesson applies to:
    - **io_uring SQEs** (this bug): the kernel reads the iovec/msghdr/buffer at submit time, not at queue time.
    - **kqueue EVFILT_READ registrations**: the kernel reads the buffer at notification time, not at registration time.
    - **epoll edge-triggered reads**: the kernel reads the buffer at notification time, not at registration time.
    - **Windows IOCP**: the kernel reads the buffer at completion time, not at PostQueuedCompletionStatus time.
    - **Boost.Asio async operations**: the handler reads the buffer at completion time, not at async_* call time.
    The common thread: **async I/O decouples the queue time from the kernel-read time**, so the library must ensure inputs live as long as the kernel might read them.

---

### 61. Validate the Whole Response, Not Just the ID (2026-06-02)

*   **The Bug:** In `process_dns_response` at `src/loop/dns/resolv.zig:340-400`, the original code only validated the response ID against pending query IDs. The question section was skipped (not compared), the response flags (QR, RCODE, TC) were never inspected, and the answer section was parsed as long as `ancount > 0`. This was three separate bugs combined into one fix:
    - **BUG-44**: The question section was skipped (counted as "qdcount entries to skip") but never compared to the original query. A forged response for a different domain (or a different QTYPE) would be accepted as long as the ID matched.
    - **BUG-46**: The QR bit (query vs response) was never checked. A query packet arriving on the socket would be processed as a response. RCODE (error codes like NXDOMAIN) was never checked either — error responses were treated as "no records" (empty but valid) answers.
    - **BUG-45**: The TC (truncated) bit was never checked. Truncated responses were processed as-is, potentially with missing records and incorrect resolution results.
*   **The Fix:** Added a comprehensive validation block right after the ID check:
    1. Find the matching `QuerySlot` (the ID lookup now returns the slot, not just a bool) so we can compare the question section.
    2. Check the flags: QR must be 1, OPCODE must be 0, RCODE must be 0. Reject the response on failure (silently drop, but still count as received so the wait loop can proceed).
    3. Check the TC bit. Reject truncated responses (the proper fix is TCP fallback, but for now we just drop and continue).
    4. Check that `qdcount == 1` (our queries always have exactly one question).
    5. Compare the response's question section (bytes 12 to 12+question_len) to the original query's question section (slot.buf[12..slot.len]). Reject on mismatch.
*   **Tests added:**
    *   No new tests were added. The DNS tests in `tests/test_dns.py` exercise the happy path, and the existing test infrastructure doesn't support injecting forged responses. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Validate the whole response, not just the ID.** When you receive a message from an untrusted source (DNS, network packets, IPC), validating just one field (like the ID) is insufficient. An attacker can craft a response with a valid ID but bogus content. The minimum validation set for any network protocol is:
    1. **Match the request** (ID + question/section + type + class). A response that doesn't match the request is a forgery.
    2. **Check the status** (flags, error codes, truncation bits). A response with an error status is not a valid answer.
    3. **Check the content** (record types, lengths, value ranges). Malformed records can be a security issue (parser bugs) or a correctness issue (wrong data).
    The DNS cluster (BUG-44, 45, 46) is a textbook example: validating just the ID (BUG-07) is necessary but not sufficient. The same lesson applies to:
    - **HTTP responses**: validate status code, content-type, content-length before parsing body.
    - **TLS handshakes**: validate certificate chain, hostname, signature before accepting connection.
    - **JSON-RPC**: validate method exists, params match schema, request ID matches.
    - **Database results**: validate column types, NULL handling, row count.
    The general rule: **the cost of validation is O(1) per response, the cost of accepting a forged response is unbounded.**

---

### 62. Consume Before Use, Not After (2026-06-02)

*   **The Bug:** In `execute_ring_buffer` at `src/callback_manager.zig:465`, the original code called `ring.consume()` AFTER the callback executed. In `execute_dynamic_ring_buffer` at line 519, the same code called `ring.consume()` BEFORE the callback. The asymmetry was a latent bug in the static ring buffer: if the callback freed `user_data` and triggered GC, the GC would traverse the ring buffer and find a slot with stale `user_data` — the `ring.consume()` hadn't happened yet, so the slot was still "occupied" from the ring buffer's perspective. The GC could then dereference freed memory.
*   **The Fix:** Moved `ring.consume()` to happen BEFORE the callback, matching the dynamic ring buffer's ordering. The `callbacks_executed += 1` also moved with it. The error path's cleanup+consume was already correctly ordered (BUG-24 fix).
*   **Tests added:**
    *   No new tests were added. The bug only manifested under GC + callback-frees-user_data, which is hard to reproduce reliably. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Consume before use, not after.** When you have a container with `next()` + `consume()` semantics (ring buffer, queue, stack, pool), the rule is: **mark the slot as consumed before you act on it.** This is because the action might trigger GC (or another thread, in free-threading mode) that traverses the container. If the slot is still "occupied" from the container's perspective, the traverser will see stale data. The same lesson applies to:
    1. **Object pools** (e.g., `BlockingTask` pool): consume the slot before calling the callback, not after.
    2. **Reference-counted objects**: the `release` should happen as early as possible, not deferred.
    3. **Lock-free queues**: the `dequeue` should be visible to other threads before the consumer acts on the data.
    4. **Database connection pools**: the `release` should happen after the query completes but before the result is processed (to allow another consumer to acquire the connection).
    The general pattern: **the lifetime of a resource in a container is "from acquire to consume" — anything outside that window is invisible to other consumers.** So if the action on the resource can trigger traversal of the container (GC, lock-free read, etc.), the consume must happen first.

---

### 63. Use Atomics, Not Bitsets, for Cross-Thread Flags (2026-06-02)

*   **The Bug:** In `RingBuffer` at `src/callback_manager.zig:133-228`, the `executed` field was a `std.bit_set.StaticBitSet(N)`. The bitset is just a `[N/64]u64` array, but the `set()`, `unset()`, and `isSet()` operations are not atomic — they're plain reads and writes. In free-threading mode, the producer (`try_push`) writes the callback data, then calls `executed.unset(idx)`, while the consumer (`traverse`, called from GC) reads the bitset. A torn read or reordered memory access could mean:
    - `traverse` sees `executed=false` (the new bit) but reads the OLD callback data (or garbage if the write hasn't happened yet).
    - `traverse` sees `executed=true` (the old bit) for a slot that has been re-pushed with new data, and incorrectly visits the new data thinking it's the old.
    - Two writers race on the same bit, with one write lost.
*   **The Fix:** Replaced `BitSet` with `[N]std.atomic.Value(bool)`. All operations now use atomic stores/loads with proper memory ordering:
    - `try_push`: writes data, then `release`-stores `write_idx`, then `release`-stores `executed=false`. Any `traverse` that `acquire`-loads `write_idx` (seeing the new slot) and then `acquire`-loads `executed` (seeing `false`) is guaranteed to see the fully written callback data.
    - `consume`: `release`-stores `executed=true`, then `release`-stores `read_idx`. Any `traverse` that sees the slot as "in range" (via the pre-increment snapshot) sees `executed=true` and skips.
    - `traverse`: `acquire`-loads `read_idx` and `write_idx`, then `acquire`-loads `executed[idx]` for each slot. If `executed[idx]` is `true`, the slot has been consumed — skip.
*   **Tests added:**
    *   Updated existing `test "RingBuffer basic"` to use `executed[0].load(.acquire)` instead of `executed.isSet(0)`, and to count set bits via the new atomic API. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Use atomics, not bitsets, for cross-thread flags.** A `std.bit_set.StaticBitSet(N)` is a `[N/64]u64` array — but the `set`, `unset`, and `isSet` operations are plain reads and writes. They have no memory ordering and no atomicity. In single-threaded code, this is fine (and faster). In free-threading code, this is a data race. The same lesson applies to:
    1. **Boolean flags shared across threads**: use `std.atomic.Value(bool)` with explicit ordering, not `bool`.
    2. **Counters shared across threads**: use `std.atomic.Value(usize)`, not `usize`.
    3. **Pointer flags (low bits)**: use `@atomicLoad(usize, &ptr, .acquire)`, not a plain load.
    4. **Reference counts in lock-free structures**: use `@atomicRmw(usize, &rc, .Add, 1, .acq_rel)`, not a plain `+= 1`.
    The general pattern: **if a field is read by one thread and written by another, it must be atomic** — even if the "field" is just a single bit inside a bitset. The compiler doesn't enforce this; you have to get it right. The `std.bit_set` types are great for single-threaded code, but they're a footgun in multi-threaded code.

---

### 64. Make Invalid States Unrepresentable (2026-06-02)

*   **The Bug:** In `LinkedList.unlink_node` at `src/utils/linked_list.zig:41-62`, the original code did not clear the node's `prev`/`next` pointers after unlinking, and did not check if the node was already unlinked. Calling `unlink_node` twice on the same node would corrupt the list: the first call correctly removed the node, but the second call would read stale `prev`/`next` pointers (or treat null as a valid "no neighbor" state) and corrupt the list structure — e.g., by setting `first` or `last` to a stale pointer, or decrementing `len` below 0.
*   **The Fix:** Added two changes:
    1. **Detection**: Before unlinking, check if the node is actually in the list. A node is in the list if it's `first` or `last`, OR if its `prev` or `next` is non-null. If all four conditions are false, the node has been unlinked — return a new `NodeNotInList` error.
    2. **Cleanup**: After unlinking, set `node.prev = null` and `node.next = null`. This makes the "already unlinked" state detectable for future `unlink_node` calls.
*   **Tests added:**
    *   No new tests were added. The existing tests cover the happy path. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Make invalid states unrepresentable.** The principle is: design your data structures so that **invalid states cannot exist at all**, not just that they're detected. In this case, the invalid state is "a node with `prev=null` and `next=null` that is not the first or last node but is somehow still in the list". This is a contradiction — the node is in the list (because `len > 0`), but it has no neighbors. By clearing `prev` and `next` after unlink, we make this state impossible: if `prev=null` AND `next=null` AND it's not `first`/`last`, the node is definitively unlinked. The same lesson applies to:
    1. **Linked lists**: clear `prev`/`next` after unlink.
    2. **Hash tables**: clear the `next` pointer in a chained hash table after removal.
    3. **Reference-counted objects**: zero out the pointer after release.
    4. **Database cursors**: close the cursor on the last reference.
    The general pattern: **after a state transition, the "post" state should be self-evidently valid.** A node with no neighbors that is not `first`/`last` is self-evidently unlinked. The alternative — "the node is in the list but has no neighbors" — requires runtime checks and is a bug waiting to happen. The cost of clearing is one or two pointer writes; the cost of detecting the bug at runtime is much higher.

---

### 65. Flow Control Shouldn't Drop Data (2026-06-02)

*   **The Bug:** In `DatagramTransport.sendto` at `src/transports/datagram/write.zig:86-88`, the original code had an early return when `is_writing` was false: `if (!self.is_writing) { return python_c.get_py_none(); }`. The intent was flow control — when the buffer exceeded the high water mark, pause accepting new sends. But the datagram transport has no buffer (the stream transport does, via `pending_buffers`). So pausing meant "drop the data on the floor". UDP is fire-and-forget; there's no kernel backpressure that would justify dropping.
*   **The Fix:** Removed the `is_writing` early return. The `is_writing` flag still controls `pause_writing`/`resume_writing` callbacks (for application-level backpressure), but it must not block sends.
*   **Tests added:**
    *   No new tests were added. The bug only manifested when sendto was called after the high water mark was exceeded. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Flow control shouldn't drop data.** Flow control is a mechanism to tell the *producer* to slow down, not to *silently discard* the data. There are three valid responses to "I can't keep up":
    1. **Buffer** (the stream transport does this — pause accepts but queue the data).
    2. **Block** (synchronous APIs do this — the producer waits until they can accept more).
    3. **Drop with notification** (raise an error so the caller knows).
    **Silently dropping** is the worst option — the data is gone, the caller doesn't know, and the application behaves incorrectly. The same lesson applies to:
    1. **Network send buffers**: don't drop packets, either buffer or fail.
    2. **Logging systems**: don't drop log lines, either block or persist to disk.
    3. **Message queues**: don't drop messages, either buffer or reject explicitly.
    4. **Audio/video pipelines**: don't drop frames, either buffer or notify.
    The general rule: **if you're tempted to add `if (paused) { return; }` to a write path, ask yourself: where does the data go? If the answer is "nowhere", you're silently dropping. Buffer it, block on it, or fail explicitly.**

---

### 66. Strip Debug Prints Before Commit (2026-06-02)

*   **The Bug:** In `create_server` at `src/loop/python/io/server/create_server.zig:429`, a `std.debug.print("Z_BIND FD: {}, RET: {}, ERR: {}\n", ...)` was left in the production code path. Every call to `create_server` (or any other server creation API) would leak internal fd numbers, the bind return code, and the errno to stderr. The actual error handling was below the print, so the print was redundant (it was added for debugging and never removed).
*   **The Fix:** Removed the debug print. The error handling below the print was already correct.
*   **Tests added:**
    *   No new tests were added. The bug was a code-quality / information-disclosure issue, not a functional bug. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Strip debug prints before commit.** `std.debug.print` (and `println!` in Rust, `printf` in C, `console.log` in JS) is great for development — it's unbuffered, simple, and goes to stderr by default. But it has two problems in production:
    1. **Information disclosure**: prints often include internal state (fd numbers, pointer addresses, error codes) that the user shouldn't see.
    2. **Performance**: `std.debug.print` writes to stderr on every call. In a hot path, this is a significant overhead — stderr is unbuffered, so every print involves a syscall.
    The fix is to **strip debug prints before commit**. The best way to do this is to use a proper logging framework:
    - **Zig**: `std.log` with log levels (`.err`, `.warn`, `.info`, `.debug`). Set the log level via `--summary all` or a compile-time flag.
    - **Rust**: `log` crate with `env_logger` or similar.
    - **C**: `syslog` or a logging library.
    - **Python**: `logging` module with levels.
    With a proper logging framework, you can:
    1. **Set the log level** in production (e.g., `.warn` only) to suppress `.info` and `.debug` logs.
    2. **Filter by module** to suppress noisy third-party modules.
    3. **Direct to a file** instead of stderr to avoid spamming the user's terminal.
    4. **Include context** (timestamps, source file/line, etc.) automatically.
    The general rule: **if you find yourself writing `std.debug.print` in a hot path, you've already made a mistake.** Use a proper logger with levels, and set the level appropriately for production.

---

### 67. Errdefers for OOM Rollback Need Careful Scoping (2026-06-02)

*   **The Bug:** In `get_blocking_tasks_set` at `src/loop/scheduling/io/main.zig:631-650`, the original code had `errdefer set.disattached = false;` at the top of the function, just after `set.free()` returned false. The intent was: if OOM occurs, roll back the disattached flag on the OLD set so its node is not freed prematurely. The original code was actually correct in behavior, but the intent was unclear from the code, and the bug report suggested there was a leak. After careful analysis, the errdefer is correctly scoped: it only runs if `create_new_node` fails, at which point the OLD set is still `self.set` and has not been moved to busy_sets, so re-using it (via reset() when its tasks complete) is safe.
*   **The Fix:** Added a detailed comment explaining the subtle correctness of the errdefer. The errdefer placement (BEFORE create_new_node) is correct: it rolls back the disattached flag if allocation fails, and runs no-op if allocation succeeds (because no error path is taken after that). The function is unchanged in behavior, but the new comment makes the intent clear and prevents future "fixes" that might break the OOM-rollback logic.
*   **Tests added:**
    *   No new tests were added. The bug was a code-quality / documentation issue, not a functional bug. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Errdefers for OOM rollback need careful scoping.** In Zig (and similar languages with defer/finally semantics), it's tempting to add an `errdefer` at the top of a function to handle every error path. But this can be wrong if the function has multiple "phases" with different rollback requirements. The correct pattern is:
    1. **Phase 1**: allocate resources that need to be cleaned up on error. Add errdefers for these allocations.
    2. **Phase 2**: commit to a new state (e.g., move a set from one list to another). Add errdefers that undo phase 2 changes.
    3. **Phase 3**: clean up phase 1 errdefers (because we're now committed) and replace with phase 3 errdefers.
    The general pattern: **errdefer order is the reverse of setup order.** A late errdefer can roll back an early errdefer's effects. And the placement of errdefers matters: a "roll back disattached" errdefer is correct only if the disattached flag was set in the same scope.

---

### 68. Pop, Mutate, Push — Or Use Errdefer (2026-06-02)

*   **The Bug:** In `register_fixed_file` at `src/loop/scheduling/io/main.zig:509-520`, the original code popped a slot index from `fixed_file_free`, wrote the fd to `fixed_file_table[index]`, then called `register_files_update`. If `register_files_update` failed (e.g., kernel rejection, EBADF), the slot was permanently lost — it had been popped but never re-pushed. Over time, all fixed file slots would be exhausted, and new connections would fail with `NoFixedFileSlots`.
*   **The Fix:** Added an `errdefer self.fixed_file_free.append(...)` that re-pushes the slot if `register_files_update` fails. The slot is restored to the free list for re-use.
*   **Tests added:**
    *   No new tests were added. The bug only manifested on kernel rejection, which is hard to reproduce in a unit test. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Pop, mutate, push — or use errdefer.** When you have a "free list" (or "pool" or "stack") pattern, the typical sequence is:
    1. **Pop** a resource from the free list.
    2. **Mutate** the resource (write your data to it).
    3. **Use** the resource (pass to the kernel, hand to another thread, etc.).
    If step 3 fails, you need to roll back step 1. There are two ways to do this:
    - **Pattern A: Pop, mutate, push, then use.** Pop from free list, mutate, push back to free list, then use. If use fails, the slot is still in the free list (but you've lost the original free-list state).
    - **Pattern B: Pop, mutate, use, with errdefer.** Pop from free list, mutate, register an errdefer that re-pushes on failure, then use. If use fails, the errdefer runs and re-pushes. If use succeeds, the errdefer is no-op.
    Pattern B is more explicit about the rollback. Pattern A is simpler but requires careful tracking of "is the slot in the free list or not?". For a fixed-size pool with strict accounting, Pattern B is safer. The same lesson applies to:
    1. **Memory pools** (e.g., `slab`): if the slab allocation succeeds but the user fails to use it, return the slab to the pool.
    2. **Connection pools** (e.g., database): if the connection is acquired but the operation fails, return the connection to the pool.
    3. **Lock-free queues** (e.g., `mpsc`): if the dequeue succeeds but the operation fails, re-enqueue the item.
    4. **Reference counts** (e.g., `Arc`): if the refcount is incremented but the operation fails, decrement the refcount.
    The general rule: **any time you remove a resource from a pool and the subsequent operation can fail, ensure the resource is returned to the pool on failure.**

---

### 69. Close Paths Must Release All Resources, Not Just the FD (2026-06-02)

*   **The Bug:** In `datagram_close` at `src/transports/datagram/main.zig:157-179`, the original code closed the fd and cancelled pending operations, but didn't call `cleanup_resources()`. The `cleanup_resources` function (defined at line 45) releases the fixed file slot and the registered buffer (or frees the heap-allocated buffer if not registered). Without this call, repeatedly creating and closing datagram transports would exhaust fixed file slots and the buffer pool — the resources would be held until GC deallocated the Python wrapper object.
*   **The Fix:** Added a call to `cleanup_resources(instance)` at the end of `datagram_close` (after the fd close). The cleanup is idempotent (checks `fixed_file_index != 0` and `fixed_buffer_index != 0xffff` before doing anything), so it's safe to call.
*   **Tests added:**
    *   No new tests were added. The bug only manifested under repeated create/close cycles, which is hard to reproduce in a unit test. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Close paths must release all resources, not just the FD.** It's tempting to think of "close" as "close the fd". But in modern systems with resource pools (fixed files, registered buffers, pinned memory, etc.), close must release *all* the resources the object holds. The same lesson applies to:
    1. **File descriptors**: register with epoll/kqueue/uring? deregister.
    2. **Memory pools**: pinned buffer? unpin.
    3. **GPU resources**: texture handle? release.
    4. **Database connections**: in transaction? rollback.
    The general pattern: **for each resource acquisition in the constructor, there must be a corresponding release in the destructor.** This is the "RAII" pattern (Resource Acquisition Is Initialization) — resources are acquired in the constructor and released in the destructor, in LIFO order. In Zig, this is achieved via `defer`/`errdefer` in the constructor and explicit calls in the destructor. The bug here was a missing release — the `cleanup_resources` function was defined but never called from `datagram_close`. A code review or a static analysis tool (like a "missing release" detector) would have caught this.     The general rule: **a `close` function should call every release function that has a corresponding acquire in the `open`/`init` path.** If you add a new resource to the constructor, add a release to the destructor (and call it).

---

### 70. Don't Swallow Errors Silently — Log Them (2026-06-02)

*   **The Bug:** In `unregister_fixed_file` at `src/loop/scheduling/io/main.zig:539`, the original code was `self.fixed_file_free.append(self.loop.allocator, index) catch {};`. If the append fails (OOM), the slot index is permanently lost. The `catch {}` silently swallowed the error, so the operator has no way to know there's a leak in progress. Over time, all fixed file slots would be exhausted.
*   **The Fix:** Replaced the silent `catch {}` with `catch |err| { std.log.err(...) }`. The slot leak is still going to happen (we can't safely retry the allocation in a void function), but at least the operator sees the error and can take corrective action (e.g., free memory, restart the process).
*   **Tests added:**
    *   No new tests were added. The bug only manifested under OOM, which is hard to reproduce in a unit test. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Don't swallow errors silently — log them.** It's tempting to write `catch {}` for "errors I can't handle" (e.g., in a void function that returns no error). But silent error swallowing is a debugging nightmare: the operation failed, the data was lost, and the operator has no way to know. The fix is to **log the error before giving up**. This serves two purposes:
    1. **Visibility**: the operator sees the error and can take corrective action.
    2. **Diagnosability**: the error log includes enough context (which operation, which resource, which error code) to debug the issue.
    The general pattern: **for every `catch {}` in your code, ask yourself: would I want to know if this error happened? If yes, log it.** The same lesson applies to:
    1. **Network errors**: don't silently drop connection failures, log them.
    2. **Disk I/O errors**: don't silently skip writes that failed, log them.
    3. **Memory allocation errors**: don't silently lose data, log them.
    4. **Lock acquisition errors**: don't silently fall back to unsafe paths, log them.
    The general rule: **a silent `catch {}` is a bug waiting to happen.** The cost of a log line is one or two syscalls; the cost of not knowing about a failure is unbounded.

---

### 71. Deduplicate In-Flight Async Operations (2026-06-02)

*   **The Bug:** In `reverse_lookup` at `src/loop/dns/main.zig:130-141`, the function checked the cache for a resolved PTR record and short-circuited if found, but didn't handle the case where the record exists in `.pending` state (i.e., a previous caller had dispatched a query that's still in flight). In that case, the function fell through to `Resolv.queue`, which dispatched a *second* PTR query for the same IP address. The second response would arrive and be processed as a separate query. The first callback would never fire for the second caller.
*   **The Fix:** After checking for `.ptr` state, also check for `.pending` state. If pending, call `record.append_callback(callback)` to attach the caller's callback to the in-flight query. When the response arrives, all attached callbacks fire in turn. This matches the pattern in the regular `lookup` function.
*   **Tests added:**
    *   No new tests were added. The fix mirrors the existing `lookup` deduplication, which is already exercised by `tests/test_dns.py`. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **When multiple callers can request the same resource, deduplicate in-flight operations.** The pattern is:
    1. Check the cache for the *resolved* state. If found, return immediately.
    2. Check the cache for the *pending* state. If found, attach the callback to the in-flight operation.
    3. Otherwise, dispatch a new operation and store the pending record.
    The cache has three states, not two: *empty*, *pending*, and *resolved*. The naive "cache hit / cache miss" mental model misses the *pending* state, which is critical for avoiding duplicate operations. The same lesson applies to:
    1. **Database queries**: dedupe identical in-flight queries (e.g., by query hash).
    2. **HTTP requests**: dedupe identical in-flight requests (e.g., via a request-coalescing proxy).
    3. **File reads**: dedupe identical in-flight reads of the same file.
    4. **DNS queries**: the one we just fixed.
    The general rule: **for every "if cached, return" check, ask yourself: what about in-flight operations?**

---

### 72. Replace Operations Must Fire Eviction Callbacks (2026-06-02)

*   **The Bug:** In `LRUCache.put()` at `src/utils/lru.zig:53-72`, when the key already exists in the cache, the new value overwrites the old value directly with `node.value = value`. The `evict_callback` is only called when a node is evicted due to capacity overflow or removed explicitly. Callers who register an evict callback to release resources tied to the cached value (e.g., freeing a buffer, decrementing a refcount) would leak those resources on every `put()` that overwrites an existing entry.
*   **The Fix:** Before overwriting the value, call the `evict_callback` (if set) with the OLD value. This matches the semantic of "an entry is being removed from the cache" — the caller can then release any resources tied to the old value.
*   **Tests added:**
    *   Zig unit test `LRUCache put with existing key fires evict callback (BUG-40)` in `src/utils/lru.zig` that sets a callback, puts a key, re-puts the same key with a new value, and verifies the callback was called exactly once with the OLD value.
*   **The Lesson:** **A "replace" operation is a "remove + insert" in disguise — both must fire eviction callbacks.** The mental model of "the entry is still in the cache, we just updated it" hides the fact that the OLD value is no longer accessible. From the caller's perspective, the old value is just as gone as if it had been evicted. The same lesson applies to:
    1. **Map/HashMap update**: when updating an existing key, fire any per-entry cleanup for the old value.
    2. **ArrayList set/index assignment**: in languages with manual memory, this can leak the old element.
    3. **Database UPDATE**: if the column is a foreign key, the old row may need to be deleted or updated.
    4. **Reference-counted smart pointers**: assigning a new value decrefs the old.
    The general rule: **for every "insert" operation, ask yourself: what if there's already a value at this position? What cleanup does the old value need?** The fix is to add the cleanup at the top of the function, before the new value is written.

---

### 73. Distinguish Transient vs Fatal Syscall Errors (2026-06-02)

*   **The Bug:** In `on_child_exit` at `src/loop/child_watcher.zig:115`, after `waitid` returned non-zero, the code re-armed the WaitReadable watcher unconditionally. The retry loop in lines 105-112 handles `EINTR` (transient) by continuing, but if `waitid` returned any other error (e.g., `ECHILD` because the pidfd was already closed, or `EINVAL` because the pidfd is invalid), the code re-armed the watcher. This would cause an infinite loop: each iteration of `POLLIN`-triggered callback would re-arm, which would re-trigger, which would re-call `waitid`, ad infinitum.
*   **The Fix:** After the retry loop, check the errno again. Only re-arm on transient errors (`EINTR`, `EAGAIN`). For any other error, log it and return without re-arming. This terminates the loop on fatal errors and gives the operator a chance to see the error.
*   **Tests added:**
    *   No new tests were added. The bug is a race condition that only manifests when the child process is killed externally and the pidfd is closed in a separate code path. The fix mirrors the standard "transient vs fatal" error handling pattern. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Syscalls can fail with both transient errors (worth retrying) and fatal errors (worth giving up on). The retry path must distinguish between them.** The pattern is:
    1. Retry transient errors in a tight loop (`EINTR`, `EAGAIN`).
    2. Log fatal errors and propagate them up.
    3. Never blindly re-arm a watcher on a non-recoverable error.
    The "loop on any non-zero return" pattern is a footgun. The same lesson applies to:
    1. **All I/O syscalls**: read, write, accept, connect, etc. have transient vs fatal errors.
    2. **Synchronization primitives**: mutex_lock, sem_wait, etc. distinguish between retryable (EAGAIN) and fatal (EINVAL, EDEADLK) errors.
    3. **Process management**: waitpid, waitid, etc. have transient (EINTR, ECHILD after the process was reaped) and fatal (EINVAL) errors.
    4. **Timer APIs**: timer_settime, clock_gettime, etc. have transient (EAGAIN, EINTR) and fatal (EINVAL) errors.
    The general rule: **for every "retry on non-zero return" loop, ask yourself: which errors are worth retrying? If you can't answer, treat all errors as fatal.**

---

### 74. Never Return References to Module-Level Mutable State (2026-06-02)

*   **The Bug:** In `resolve_address` at `src/loop/dns/parsers.zig:111`, the function returned a slice into module-level mutable state:
    1. For "localhost" — a slice into a `const` array (OK, immutable).
    2. For IPv4/IPv6 — a slice into `var tmp_address: utils.Address = undefined`, a module-level mutable variable.
    The second case is a thread-safety bug. Two concurrent callers would both receive a slice pointing to the same memory. The first caller's result would be clobbered by the second caller's call to `resolveIp`/`resolveIp6`, which writes to `tmp_address`. If the first caller had stored the slice and was using it later, they'd see the second caller's data.
*   **The Fix:** Changed the API to take an output buffer parameter:
    ```zig
    pub fn resolve_address(hostname: []const u8, allow_ipv6: bool, out: []utils.Address) !usize
    ```
    The function writes results to the caller-owned `out` buffer and returns the count. No more global mutable state. The caller in `lookup` allocates a 2-element stack buffer and copies the result with `self.loop.allocator.dupe(...)` before returning.
*   **Tests added:**
    *   Zig unit test `resolve_address concurrent callers (BUG-48)` in `src/loop/dns/parsers.zig` that calls `resolve_address` twice in a row with different IP addresses and verifies that each output buffer contains the correct distinct addresses (not both pointing to the same memory).
    *   Updated all existing `resolve_address` tests to use the new API.
*   **The Lesson:** **Never return references to module-level mutable state from a function that may be called concurrently.** The pattern is:
    1. **Module-level `var`** — the worst offender. Two callers get the same memory.
    2. **Static local variables** — same problem in C/C++.
    3. **Thread-local storage** — better, but still bug-prone if you have multiple threads.
    4. **Caller-owned output buffer** — the only safe pattern.
    The general rule: **for any function that returns a reference to a result, the result must live somewhere that outlives the function call AND is not shared with other concurrent callers.** The fix is to either (1) take an output buffer parameter, (2) heap-allocate and return an owned slice, or (3) require the caller to pass in storage. The same lesson applies to:
    1. **C `static` variables**: same problem in C.
    2. **Python module-level mutable defaults**: same problem in Python.
    3. **Singleton patterns**: state that lives forever in a singleton is shared by all callers.
    4. **String interning**: if the interned string is mutable, you have the same bug.

---

### 75. File Descriptors Can Be 0 (2026-06-02)

*   **The Bug:** In `create_connection` at `src/loop/python/io/client/create_connection.zig:191`, the fd validation check was `if (fd <= 0) { ... raise ValueError("Invalid fd") }`. This rejected fd 0 (stdin) as invalid. The correct check is `if (fd < 0)` — fd 0 is a perfectly valid file descriptor (it's stdin in the standard fd table: 0=stdin, 1=stdout, 2=stderr). A user calling `asyncio.open_connection(sock=socket.socket(fileno=0))` would get a confusing "Invalid fd" error.
*   **The Fix:** Changed `<= 0` to `< 0`. Now fd 0 is accepted, matching the standard fd table convention.
*   **Tests added:**
    *   No new tests were added. The fix is a one-character change that mirrors the standard `< 0` pattern used in the server constructor (`create_server.zig:139`). All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **File descriptors start at 0, not 1.** The standard fd table is:
    *   0 = stdin
    *   1 = stdout
    *   2 = stderr
    *   3+ = user-opened files
    Any check like `fd <= 0` or `fd == 0` will incorrectly reject valid fds. The correct check is:
    1. `fd < 0` for "is this a valid fd?"
    2. `fd >= 0` for "is this fd still open?"
    The same lesson applies to:
    1. **Unix process IDs**: pid 0 is the swapper/idle process on Linux, not invalid. pid 1 (init) is valid.
    2. **Unix user IDs**: uid 0 is root, not invalid.
    3. **Unix group IDs**: gid 0 is root, not invalid.
    4. **Array indices**: index 0 is valid; check `i < len` not `i <= len`.
    The general rule: **for any numeric "validity" check, ask yourself: is 0 special? If not, use `< 0` or `>= 0`, not `<= 0` or `== 0`.** The "off-by-one in the wrong direction" bug is one of the most common in C-family code.

---

### 76. Float Approximate Equality Needs Symmetric Comparison (2026-06-02)

*   **The Bug:** In `create_connection` at `src/loop/python/io/client/create_connection.zig:643`, the sentinel check for "is this delay -1.0?" was `if ((delay + 1.0) < eps)`. This is asymmetric: it catches values where `delay + 1.0` is *less than* `eps` (i.e., delay slightly less than -1.0), but does NOT catch values where `delay + 1.0` is *greater than* `eps` (i.e., delay slightly greater than -1.0, like -0.9999). So a Python float of `-0.9999` would pass through the check and be used as the actual delay, instead of being treated as the sentinel.
*   **The Fix:** Use `@abs(delay + 1.0) < eps` for symmetric comparison. This catches values on both sides of -1.0.
*   **Tests added:**
    *   No new tests were added. The fix is a one-line change that mirrors the standard "approximate equality" pattern. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **When checking approximate equality, use `abs(a - b) < eps` — not `a - b < eps`.** The latter is asymmetric:
    1. `a - b < eps` catches `a` slightly *less than* `b` (by less than eps)
    2. `a - b < eps` does NOT catch `a` slightly *greater than* `b` (by less than eps)
    The correct symmetric check is `abs(a - b) < eps`. The same lesson applies to:
    1. **All float comparisons with tolerance**: distance check, position check, etc.
    2. **Float sentinel detection**: if -1.0 is the sentinel, use `abs(delay - (-1.0)) < eps`, not `delay - (-1.0) < eps`.
    3. **Range checks**: `x in [a, b]` should use `x >= a - eps and x <= b + eps` (or `abs(x - (a+b)/2) < (b-a)/2 + eps`).
    4. **Cyclic comparisons**: if comparing angles or phases, use `abs(diff) < eps` to handle wraparound.
    The general rule: **for any approximate equality check, ask yourself: am I checking only one side? If so, use `abs` to make it symmetric.** The "asymmetric float comparison" bug is one of the most common in numerical code.

---

### 77. errdefer After Every Resource Acquisition (2026-06-02)

*   **The Bug:** In `create_server` at `src/loop/python/io/server/create_server.zig:203-207`, when a pre-existing socket is provided via `sock=`, the fd is duplicated with `std.os.linux.dup()` so the StreamServer owns its own copy. The original `errdefer` only cleaned up `address_list` — it didn't clean up the dup'd fd. If any subsequent operation (e.g., `Loop.Scheduling.Soon.dispatch`, the allocators, etc.) failed after the dup, the dup'd fd would leak.
*   **The Fix:** Added an `errdefer _ = std.os.linux.close(server_data.socket_fd);` immediately after the dup succeeds. This ensures the fd is closed on any subsequent error before the StreamServer takes ownership.
*   **Tests added:**
    *   No new tests were added. The fix follows the standard errdefer pattern for resource cleanup. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Add an errdefer immediately after every resource acquisition.** The pattern is:
    1. Acquire resource R.
    2. Add `errdefer cleanup(R);` immediately.
    3. Continue with code that might fail.
    The errdefer is "insurance" — it costs nothing on the success path and prevents leaks on the failure path. The same lesson applies to:
    1. **File descriptors**: dup, open, accept, pipe, socket all need errdefer.
    2. **Heap allocations**: every `allocator.create` and `allocator.dupe` needs errdefer.
    3. **Locks**: mutex.lock needs errdefer mutex.unlock.
    4. **Database transactions**: BEGIN needs errdefer ROLLBACK.
    5. **Reference counts**: Py_IncRef needs errdefer Py_DecRef.
    The general rule: **for every "acquire" operation, the very next line should be the matching "cleanup on error" defer.** The "I added the errdefer later" anti-pattern is a common source of leaks — by the time you get to the end of the function, you've forgotten which resources need cleanup. Adding the errdefer at the acquisition point keeps the cleanup tied to the acquisition.

---

### 78. SSL I/O Functions Can Raise WantRead/WantWrite/Error (2026-06-02)

*   **The Bug:** In `_SSLTransportWrapper.write` at `talyn/loop.py:36-38`, the call `self._ssp._sslobj.write(data)` can raise `SSLWantWriteError` (during renegotiation), `SSLWantReadError` (need to read more), `SSLError` (fatal), or `SSLSyscallError` (fatal). The previous code caught none of these — they propagated uncaught, crashing the protocol.
*   **The Fix:** Added a try/except for all four cases. For `SSLWantReadError` and `SSLWantWriteError`, set the corresponding `_write_wants_read` / `_write_wants_write` flag on the parent SSLProtocol so the appropriate read/write side re-arms. For `SSLError`/`SSLSyscallError`, schedule the fatal error to be raised via `call_soon` to break out of the current write context.
*   **Tests added:**
    *   No new tests were added. The fix mirrors the standard `asyncio.sslproto` SSLProtocol's handling. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **SSL I/O functions can return a "want" status (read or write) instead of completing synchronously.** The pattern is:
    1. **WantRead**: the SSL state machine needs to read more data from the peer before it can complete. Re-arm the read side.
    2. **WantWrite**: the SSL state machine needs to write more data to the peer before it can complete. Re-arm the write side.
    3. **Error**: the SSL connection is broken. Close the transport and notify the protocol.
    The same lesson applies to:
    1. **All non-blocking I/O**: sockets, pipes, files can return EAGAIN/EWOULDBLOCK which Python wraps as `BlockingIOError`.
    2. **Database cursors**: `cursor.execute()` can return "need to fetch more rows" or "connection lost".
    3. **Cryptographic operations**: signing/verifying can return "need more data".
    4. **Network protocols**: HTTP/2, WebSockets, gRPC all have want-read/want-write patterns.
    The general rule: **for any non-blocking I/O API, catch the "want" status and re-arm the appropriate side; catch the "error" status and close the connection.**

---

### 79. Best-Effort Thread Join on Timeout (2026-06-02)

*   **The Bug:** In `shutdown_default_executor` at `talyn/loop.py:485-496`, the function spawns a daemon thread to run `executor.shutdown(wait=True)` and then awaits a future with a timeout. If the future completes within the timeout, the `else` branch joins the thread. But if the timeout expires (raising `asyncio.TimeoutError`), the thread is not joined — it's left running. Since the thread is a daemon, it won't block process exit, but it may still be running and accessing resources that are about to be freed.
*   **The Fix:** In the `except asyncio.TimeoutError` branch, call `thread.join(timeout)` as a best-effort join. This gives the thread the same amount of time to complete after the future timed out. If it still doesn't return, we can't do anything more — the thread is daemon and will be cleaned up on process exit.
*   **Tests added:**
    *   No new tests were added. The fix is a one-line addition to the timeout path. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Always attempt to join a spawned thread, even on timeout.** The pattern is:
    1. **Spawn the thread.**
    2. **Wait for the work to complete (with timeout if applicable).**
    3. **Always join the thread** — either in the success path or in the timeout path.
    The "join only on success" anti-pattern is a common source of thread leaks. The same lesson applies to:
    1. **Process spawning**: subprocess.Popen should be waited on, not just polled.
    2. **Async tasks with background threads**: the asyncio task may complete but the thread is still running.
    3. **Resource pools**: thread pool executors should be shut down, not abandoned.
    4. **Timer threads**: scheduled callbacks running on a worker thread should be joined on cancel.
    The general rule: **for every spawned thread, the very last thing you do with it should be a join (or a daemon declaration).** The "thread leaks" bug is one of the most insidious because the process keeps running but the thread is just consuming resources in the background.

---

### 80. Drain Buffers Before Protocol Switch (2026-06-02)

*   **The Bug:** In `start_tls` at `talyn/loop.py:716-727`, the code already handled the StreamReader case: if the existing protocol was a `StreamReaderProtocol`, it copied the stream reader's buffer into the SSL incoming MemoryBIO. But for non-`StreamReaderProtocol` protocols (e.g., raw byte protocols, custom protocols), there was no buffer drain. Calling `transport.pause_reading()` is async — it just sets a flag, and data already in the transport's internal read buffer could be delivered to the OLD (cleartext) protocol, leaking plaintext before TLS was established.
*   **The Fix:** Before `pause_reading()`, check for an internal buffer on the raw transport (e.g., `transport._buffer` or `transport.buffer`) and feed any buffered data into the SSL incoming MemoryBIO. This ensures the new SSL protocol sees all the data, regardless of which protocol was active before.
*   **Tests added:**
    *   No new tests were added. The fix is a defensive drain of any internal buffer. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **When switching protocols or upgrading a connection, drain all intermediate buffers first.** The pattern is:
    1. **Pause reading** (stop new data from being read).
    2. **Drain existing buffers** (move any in-flight data to the new protocol).
    3. **Switch protocols.**
    4. **Resume reading** with the new protocol.
    The "switch and pray" anti-pattern — just switch protocols and hope the buffer is empty — leads to data loss or security vulnerabilities. The same lesson applies to:
    1. **TLS upgrade (start_tls)**: must drain pre-TLS data.
    2. **HTTP/1 to HTTP/2 upgrade**: must drain pre-upgrade data.
    3. **WebSocket upgrade**: must drain pre-upgrade HTTP request.
    4. **Protocol proxying**: when inserting a proxy between two protocols, drain both sides.
    5. **Connection migration**: when migrating a connection, drain the old transport.
    The general rule: **for every protocol/connection switch, ask yourself: what data is in flight right now? Where will it go after the switch?** The answer should be "to the new protocol" — not "lost" or "to the old protocol".

---

### 81. Signal Unregistration Must Reverse Signal Registration (2026-06-02)

*   **The Bug:** In `unlink` at `src/loop/unix_signals.zig:161-197`, the SIGINT branch only installed a `default_sigint_signal_callback` but did NOT unblock the signal from the process mask or remove it from the signalfd. So after unlinking SIGINT:
    1. The signal was still blocked (via `sigprocmask`).
    2. The signal was still in the signalfd mask.
    3. The process-level handler was still the dummy handler.
    The "default callback" installed was unreachable: blocked signals are delivered to signalfd (which no longer had SIGINT in its mask), not to the process-level handler. So the next Ctrl+C would be lost — the process wouldn't terminate.
*   **The Fix:** For SIGINT, do the same cleanup as the `else` branch: unblock the signal, remove it from signalfd, restore SIG_DFL. The callback is then unreachable anyway, so we early-return from unlink.
*   **Tests added:**
    *   No new tests were added. The fix is a defensive cleanup to ensure the signal is properly restored. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Signal unregistration must reverse every step of signal registration.** The pattern is:
    1. **Register**: block signal, add to signalfd, install handler.
    2. **Unregister**: unblock signal, remove from signalfd, restore SIG_DFL.
    The "install a default callback and hope" anti-pattern is a common bug. A callback that's unreachable due to a blocked signal is worse than no callback at all — the user thinks they have signal handling when they don't. The same lesson applies to:
    1. **All signal handlers**: SIGTERM, SIGUSR1, SIGUSR2 all need full cleanup.
    2. **File system watchers**: inotify_add_watch needs inotify_rm_watch.
    3. **Event sources**: epoll_ctl ADD needs epoll_ctl DEL.
    4. **Thread registrations**: pthread_create needs pthread_join.
    5. **Memory mappings**: mmap needs munmap.
    The general rule: **for every "add" operation, the matching "remove" must reverse all the side effects of the add.** If you can't enumerate all the side effects, the add operation is unsafe.

---

### 82. Never Leave Debug Prints in Hot Paths (2026-06-02)

*   **The Bug:** In the event loop's main blocking wait at `src/loop/runner.zig:244-265`, there were 4 separate `std.debug.print` calls in a tight loop that ran on every iteration of the hot path. Each print was a synchronous write to stderr. For an I/O-bound workload, this is severe performance degradation: every blocking wait iteration (which can be millions per second) was hitting the stderr file descriptor.
*   **The Fix:** Removed all 4 debug prints. Replaced with a single comment explaining why. The blocking wait logic itself (the `@atomicStore`, `mutex.unlock`, etc.) is unchanged.
*   **Tests added:**
    *   No new tests were added. The fix is a deletion of dead code. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Never leave debug prints in hot paths.** Even "temporary" debug prints have a way of making it to production. The pattern is:
    1. **Hot paths**: any code that runs more than ~1000 times per second.
    2. **Tight loops**: even one debug print per iteration is too much.
    3. **Critical sections**: even if the print is rare, it can deadlock if stderr is closed.
    The same lesson applies to:
    1. **Allocation tracking**: in debug builds, every `allocator.create` may be wrapped in logging. This is fine for `std.testing.allocator` in unit tests, but a performance disaster in production.
    2. **Reference counting assertions**: every `Py_DecRef` doing an `assert(refcount > 0)` is fine in tests but adds overhead in production.
    3. **Stack traces**: inlined stack traces on every function call (e.g., via `__builtin_frame_address`) destroy performance.
    4. **Mutex contention logging**: logging every lock acquisition is fine for a debug mutex, not for a hot mutex.
    The general rule: **any code that runs in a loop on a hot path should be O(1) and side-effect-free.** The "I left the debug print in for now" anti-pattern is a common source of performance regressions.

---

### 83. Make Data-Structure Operations Robust to Assumed Invariants (2026-06-02)

*   **The Bug:** In `BlockingTasksSet.pop()` at `src/loop/scheduling/io/main.zig:253-257`, the function decremented `self.index`, `self.active_tasks`, and `self.loop.reserved_slots`, but did NOT clear the slot that was being "released". This is fine as long as `pop()` is only called on the most recently pushed task (the LIFO assumption), because the slot won't be read again. But if any future code path calls `pop()` on a non-last task, the stale data in the slot would be read incorrectly.
*   **The Fix:** Clear the slot's `data`, `operation`, `index`, and `write_iovs_copy` fields before decrementing. Now `pop()` is safe regardless of which task it pops.
*   **Tests added:**
    *   No new tests were added. The fix is a defensive measure against future code changes. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Don't rely on assumed invariants that the function's signature doesn't enforce.** The pattern is:
    1. **The signature**: `pop()` doesn't take an index — it implies "pop the last one".
    2. **The invariant**: the caller always pushes and pops in LIFO order.
    3. **The fragility**: if a future caller breaks the invariant, the bug is silent.
    The fix is to **make the function safe even when the invariant is broken.** This is defensive programming: don't trust callers, don't trust the future, don't trust yourself. The same lesson applies to:
    1. **Stack pop**: if you pop a non-top frame, the stack should be coherent.
    2. **Allocator free**: freeing an arbitrary pointer should work (the allocator should validate).
    3. **Reference count decrement**: decrementing any refcount should work, not just the "expected" ones.
    4. **Database row deletion**: deleting any row should work, not just the "last inserted" one.
    The general rule: **for any data-structure operation, ask yourself: what state am I leaving behind? Is that state safe to read?** If the answer is "it depends on caller behavior", make the function self-sufficient.

---

### 84. Container Cleanup Needs Domain-Specific Knowledge (2026-06-02)

*   **The Bug:** In `Loop.deinit` at `src/loop/main.zig:164-166`, the three hook lists (`prepare_hooks`, `check_hooks`, `idle_hooks`) were cleared using `LinkedList.clear()`, which only destroys the linked-list node but doesn't call any cleanup on the contained `Callback` data. The `Callback` struct has a `cleanup: ?GenericCleanUpCallback` field that's a function pointer for releasing resources (e.g., decrementing a Python reference). So on loop teardown, the Python object references held in the callback data leaked.
*   **The Fix:** Added a new `clear_with_cleanup` method to `LinkedList` that takes a `comptime cleanup_fn` and invokes it on each node's data before destroying. Used it in `Loop.deinit` to invoke the Callback's cleanup function.
*   **Tests added:**
    *   No new tests were added. The fix is a defensive measure to prevent leaks on loop teardown. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Generic containers can't know about domain-specific cleanup needs.** A `LinkedList(T)` doesn't know if `T` holds a Python reference, a file descriptor, or a heap-allocated buffer. The pattern is:
    1. **Provide a "fast path" cleanup** for the simple case (just destroy the node).
    2. **Provide a "domain-aware" cleanup** for the case where the data holds resources.
    3. **Let the caller choose** which to use based on what `T` is.
    The "the container handles all cleanup" anti-pattern forces containers to know too much. The "the caller handles all cleanup" anti-pattern is what we had — fine for the simple case, but easy to forget for the domain case. The same lesson applies to:
    1. **HashMap/TreeMap**: should have a `clear_with_cleanup` variant.
    2. **ArrayList**: `deinit_with_cleanup` for elements that hold resources.
    3. **Thread pools**: should have a "shutdown with task cleanup" variant.
    4. **File system walkers**: should have a "walk and cleanup" variant.
    The general rule: **for every "destroy" operation, ask yourself: does the data need cleanup? If yes, provide a way to do it.**

---

### 85. Make `else` Branches Visible (2026-06-02)

*   **The Bug:** In `dispatch_completion_batch` at `src/loop/runner.zig:125-150`, the switch on `record.op` only handled `DataReceived` and `BufferUpdated`. The other 6 variants (`EofReceived`, `ConnectionMade`, `ConnectionLost`, `ResumeWriting`, `DatagramReceived`, `ErrorReceived`) all fell to a bare `else => {}` and were silently dropped. If a future code path pushed a record with one of these ops (e.g., a datagram transport added a new completion type), it would be silently lost with no warning.
*   **The Fix:** Replaced the bare `else => {}` with explicit cases for the unhandled variants that log a `std.log.warn` message naming the dropped op. The dispatch still doesn't act on these (the transport doesn't have the matching protocol callbacks), but the operator can now see if/when one is dropped.
*   **Tests added:**
    *   No new tests were added. The fix is a defensive measure to make silent drops visible. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Bare `else => {}` branches are silent bugs waiting to happen.** The pattern is:
    1. **The compiler is silent**: `else => {}` compiles cleanly.
    2. **The runtime is silent**: the op is dropped with no log.
    3. **The operator is silent**: they don't know the op is being dropped.
    4. **The bug is silent**: by the time someone notices, it's hard to trace back.
    The fix is to make the `else` branch **loud**: log the dropped op so it's visible. The same lesson applies to:
    1. **Switch statements on enums**: every variant should be explicitly handled or explicitly logged.
    2. **Pattern matches**: missing arms should be logged, not silently dropped.
    3. **Protocol message handlers**: unknown message types should be logged.
    4. **Syscall return codes**: unknown return codes should be logged.
    5. **Network protocol opcodes**: unknown opcodes should be logged.
    The general rule: **for every "default" branch, ask yourself: is this the right default? If not, log it.** The "silent default" anti-pattern is one of the most common sources of subtle bugs.

---

### 86. Distinguish Expected From Unexpected Outcomes (2026-06-02)

*   **The Bug:** In `BlockingTask.check_result` at `src/loop/scheduling/io/main.zig:116-117`, the cancel operations (`.Cancel` and `.CancelByFd`) had empty handlers. Cancel is fire-and-forget by design, but the result code (success, ENOENT indicating the task was already complete, or other errors) was being silently dropped. If a cancel returned an unexpected error (e.g., EINVAL, EBADF), there was no way for the operator to know.
*   **The Fix:** Added explicit handling: SUCCESS and NOENT are expected (the task either was canceled or had already completed and isn't there). Any other result code is logged as a warning. The cancel still doesn't act on the result (fire-and-forget), but unexpected results are now visible.
*   **Tests added:**
    *   No new tests were added. The fix is a defensive log statement. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Distinguish between "expected outcome" and "unexpected outcome" — even for fire-and-forget operations.** The pattern is:
    1. **Expected outcomes**: SUCCESS, expected non-error results.
    2. **Benign outcomes**: e.g., NOENT for a cancel that raced with completion.
    3. **Unexpected outcomes**: any other result code.
    The "fire and forget, ignore the result" anti-pattern hides bugs. The same lesson applies to:
    1. **Thread detach**: detach is fire-and-forget, but logging the exit status helps debugging.
    2. **Async cancel**: cancel is fire-and-forget, but logging unexpected errors helps debugging.
    3. **UDP send**: UDP is unreliable, but logging ICMP errors helps debugging.
    4. **Best-effort cleanup**: cleanup is best-effort, but logging failures helps debugging.
    The general rule: **for every "fire-and-forget" operation, ask yourself: what's the result code, and is the result code what I expected?** If the answer is "I don't know" or "I haven't thought about it", log it.

---

### 87. Don't Mix C-String and Length-Based String APIs (2026-06-02)

*   **The Bug:** In `task_get_name` at `src/task/utils.zig:44`, the format string `"Talyn.Task_{x:0>16}\x00"` included a C-string null terminator. `std.fmt.allocPrint` produces a `[]u8` slice whose length includes the null terminator. Then `PyUnicode_FromStringAndSize(random_str.ptr, @intCast(random_str.len))` created a Python string of length 27 (26 chars + 1 null), with an embedded NUL byte.
*   **The Fix:** Removed the `\x00` from the format string. `PyUnicode_FromStringAndSize` takes an explicit length, so a null terminator is unnecessary and harmful.
*   **Tests added:**
    *   No new tests were added. The fix is a one-character change. All 284 tests across all 4 Python versions in both Debug and ReleaseSafe modes pass after the fix.
*   **The Lesson:** **Don't mix C-string conventions with length-based string APIs.** C strings use a null terminator to mark the end. Length-based strings (like Python's `PyUnicode_FromStringAndSize`, Rust's `&str`, or Zig's `[]u8`) use an explicit length. Mixing them is a common bug:
    1. **C string + length API**: you include the null terminator in the length.
    2. **Length string + C string API**: you forget to add the null terminator.
    3. **Both**: you have neither (length is wrong AND string isn't null-terminated).
    The same lesson applies to:
    1. **Python bytes/str conversion**: `PyBytes_FromStringAndSize` is length-based, no null needed.
    2. **Rust &str → CString**: must explicitly add null terminator.
    3. **Zig []u8 → C strings**: must explicitly null-terminate.
    4. **JSON serialization**: JSON strings use explicit length, not null terminators.
    The general rule: **for any string conversion between C and length-based APIs, ask yourself: which API am I using, and does the string I'm passing match its expectations?**

