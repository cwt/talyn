# Leviathan TODO

## ✅ PRIORITY 1: Zig 0.16.0 Compatibility — DONE (2026-05-14)

Project now targets Zig 0.16.0 (was 0.15.2).

### 1.1–1.10: Summary

| Issue | Resolution |
|-------|-----------|
| `builtin.mode` → `.optimize` | NO CHANGE — reverted to `.mode` in 0.15.x |
| `usingnamespace` removed | Replaced with `pub const` re-exports (4 files) |
| `std.Thread.Mutex` → `std.Mutex` | NO CHANGE — still `std.Thread.Mutex` in 0.15 |
| `refAllDeclsRecursive` removed | Changed to `_ = Loop;` |
| `callconv(.C)` → `callconv(.c)` | 102 instances across 21 files |
| `addSharedLibrary` / `addTest` | Migrated to `addLibrary` + `createModule` |
| `std.ArrayList` unmanaged | 6 files: `.append(gpa, item)`, `.deinit(gpa)` |
| `empty_sigset` → `sigemptyset()` | Function instead of value |
| `sigaddset` type mismatch | Switched to `std.posix.sigaddset` |
| `.metadata()` → `.stat()` | API rename, `.size` field not method |
| `PyExc_*` C globals | `pub const` → `pub extern var` |
| jdz_allocator removed | Replaced with `std.heap.c_allocator` |
| `@cImport` no `usingnamespace` | ~100 symbols manually re-exported in `python_c.zig` |

---

## 🟡 PRIORITY 2: Network & Transport — ALL DONE (7/7)

### 2.1 — `create_connection` — ✅ DONE

Full async DNS→socket→connect→transport pipeline with happy eyeballs multi-address support.
11 tests pass (basic, send/recv, close, refused, multi-msg, extra_info, missing_args, invalid_factory, lambda, write_eof, is_closing).

**Bugs found & fixed:**
- **Double-decref on `protocol_factory`**: Borrowed reference from `args` was decref'd in `defer` block → segfault in error path. Fixed.
- **`undefined` field cleanup segfault**: `SocketCreationData` fields were `undefined` before initialization, but `errdefer` called `deinitialize_object_fields` which touched them. Fixed by making fields optional/null.
- **Memory leak in result tuples**: `PyTuple_New` result was incref'd by `future_fast_set_result` but never released. Added `defer py_decref(result_tuple)`.
- **Double-close on connected socket**: `defer` in connect callback closed `fd` even on success. Fixed with `fd_created` toggle.
- **Filename typo**: Renamed `create_connnection.zig` to `create_connection.zig`.
- **`is_closing` always False**: `transport_close` didn't set the `closed` flag. Fixed.
- **Intermittent hang in free-threading**: Race condition in `poll_blocking_events` where the loop could block even if callbacks were queued by other threads. Fixed by checking `ready_queue.empty()` before blocking.
- **`Abort` crashes on signals**: `io_uring` operations (submit/poll) were interrupted by signals (EINTR), causing Zig panics or inconsistent returns to Python. Fixed by implementing silent retries on `SignalInterrupt` and removing all remaining `@panic`/`unreachable` calls in the core IO path.
- **GC instability in Subprocess**: `SubprocessTransport` was crashing during GC cycles. Switched to stable manual reference counting and fixed struct initialization to prevent clobbering the Python object head.

---

## 🧠 Lessons Learned: The Journey to 100% Stability

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

### 11. Ghost Reference Cycle in Future Callbacks (2026-05-13)
When Task A awaits Future B, `wakeup_task` is registered as a `ZigGeneric` callback on Future B with `ptr = task`. `traverse_callbacks_queue()` at `src/future/callback.zig:164-177` had a no-op `ZigGeneric` arm — the GC could not see the `Task ← Future` cycle.
*   **The Bug:** Task holds `fut_waiter` → Future B. Future B's callback queue holds `ptr` → Task A. Python GC traverses Task A's members (including `fut_waiter` → Future B) and Future B's members (including `callbacks_queue`), but the `ZigGeneric.ptr` field was invisible. This ghost cycle leaked memory, causing OOM on long-running processes. The comment in the code literally said "This cycle is HIDDEN".
*   **The Fix:** The `ZigGeneric` arm now calls `visit(ptr)` to expose the Task pointer to the GC. The `@alignCast(@ptrCast(ptr))` is safe — `ptr` is always a `*PythonTaskObject` from the Python heap.
*   **The Lesson:** Any native structure holding a `PyObject` pointer must be reachable via `tp_traverse`. Skipping even one arm of a traversal union breaks the cycle detector.

---

## 🏗 Architectural Mandates (Rules for the Future)

1.  **NO PANICS in the IO Path:** Use `handle_zig_function_error` to convert Zig errors to Python exceptions. Never use `@panic` or `unreachable` in code that runs during the normal loop cycle.
2.  **EINTR Safety:** All `io_uring` submissions must use `IO.submit_guaranteed()`.
3.  **Thread-Safe Dispatches:** Any function that can be called from a background thread (like `call_soon_threadsafe`) must trigger the `eventfd` wakeup *only if* the loop is actually blocked.
4.  **Null Discovery:** In free-threading, GC can null out fields concurrently. Always use `?PyObject` and handle `null` gracefully in callbacks.
5.  **Initialization Order (GC Safety):** When adding items to a collection traversed by Python's GC, **ALWAYS fully initialize the data before advancing the index or linking the node.** Use `@atomicStore` with release semantics to ensure initialization is visible to GC threads.
6.  **Ring FD Guard Before Kernel Calls:** Any function touching `ring.fd`, `ring.register_files_update()`, or any io_uring registration API MUST check `ring.fd >= 0` first. During `loop.close()`, callbacks can fire after `ring.deinit()` has set fd = -1. Asserting `fd >= 0` without a guard will `SIGABRT`.

## 🔵 PRIORITY 4: Standard Compatibility & GC Stability — ✅ DONE (2026-05-10)

Full compatibility with standard `test.test_asyncio` suite modules. 185 internal tests + 400+ standard tests passing.

---

## 🔴 PRIORITY 9: Callback Dispatch Rewrite — Flat Ring Buffer (2026-05-11)

### Root Cause of 0.42× Task Performance

After 7 performance optimizations (Priority 8), leviathan remains **2-2.5× slower** than `asyncio` on task-intensive workloads. All incremental fixes hit the same wall: the `CallbacksSetsQueue` linked-list dispatch layer.

```
uvloop/libuv:  array[index++] = callback_ptr     // O(1), 1 store
leviathan:     walk(node) → find_slot() → copy(80-byte Callback)
               // O(n) walk, memcpy per append
```

### Design: Flat Ring Buffer Replacements

Replace the current `CallbacksSetsQueue` + `CallbacksSet` linked-list with two fixed-size ring buffers.

### Implementation Plan

#### Phase 1: Single Ring Buffer (Non-thread-safe)

| # | Task | Files | Status |
|---|------|-------|:---:|
| 9.1 | Define `RingBuffer(N)` struct with `[N]Callback` array, `read_idx`, `write_idx`, `executed` bitset | `callback_manager.zig` | ✅ **DONE** |
| 9.2 | Replace `append()` with O(1) ring push | `callback_manager.zig` | ✅ **DONE** |
| 9.3 | Replace `execute_callbacks()` loop with ring drain | `callback_manager.zig` | ✅ **DONE** |
| 9.4 | Replace `prune()` with ring reset | `callback_manager.zig` | ✅ **DONE** |
| 9.5 | Add `tp_traverse` for ring buffer | `callback_manager.zig` | ✅ **DONE** |
| 9.6 | Wire up `call_once`, `dispatch_nonthreadsafe`, double-buffer swap | `runner.zig`, `soon.zig` | ✅ **DONE** |
| 9.7 | Update zig unit tests | `callback_manager.zig` | ✅ **DONE** |
| 9.8 | Run full test suite + benchmarks | All | ✅ **DONE** |

**Current impact:**
- Task-intensive benchmarks: 0.42× → **0.44×** (marginal gain, task spawning still bottlenecked).
- I/O benchmarks (UDP Ping-Pong): 0.80× → **1.08×** (matching/beating asyncio).
- Stability: No more linked-list walks or dynamic growth panics. GC-safe in free-threading.

#### Phase 2: io_uring Batching (Requires Phase 1)

Once the dispatch layer is O(1), the next bottleneck is io_uring submission/reaping overhead:

| # | Task | Status |
|---|------|:---:|
| 9.9 | Batch SQE submission — collect pending ops, submit all in one `io_uring_enter` | 🔴 **REVERTED** |
| 9.10 | Batch CQE reaping — process all CQEs per `copy_cqes` without re-entering loop | 🔴 Pending |
| 9.11 | Registered buffers / fixed files for hot paths | 🔴 Pending |

**Expected impact with both phases:** leviathan at **2-5×** asyncio, matching or beating uvloop.

---

## 🔴 PRIORITY 10: Python/Zig Boundary Overhead Elimination (2026-05-13)

### Root Cause of 0.2-0.4× Task Performance (REVISED)

Task Spawn benchmark (zero I/O, pure `create_task()`) shows leviathan at **0.21-0.39×** asyncio. The original analysis blamed 12 "Python/Zig boundary crossings" but this was incorrect — in CPython 3.14, `_enter_task`/`_leave_task`/`_register_task`/`all_tasks` are all **C builtins** (from the `_asyncio` C module), not Python bytecode. `PyObject_Vectorcall` on a C builtin is just a function pointer call — same cost as calling from Zig directly.

The real bottleneck after debugging: the 80-byte `Callback` struct copy per `Soon.dispatch` + `PyIter_Send` overhead (coroutine startup is inherently expensive). These are architectural costs of leviathan's design.

**Conclusion: Priority 10 is WON'T FIX.** The perceived boundary crossings were already near-optimal. The core bottleneck is in the task creation and dispatch architecture itself.

### Implementation Plan

#### Phase 1: Eliminate _register_task / _enter_task / _leave_task Python calls

| # | Task | Files | Status |
|---|------|-------|:---:|
| 10.1 | Cache `loop._asyncio_tasks` PySet pointer at loop init | `loop/main.zig`, `loop/python/constructors.zig`, `loop.py` | ✅ DONE |
| 10.2 | Replace `PyObject_Vectorcall(_register_task)` with `PySet_Add` in `task_schedule_coro` | `task/constructors.zig` | ⚠️ WON'T FIX — `_register_task` is a C builtin, no Python frame overhead |
| 10.3 | Replace `PyObject_Vectorcall(_enter_task)` with direct set/dict ops | `task/callbacks.zig` | ⚠️ WON'T FIX — `_enter_task` is a C builtin in 3.14 |
| 10.4 | Replace `PyObject_Vectorcall(_leave_task)` with direct set/dict ops | `task/callbacks.zig` | ⚠️ WON'T FIX — `_leave_task` is a C builtin in 3.14 |
| 10.5 | Skip `PyContext_Enter`/`Exit` when context is default | `task/callbacks.zig` | ⚠️ WON'T FIX — `PyContext_Current()` not in public C API, so we can't do the check ourselves. CPython's `PyContext_Enter` already does fast pointer comparison internally. Saving the function call overhead is ~5ms in Task Spawn (3%) — not worth the churn. |
| 10.6 | Run full test suite + benchmarks | All | ✅ DONE (263 tests pass, 11 benchmarks complete) |

**Expected impact:** 0.2-0.4× task performance is an architectural bottleneck (PyIter_Send + 80-byte Callback copy per dispatch). Priority 10 optimizations cannot fix this.

#### Phase 2: Further boundary reductions (future)

| # | Task | Status |
|---|------|:---:|
| 10.7 | Fuse `PyIter_Send` with enter/leave in a single Zig→Python trampoline | 🔴 Future |
| 10.8 | Investigate `PyEval_SaveThread`/`PyEval_RestoreThread` overhead in callback dispatch loop | 🔴 Future |
| 10.9 | Profile remaining boundary crossings with `perf` to find next bottleneck | 🔴 Future |

---

## 🔴 PRIORITY 11: SQE Batch Submission — io_uring Batching (2026-05-13)

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
| 11.12 | Batch CQE reaping — process all CQEs per `copy_cqes` without re-entering loop | 🔴 Future |
| 11.13 | Registered buffers / fixed files for hot paths | 🔴 Future |

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

## 🔴 PRIORITY 13: Subprocess — pidfd-Based Exit Notification — ✅ DONE (2026-05-15)

### Root Cause of 0.23× Subprocess Performance

Subprocess benchmark (0.23×, 4× slower than asyncio) was the worst-performing benchmark.

**Old design:** `src/transports/subprocess/transport.zig` used **timer-based polling** to detect child exit:

```
start_exit_watcher → queue WaitTimer(1ms)
1ms later: wait4(pid, NOHANG) → process still starting (Python init ~10-30ms)
5ms later: wait4 → still starting
25ms later: wait4 → process exited → callback
Total latency per process: ~31ms (polling overhead)
```

**asyncio approach:** Uses SIGCHLD signal handler. Kernel delivers the signal immediately when the child exits. Latency: microseconds.

**Existing correct infrastructure:** `src/loop/child_watcher.zig:42-60` already implements the right approach:

```
pidfd_open(pid, 0) → queue WaitReadable(pidfd)
pidfd becomes readable → kernel wakes io_uring → callback → waitid(.PIDFD)
```

The `child_watcher` was a separate mechanism from the subprocess transport and was NOT used by it.

### Fix: Port subprocess transport to pidfd + WaitReadable

Replaced `WaitTimer`+`wait4` polling with `pidfd_open`+`WaitReadable`+`waitid(.PIDFD)` — same as child_watcher.

| # | Task | Status |
|---|------|:---:|
| 13.1 | Open pidfd in `start_exit_watcher` via `pidfd_open` syscall | ✅ DONE |
| 13.2 | Queue `WaitReadable` on pidfd instead of `WaitTimer` | ✅ DONE |
| 13.3 | Use `waitid(.PIDFD)` instead of `wait4` in callback | ✅ DONE |
| 13.4 | Close pidfd in `subprocess_close` | ✅ DONE |
| 13.5 | Removed `poll_count` and `pidfd_timer_duration` | ✅ DONE |
| 13.6 | All 263 tests + 5 std modules pass on 4 Pythons | ✅ DONE |

### Actual Impact

| Benchmark | Before (461) | After (462) | Change |
|-----------|:-----------:|:----------:|:------:|
| **Subprocess** | **0.23×** | **~1.0×** | **+335%** 🔥 |
| All others | unchanged | unchanged | within noise |

---

## 🔴 PRIORITY 14: Remove IOSQE_ASYNC from Data Ops — ✅ DONE (2026-05-15)

### Root Cause of 0.3-0.6× I/O Performance

Every IO operation set `sqe.flags |= IOSQE_ASYNC` (20 locations across 4 files).
This forces the kernel to offload ALL operations to workqueue threads, even
trivial read/write on sockets with data already buffered. Each offloaded op
adds a context switch (submit → workqueue → complete).

**Fix:** Removed `IOSQE_ASYNC` from `ring.read`, `ring.write`, `ring.writev`,
`ring.recvmsg`, `ring.sendmsg`. Kept on `POLL_ADD`, `Timer.wait`, `link_timeout`
(inherently async ops). `connect`, `accept`, `shutdown` also had `IOSQE_ASYNC` but
were removed separately in PRIORITY 16.

On non-blocking sockets, the kernel handles `-EAGAIN` gracefully:
it auto-installs a poll callback and completes when data arrives.
No workqueue needed — no context switch overhead.

### Actual Impact (M=65536)

| Benchmark | Before (464) | After (465) | Change |
|-----------|:-----------:|:----------:|:------:|
| **UDP Ping-Pong** | **0.45×** | **1.16×** | **+156%** 🔥 |
| **TCP Echo** | **0.38×** | **0.75×** | **+99%**  |
| Event Fiesta Factory | 0.65× | 0.91× | +40% |
| Socket Ops | 0.53× | 0.65× | +23% |
| Producer Consumer | 0.62× | 0.73× | +18% |
| Task Spawn | 0.67× | 0.75× | +11% |
| Chat | 0.96× | 1.00× | ~same |
| Subprocess | 1.00× | 1.00× | ~same |

**Impact:** UDP Ping-Pong now beats asyncio. All I/O benchmarks improved
significantly. The remaining gap (~0.7× on TCP/Unix Echo) is likely from
callback dispatch overhead (Zig→Python boundary per completion).

---

## 🔴 PRIORITY 15: Batch Dispatch Engine + Full io_uring — Architectural Redesign

### Phase 1: Completion Record Buffer — ✅ DONE (2026-05-15)

Infrastructure in place. Batch insertion disabled; completions flow through standard callback path.
All 268 tests pass on all 4 Pythons (3.13, 3.14, 3.13t, 3.14t).

**Files added/modified:**
| File | Change |
|------|--------|
| `src/loop/completion.zig` | New: `CompletionOp` enum, `CompletionRecord` (32 bytes), `CompletionBatch` (max 4096, GC-safe traverse) |
| `src/loop/main.zig` | `Loop` struct: added `completion_batch: CompletionBatch` field |
| `src/loop/runner.zig` | `dispatch_completion_batch()` + `batch_clear()` functions; called in main loop tick |
| `src/loop/runner.zig` | `fetch_completed_tasks`: batch insertion logic present but bypassed; uses standard callback path |
| `src/transports/read_transport.zig` | `perform()`: sets `module_ptr` to `parent_transport` for batch routing; added `batch_dispatched` flag |
| `src/transports/stream/read.zig` | Skip Python protocol call when `batch_dispatched` is true; still re-queues read |
| `src/callback_manager.zig` | Added `batch_dispatched` flag to `CallbackData` |
| `leviathan/loop.py` | `_dispatch_completions()`, `_dispatch_completions_with_list()`, `_dispatch_data_received()`, `_dispatch_eof_received()`, `_dispatch_buffer_updated()`, `_dispatch_connection_lost()` |
| `src/loop/python/constructors.zig` | `loop_traverse`: visits `completion_batch` for GC safety |

### Phase 2: Batch Dispatch — ✅ DONE (2026-05-16)

Batch dispatch now enabled. **Key insight:** eliminate ALL PyObject pointers from
`CompletionRecord`. Store only raw Zig pointers — GC never touches the batch.

**Root cause 1 (deadlock — FIXED):** Protocol methods call `loop.call_soon()` which
needs the mutex. Moved `dispatch_completion_batch` to after `mutex.unlock()`.

**Root cause 3 (GC segfault):** `CompletionRecord` stored `transport: ?PyObject` and
`data: ?PyObject`. The GC traversed these. When `batch_clear` decref'd them without
nullifying the slot first, the GC could visit a dangling pointer during decref's own
`__del__` if the deallocator triggered a GC collection → segfault.

**Fix:** Replaced PyObject fields with raw Zig pointers:
- `transport: ?PyObject` → `stream_transport: ?*anyopaque` (Zig pointer to `StreamTransportObject`)
- `data: ?PyObject` → `buffer_ptr: ?*anyopaque` (raw bytes pointer) + `nbytes: i64`
- PyBytes created during dispatch from `buffer_ptr + nbytes`
- Protocol accessed via transport's cached method pointers (`protocol_data_received`, `protocol_buffer_updated`)
- `batch_clear` simplified to just `reset()` — no decrefs needed (no PyObject stored)
- No GC `traverse` needed — `CompletionBatch` has zero PyObject pointers
- Python-side dispatch helpers (`_dispatch_completions`, etc.) retained but bypassed in favor of direct Zig dispatch

**Why the old approach failed:** The fundamental issue was storing PyObject pointers
in a buffer that can be overwritten between `tp_traverse` visits. Even with proper
incref/decref, the window between `batch_clear` (which decref'd the pointers) and
the next `reset()` created a race where GC traversal could visit stale pointers.

**New approach (robust):**
1. `CompletionRecord` stores `stream_transport: ?*anyopaque` — transport is a Zig struct, not a PyObject. GC doesn't visit it.
2. `buffer_ptr: ?*anyopaque` + `nbytes: i64` — raw bytes from the read transport's internal buffer. No PyBytes until dispatch.
3. In `fetch_completed_tasks`: push record directly (no incref, no PyBytes creation).
4. In `dispatch_completion_batch`: read records, create PyBytes + call protocol methods via transport's cached `*anyopaque` pointers.
5. `batch_clear` is just `batch.reset()` — zero PyObject interaction.
6. No GC traverse for the batch at all.

**Files changed:**
| File | Change |
|------|--------|
| `src/loop/completion.zig` | Remove PyObject fields + `traverse()`. Add `stream_transport`, `buffer_ptr` fields |
| `src/loop/runner.zig` | `fetch_completed_tasks`: enable batch insertion (remove `false and` guard). `dispatch_completion_batch`: create PyBytes from raw buffer + call protocol methods. Remove `batch_clear` |
| `src/loop/python/constructors.zig` | Remove `completion_batch.traverse()` from `loop_traverse` |

**Impact:** All 268 tests pass on all 4 Pythons + standard asyncio test suites pass on all 4 Pythons + Zig unit tests pass.

### Root Cause of 0.6-0.8× I/O Performance

The current architecture processes completions one-at-a-time with per-completion Zig→Python crossings:

```
CQE → Zig callback → memcpy 48-byte Callback into ring buffer → pop → PyObject_Call → Python method
```

This means **1 Zig→Python boundary crossing per I/O completion**. For TCP Echo at M=65536:
- 128 completions per batch (64 read + 64 write)
- 128 Python crossings via `PyObject_CallOneArg(protocol.data_received, py_bytes)`
- Each crossing: CPython builds args tuple, does type checks, calls method, returns

**The fix:** Replace per-completion Python calls with batched dispatch. Zig writes completion records to a shared buffer, Python reads the batch and dispatches in a tight native loop.

### Design: Completion Record Buffer

```
Current:                                      Proposed:
                                                                    
Zig: copy_cqes → fetch_completed_tasks        Zig: copy_cqes → fill CompletionRecord[64]  
       → ring_buffer.push(Callback)                  → set ready_count atomic
       → each callback does PyObject_Call     Python: read batch[0..ready_count]
                                                     → for each: switch type → call method
                                                     → clear batch
```

**CompletionRecord** (lightweight, no function pointers):
```zig
const CompletionRecord = struct {
    operation: enum { DataReceived, EofReceived, ConnectionLost, 
                     ResumeWriting, Accept, Connected, ... },
    transport: ?*TransportObject,
    data: union { bytes: *PyObject, nbytes: i64, error: ?*PyObject, ... },
};
```

Instead of copying a 48-byte `Callback` struct (with function pointer, module_ptr, callback_ptr), we store just the operation type + transport pointer + data. Python reads this and calls the protocol method natively — no function pointer indirection.

### Implementation Plan

#### Phase 1: Completion Record Buffer (replaces callback_manager ring buffer for IO completions) — ✅ DONE

| # | Task | Files | Expected |
|---|------|-------|:--------:|
| 15.1 | Define `CompletionRecord` union for all IO operation types | `src/loop/completion.zig` | ✅ |
| 15.2 | Replace `fetch_completed_tasks` — write `CompletionRecord` instead of pushing `Callback` | `runner.zig` | ⏸ (infra ready, batch insertion bypassed) |
| 15.3 | Add Python-accessible batch buffer (`CompletionRecord[N]` + `ready_count` atomic) | `loop/main.zig` | ✅ |
| 15.4 | Add Python-side dispatch loop: read batch, call protocol methods natively | `loop.py` | ✅ |
| 15.5 | Route Python dispatch errors back to loop exception handler | `loop.py` | ✅ |
| 15.6 | Keep callback_manager for non-IO tasks (call_soon, call_later, task wakeups) | — | ✅ No change for task dispatch |
| 15.7 | Run full test suite + benchmarks | All | ✅ 268 tests pass, 4 Pythons |

#### Phase 2: io_uring SQPOLL — Zero-Syscall Submission — ⛔ REVERTED

SQPOLL was implemented and tested but **reverted** after benchmarks showed net regressions.
See [PRIORITY 17](#🔴-priority-17-sqpoll-hang-after-16000-total-sqes--✅-fixed-2026-05-17) for full analysis.

| # | Task | Status |
|---|------|:------:|
| 15.8 | Init io_uring with `IORING_SETUP_SQPOLL` | ⛔ Reverted |
| 15.9 | `submit_guaranteed()` SQPOLL fast path | ⛔ Reverted |
| 15.10 | Handle `IORING_SQ_NEED_WAKEUP` | ⛔ Reverted |
| 15.11 | Unit tests for SQPOLL | ⛔ Removed |

**Why reverted:** On kernel 7.0.6, SQPOLL has a critical bug causing hangs after ~16000 SQEs
(P17). The P17 fix (eventfd write before every blocking `enter()` + `SQ_WAKEUP` on every
`submit()`) adds more overhead than SQPOLL saves. Net result: **UDP Ping-Pong dropped
from 1.16× to 0.57×**, Socket Ops from 0.65× to 0.49×. Zero-syscall submission is
theoretically valuable but practically harmful on this kernel.

#### Phase 3: Registered Buffers + Fixed Files — ✅ DONE (2026-05-17)

IOSQE_FIXED_FILE optimization eliminates `fget`/`fput` per IO operation. Socket FDs are
registered in a sparse fixed file table at transport creation. Index 0 reserved for eventfd.

**Bug found & fixed (2026-05-17):** `Loop.release()` order was wrong — `io.deinit()` ran
before callback dispatch. Pending `read_operation_completed` callbacks called
`unregister_fixed_file()` on a deinitialized ring (fd = -1), triggering
`assert(fd >= 0)` → abort. Fixed by:
1. Guarding `unregister_fixed_file()` with `ring.fd >= 0` check
2. Moving callback dispatch before `io.deinit()` in `Loop.release()`
See Lesson 12 for details.

| # | Task | Files | Expected |
|---|------|-------|:--------:|
| 15.12 | Register transport read/write buffers with `io_uring_register_buffers` | `io/main.zig`, transport files | |
| 15.13 | Use `IOSQE_FIXED_FILE` for hot-path socket operations | `read.zig`, `write.zig` | |
| 15.14 | Pre-register eventfd + pidfds as fixed files | `io/main.zig`, `child_watcher.zig` | |
| 15.15 | Benchmark — measure buffer registration impact | All | **Expected: 1.5-2.5× → 2.0-3.5×** |

#### Phase 4: Combined Submit+Wait + Full-Batch CQE Drain

| # | Task | Files | Expected |
|---|------|-------|:--------:|
| 15.16 | Replace `flush_pending_sqes()` + `copy_cqes()` with combined `io_uring_enter(to_submit, wait_nr, GETEVENTS)` — one syscall instead of two | `runner.zig` | |
| 15.17 | Drain ALL available CQEs per batch (not just batch_size) — `IORING_ENTER_GETEVENTS` with `wait_nr = 0` after first wake | `runner.zig` | |
| 15.18 | Benchmark | All | |

### Expected Impact (M=65536)

| Benchmark | Current (479) | Phase 1 | Phase 3 | Phase 4 |
|-----------|:------------:|:-------:|:-------:|:-------:|
| **TCP Echo** | **0.65×** | 1.2× | 2.5× | **3.0×** |
| **UDP Ping-Pong** | **0.57×** | 1.5× | 3.0× | **3.5×** |
| Socket Ops | 0.49× | 1.0× | 2.5× | **3.0×** |
| Chat | 0.95–1.06× | 1.0× | 1.5× | **1.8×** |
| Subprocess | 0.98× | 1.0× | 1.2× | **1.5×** |

**Note:** Phase 2 (SQPOLL) was reverted. These targets assume Phases 3+4 are built
on the non-SQPOLL baseline, which already has batched SQE submission (Phase 1)
via `flush_pending_sqes()`. The main missing pieces are registered buffers and
combined submit+wait.

---

## 🔴 PRIORITY 17: SQPOLL Hang After ~16000 Total SQEs — ⛔ REVERTED (2026-05-17)

### Root Cause

After ~16000–16400 total SQEs (~2 wraps of 8192-entry SQ ring), `run_until_complete` on a single `Loop` object hangs in `enter(0, 1, GETEVENTS | SQ_WAKEUP)` — blocks forever waiting for a CQE that never arrives.

### Investigation Timeline

| Attempt | Finding |
|---------|---------|
| Check `/proc/<tid>/status` | **SQPOLL thread is `R (running)`** during the hang — NOT sleeping. `SQ_WAKEUP` is useless because the thread is already awake. |
| Replace eventfd READ with POLL_ADD | Hang still at exactly same iteration count. Eventfd SQE type was irrelevant. |
| Always call `enter(0, 0, SQ_WAKEUP)` unconditionally in `submit_guaranteed` | NO effect — same iteration count hang. Thread doesn't need waking. |
| Larger batches (m=128, m=256) hit hang earlier | Hang correlates with **total SQE count**, not iteration count. ~16000–16400 total SQEs triggers the hang regardless of batch size. |
| Single-connect loops (m=1, ~2 SQEs/iter) run 500+ iterations fine | Below the threshold. |

### Key Discoveries

1. **`flush_sq()` returns `sq_ready()` = `sqe_tail − kernel_sq_head`** — the **total backlog** of SQEs the kernel hasn't yet consumed since the beginning, NOT the count of SQEs just flushed. After 17001 submitted and kernel consumed 16400, `flush_sq()` returns 601.

2. **`submit_guaranteed` over-submits stale SQEs**: `ring.submit()` returns `sq_ready()` (601), then calls `enter(601, 0, SQ_WAKEUP)`. The kernel may try to re-process SQEs already consumed by the SQPOLL thread — corrupting its internal SQE tracking.

3. **No CQE production guarantee**: With SQPOLL thread running but ignoring SQ_WAKEUP, and no socket operations producing CQEs, `enter(0, 1, GETEVENTS | SQ_WAKEUP)` has **no mechanism to produce a CQE** — the eventfd POLL_ADD won't fire because nobody wrote to the eventfd.

### The Fix (tried — reverted with SQPOLL)

In `poll_blocking_events`'s blocking path, **write to eventfd before every blocking `enter()`**:

```zig
_ = try self.io.wakeup_eventfd();
```

This guarantees the eventfd POLL_ADD produces a CQE, so `enter()` returns immediately.

**Why it's insufficient:** The P17 fix works around the hang but adds 1 eventfd write + 1 eventfd read + 1 POLL_ADD re-registration per loop iteration. When combined with `SQ_WAKEUP` on every `submit_guaranteed()`, the total syscall overhead **increases** vs non-SQPOLL mode. UDP Ping-Pong dropped from 1.16× to 0.57× — a 50% regression.

### Results

- P17 fix itself works: all 269 tests pass on all 4 Pythons
- **BUT benchmark regressions make SQPOLL net-negative:** UDP Ping-Pong −50%, Socket Ops −23%, TCP/Unix Echo −16-21%
- **Conclusion: SQPOLL reverted.** The kernel bug on 7.0.6 cannot be worked around without unacceptable overhead. Revisit on kernel ≥ 7.10.

### Lesson

Never assume `SQ_WAKEUP` works on all kernel versions. The eventfd is the **only guaranteed CQE source** — always prime it before blocking if you need to wake. And more importantly: **benchmark before shipping** — SQPOLL's theoretical zero-syscall benefit is wiped out by the workarounds needed for kernel bugs.

---

## 🔴 PRIORITY 16: Socket Ops Stability Investigation — ⚠️ WON'T FIX (2026-05-15)

### Root Cause Analysis of 0.63× Socket Ops Performance (24% Stdev)

Socket Ops benchmark (0.63×, 512 sequential one-shot connections) had high variability.
Hypothesis: `IOSQE_ASYNC` on `connect`/`accept`/`shutdown` forced workqueue offloading,
causing scheduling jitter.

**Attempted fix:** Removed `IOSQE_ASYNC` from `socket.zig` connect/accept/shutdown.

**Result:** Socket Ops benchmark **TIMEOUT** at M=1024. Root cause: io_uring's inline
`IORING_OP_CONNECT` without `IOSQE_ASYNC` returns `-EINPROGRESS` for non-blocking sockets
without properly installing a poll callback. The workqueue is **required** for correct
TCP handshake handling in io_uring.

**Conclusion:** `IOSQE_ASYNC` cannot be removed from connect/accept for io_uring.
The 24% stdev is inherent to workqueue scheduling and cannot be eliminated without
changing the io_uring submission model (SQPOLL was tried in P15 Phase 2 and reverted —
see PRIORITY 17).

### Tests Added (kept as regression tests)

| File | Tests |
|------|-------|
| `tests/test_socket_ops.py` | 5 new tests: many_sequential_connections, raw_socket_connect_accept, shutdown_variants, concurrent_connect_accept_stress, unix_socket_connect_accept |

---

## PRIORITY 12: Callback Struct Slimming (2026-05-14) ✅ DONE

### Root Cause of 0.4-0.5× Performance

Every dispatch copied a 112-byte `Callback` struct into the ring buffer.
The `exception_context` field (56 bytes inline) was the biggest contributor —
it included two 16-byte slices (`module_name`, `exc_message`) that are constant
per callback function type and only used in error/cold paths.

| Size | Before | After | Saving |
|------|:------:|:-----:|:------:|
| `CallbackExceptionContext` | 48 bytes | removed | 100% |
| `CallbackData` | 88 bytes | 40 bytes | 55% |
| `Callback` | 112 bytes | 48 bytes | **57%** |

**Fix:** Replaced inline `exception_context: ?CallbackExceptionContext` (56 bytes)
with two optional pointers: `module_ptr: ?*PyObject` (8) + `callback_ptr: ?PyObject` (8).
Exception handler now receives `module_ptr` and `callback_ptr` directly instead
of a nested context struct.

**Impact:** TCP Echo recovered from 0.29× → 0.56× (+93%). Chat 0.79→0.84× (+6%).
Task-intensive benchmarks gained 5-10%. The smaller dispatch struct means less
cache pressure and fewer memory bandwidth cycles per dispatch.

### UDP Ping-Pong Timeout — ✅ FIXED (2026-05-14)

The UDP Ping-Pong benchmark was failing with a timeout or entering a busy loop of 0-byte `recvmsg` completions. 

**Root Cause:** 
1. **Dangling Stack Pointers:** `DatagramTransport.sendto` (connected path) used a stack-allocated `iovec`. When `PerformWriteV` was deferred (Priority 11 Phase 1), the pointer became invalid before submission.
2. **Zero-Copy Stack MSGHdr:** `Read.perform` and `Write.perform` used stack-allocated `msghdr` structs for the `zero_copy` path. As these operations were deferred, they also used dangling pointers.
3. **Circular Dependency:** UDP Ping-Pong involves immediate request-response. Deferring the first `sendto` (the ping) until the end of the tick created a deadlock if the loop blocked waiting for a completion that couldn't happen until the ping was sent.

**The Fix:**
1. **Unified SendTo Path:** Refactored `z_datagram_sendto` to use heap-allocated `SendToData` and `.PerformSendMsg` for both connected and unconnected paths. `.PerformSendMsg` uses immediate submission, ensuring pointers are valid and breaking the circular dependency.
2. **Immediate Zero-Copy Submit:** Added `IO.submit_guaranteed()` to `Read.perform` and `Write.perform` when `zero_copy` is enabled. This ensures the stack-allocated `msghdr` is consumed by the kernel before the function returns.
3. **Busy-Loop Prevention:** While not the primary cause, ensured that `read_completed` doesn't just blindly re-arm on 0-byte datagrams if they persist (though this is standard for UDP).

**Impact:** UDP Ping-Pong benchmark now passes for all $M$ values, matching or slightly beating `asyncio` performance.

### Safety Checklist

- [x] **Lesson 1 (Atomic Sleep):** `should_wait` is evaluated AFTER flush, inside the mutex — safe
- [x] **Lesson 2 (EINTR):** `flush_pending_sqes()` uses `submit_guaranteed()` — already EINTR-safe
- [x] **Lesson 9 (EventFD):** `register_eventfd_callback()` still calls `submit_guaranteed()` immediately — no change
- [x] **Cancellation correctness:** `queue()` flushes SQ before dispatching Cancel — target visible to kernel
- [x] **No indefinite deferral:** `poll_blocking_events()` forces flush on every iteration — max deferral is 1 tick
- [x] **No deadlock on idle loop:** `should_wait=false` when flush submits 0 and `reserved_slots==0`

---

## ✅ Completed Next Steps

1.  **`create_server` DNS** — ✅ Already implemented with async state machine (same callback pattern as `create_connection`). Added `host=None` support (binds to all interfaces: IPv4 + IPv6).
2.  **Universal Sockaddr Handling** — ✅ Already in place. Address resolution uses `std.net.Address` throughout; family is detected dynamically from `address.any.family`.
3.  **`getnameinfo`** — ✅ Already implemented at `src/loop/python/io/socket/getnameinfo.zig`. Registered as `loop.getnameinfo`.

---

## 🛠 Scripts

- `scripts/test_all.sh` — Automated build+test for all 4 Python versions (3.13, 3.14, 3.13t, 3.14t). Auto-detects free-threading, runs zig unit tests, and verifies standard `test.test_asyncio` modules.

---

## Reference

- **uvloop source:** https://github.com/MagicStack/uvloop
- **Test results:** 268 internal tests + standard asyncio suite modules PASS on all 4 versions (3.13, 3.14, 3.13t, 3.14t). UDP Ping-Pong matches standard asyncio.

---

## 🔍 Profiling Results (2026-05-15)

### TCP Echo (10k iterations) — Leviathan vs asyncio

| Metric | Leviathan | asyncio | Ratio |
|--------|-----------|---------|-------|
| **Time** | 8.39s | 1.16s | **7.2× slower** |
| **CPU cycles** | 39.6B | 4.0B | 9.8× more |
| **Instructions** | 38.0B | 7.2B | **5.3× more** |
| **IPC** | 1.0 | 1.8 | 1.8× worse |
| **Backend bound** | 70.4% | 10.6% | **6.6× worse** |
| **Retiring** | 5.4% | 19.7% | 3.6× less |
| **dTLB loads** | 11.9B | 2.2B | 5.5× more |

**Root Cause:** Leviathan executes 5.3× more instructions for the same work.
70% backend-bound (memory stalls), only 5.4% useful work retiring.

**Per I/O completion cost:**
1. CQE → copy 48-byte Callback into ring buffer
2. Ring buffer drain → `callback.func()` → `PyObject_Vectorcall`
3. Coroutine yields Future → `wakeup_task` → `_execute_task_send`:
   - `PyObject_Vectorcall(_enter_task)` → `PyContext_Enter` → `PyIter_Send` → `PyContext_Exit` → `PyObject_Vectorcall(_leave_task)`
4. Future completion → same path again

Each message (read+write) triggers multiple callback dispatches, each with
Callback copy + Python crossings.

**Conclusion:** P15 Phase 1 (CompletionRecord buffer) will reduce memory traffic
by eliminating the Callback copy. However, Python boundary crossings (`PyIter_Send`,
`PyObject_Vectorcall`) remain — those are inherent to the coroutine model.
Expect 1.0-1.3× after P15, not 3×. The remaining gap is a CPython architectural limit.

---

## 🔍 Codebase Audit (2026-05-13)

| Severity | Lesson | File:Line | Bug | Status |
|----------|--------|-----------|-----|:---:|
| Medium | 10. Coroutine Cleanup | `src/task/callbacks.zig:437` | `execute_task_throw` no `data.cancelled` check | ✅ Fixed |
| High | 3. Ghost Ref Cycles (now #11) | `src/future/callback.zig:164-177` | ZigGeneric ptr invisible to GC | ✅ Fixed |
| — | 2. EINTR / No Panics | `src/callback_manager.zig:90` | `@panic("RingBuffer overflow")` on dispatch | ⚠️ Intentional guardrail — fail-fast is better than silent error here |
| Low | 10. Coroutine Cleanup | `src/loop/python/control.zig:161` | `hook_callback` no `cancelled` check | ⚠️ False positive — hooks not in `release_ring_buffer` |
| Low | 7. tp_traverse Precision | `src/future/python/constructors.zig:85` | `@alignCast` on GC path | ⚠️ WON'T FIX — needs Future struct refactor |

2 real bugs fixed, 1 intentional guardrail, 2 false-positives / won't-fix.

---

## 🔴 PRIORITY 18: Deep Audit — Lessons-Learned Scan (2026-05-17)

Full codebase scan against all 12 lessons + 6 architectural mandates. 49 files, ~8000 LOC.
Results below grouped by severity.

### 🔥 CRITICAL (4) — will crash or silently lose data

| # | Lesson | File:Line | Bug | Fix |
|---|--------|-----------|-----|-----|
| C1 | L5 Resilience | `loop/child_watcher.zig:141-144` | Child exit callback error silently dropped. `PyObject_Call` fails → exception fetched + decref'd → function returns `void` (success). User never knows their child handler crashed. | ✅ **FIXED** — Route exception to loop's `call_exception_handler`. |
| C2 | L5 Resilience | `loop/fs_watcher.zig:119-124` | Same pattern — inotify callback errors silently dropped. `PyObject_Call` returns null → `PyErr_GetRaisedException` + decref → `return`. | ✅ **FIXED** — Route exception to loop's `call_exception_handler`. |
| C3 | L5 Resilience | `transports/subprocess/transport.zig:178-185` | `.CHILD` error branch: both `process_exited` (L178) and `connection_lost` (L184) callbacks silently swallow errors with `PyErr_Clear`. Double loss. | ✅ **FIXED** — Route both to `call_exception_handler`. |
| C4 | M4 Null Discovery | `python_c.zig:266` | `obj.ob_type orelse unreachable` — In Python 3.13t free-threading, `ob_type` CAN be null during concurrent deallocation. Used from dozens of call sites (`is_type`, `type_check`, `long_check`, etc.). | ✅ **FIXED** — `get_type` returns `?*PyTypeObject`, all 9 callers guard with `orelse return`/`orelse return error.PythonError`. |

### 🔶 HIGH (10) — will break under load or leak memory

| # | Lesson | File:Line | Bug | Fix |
|---|--------|-----------|-----|-----|
| H1 | M1 No Panics | `callback_manager.zig:90` | `@panic("RingBuffer overflow")` on static `RingBuffer(N)`. Burst of >524288 callbacks → SIGABRT. No grow mechanism on the static buffer used by `Soon.dispatch`. | ⚠️ Intentional guardrail — production uses `DynamicRingBuffer.push_or_grow()` which auto-grows. Static `RingBuffer(N)` only in unit tests. |
| H2 | M2 EINTR | `loop/runner.zig:248,252,261` | `ring.copy_cqes()` not EINTR-protected. Signal during CQE harvest → error propagates → event loop crashes. 3 unprotected call sites. | ✅ **FIXED** — wrapped in `copy_cqes_eintr_safe()` with `SignalInterrupt` retry loop. |
| H3 | L3 Ghost Refs | `transports/subprocess/transport.zig:9-21` | `SubprocessTransportObject`: 4 PyObject fields (`loop`, `protocol`, `popen`, `returncode`), no `tp_traverse`, no `HAVE_GC`. Cyclic ref through subprocess transport = permanent leak. | ✅ **FIXED** — added `tp_traverse`, `tp_clear`, `HAVE_GC` flag, `PyObject_GC_UnTrack` in dealloc. |
| H4 | L3 Ghost Refs | `loop/unix_signals.zig:17` | `UnixSignals.callbacks` BTree stores PyObject refs in `callback.data.user_data`. Never traversed by `loop_traverse`. Signal handler callbacks are ghost refs from GC's perspective. | ✅ **FIXED** — added `UnixSignals.traverse()` with btree node walk; guarded with `fd < 0` for uninitialized state; called from `loop_traverse`. |
| H5 | L3 Ghost Refs | `future/main.zig:17` | `exceptions_queue: ArrayList(?*PyObject)` not traversed by `future_traverse`. Exception refs from `ExceptionGroup` aggregation invisible to GC. | ✅ **FIXED** — added traversal of `exceptions_queue.items` in `future_traverse`. |
| H6 | M3 Thread Safety | `loop/scheduling/soon.zig:22-28` | `dispatch_guaranteed_nonthreadsafe` doesn't check `ring_blocked` / write eventfd. Callbacks dispatched while loop is blocked → loop sleeps forever waiting for IO that may never arrive. | ✅ **FIXED** — added `ring_blocked` check + `wakeup_eventfd()` call. |
| H7 | L5 Resilience | `transports/stream/lifecycle.zig:61-62,69-70` | `connection_lost` callback errors silently dropped in `close_transports`. Both `PyObject_CallOneArg` failures cleared with `PyErr_Clear`. | ✅ **FIXED** — route errors to loop's `call_exception_handler` via context dict. |
| H8 | L10 Cancelled | `transports/write_transport.zig:109` | `flush_buffered_writes` prepare hook missing `data.cancelled` guard. During shutdown, called from `execute_hooks` → queues IO to deinitialized ring. | ✅ **FIXED** — added `if (data.cancelled) return;` at top. |
| H9 | L10 Cancelled | `transports/read_transport.zig:122` | `read_operation_completed` missing proper `data.cancelled` early-exit. Only skips `bytes_read` calculation (L132), still calls Python read callback + touches transport state. | ✅ **FIXED** — added `if (data.cancelled) { cleanup_resources_callback(data.user_data); return; }` at top. |

### 🟡 MEDIUM (5) — fragile, could bite later

| # | Lesson | File:Line | Bug | Fix |
|---|--------|-----------|-----|-----|
| M1 | L10 Cancelled | `loop/python/control.zig:161` | `hook_callback` missing `data.cancelled` guard. During shutdown, `execute_hooks` calls arbitrary Python code on a potentially torn-down loop. | ✅ **FIXED** — added `if (data.cancelled) { py_decref(handle); return; }`. |
| M2 | L3 Ghost Refs | `loop/python/control.zig:126-132` | `HookHandle.callback`: separate `py_newref` on callback object. When hook is unlinked from HooksList, this ref becomes invisible to GC. | ✅ **FIXED** — added `tp_traverse` + `HAVE_GC` flag to `HookHandleType`. |
| M3 | L3 Ghost Refs | `loop/python/control.zig:198-203` | `PathWatcherHandle.callback`: same pattern as HookHandle. Separate incref invisible when watcher removed from FSWatcher. | ✅ **FIXED** — added `tp_traverse` + `HAVE_GC` flag to `PathWatcherHandleType`. |
| M4 | M4 Null Discovery | `transports/datagram/write.zig:191` | `args[1].?` evaluated before `is_none` check. If `args[1]` is null, `.?` crashes before `is_none` can return false. | ✅ **FIXED** — added `args[1] != null` guard before `.?` unwrap. |
| M5 | L5 Resilience | `loop/runner.zig:147-153` | `execute_hooks` uses `try` — single failing hook (e.g. `flush_buffered_writes`) propagates error → kills the event loop. | ✅ **FIXED** — changed `try` to `catch continue` per-hook. |

### 🟢 LOW / INFO (3) — defense-in-depth, not high priority

| # | Lesson | File:Line | Bug | Fix |
|---|--------|-----------|-----|-----|
| L1 | L12 Ring FD | `loop/scheduling/io/main.zig:382` | `register_fixed_file()` lacks `ring.fd >= 0` guard. If called after `io.deinit()`, `register_files_update` will assert-fail. Currently protected by Python layer preventing new connections on stopped loop. | ✅ **FIXED** — added `if (self.ring.fd < 0) return error.LoopDeinitialized;` guard. |
| L2 | L2 EINTR | `loop/scheduling/io/main.zig:414` | Eventfd write discards return value via `_ =`. EINTR before the atomic 8-byte write could theoretically lose a wakeup (rare). | ✅ **FIXED** — retry loop on EINTR, return on any other error. |
| L3 | L2 EINTR | `loop/child_watcher.zig:104` | `waitid` with WNOHANG: EINTR causes re-arm cycle where the pidfd read is queued again. Not crashy but wastes one io_uring cycle per signal. | ✅ **FIXED** — immediate retry on EINTR inside a `while(true)` loop. |

### ✅ What's Clean

The scan also confirmed these areas are properly handled:

| Lesson | Finding |
|--------|---------|
| L6 Stack | No `var loop: Loop = undefined;` on the stack. ~42MB struct always heap-allocated via `LoopObject`. All `self.* = .{...}` patterns on small structs. |
| L7 @alignCast | Both instances in traverse functions (`future/python/constructors.zig:85`, `future/callback.zig:168`) are safe — restoring known types from opaque pointers. |
| L10 Cancelled | 44/47 production callbacks properly handle `data.cancelled`. Only 3 missing (H8, H9, M1 above). |
| L5 Dispatch | `execute_ring_buffer` / `execute_dynamic_ring_buffer` correctly catch errors, route to exception handler, check for KeyboardInterrupt/SystemExit, and continue. |
| L5 Task Errors | All task callbacks (`execute_task_send`, `execute_task_throw`, etc.) use `handle_zig_function_error` properly. |
| L1 Atomic Sleep | `should_wait` evaluated AFTER flush, inside mutex. `ring_blocked` set before dropping GIL. Eventfd write after push. Correct pattern. |
| M3 Atomics | Ring buffer read/write indices use `@atomicLoad`/`@atomicStore` with `.acquire`/`.release`. `BlockingTasksSet.index` correctly synchronized. |
| M5 Init Order | All collection insertions initialize data before advancing index/linking node. GC-safe ordering throughout. |

### Summary

| Severity | Count | Impact |
|----------|:-----:|--------|
| CRITICAL | 4 | Silently lost Python errors, crash in free-threading |
| HIGH | 10 | Memory leaks under load, loop crashes on signals, shutdown crashes |
| MEDIUM | 5 | GC blind spots, fragile null handling, loop-killing hook errors |
| LOW | 3 | Defense-in-depth gaps, no current crash risk |
| **Total** | **22** | |
