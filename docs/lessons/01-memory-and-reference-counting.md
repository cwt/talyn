[⬅️ Back to Lessons Index](../lessons-learned.md)

# Memory & Reference Counting

Lessons about Python C API reference management, GC traversal, use-after-free, double-free, and struct lifecycle.

---

### Ghost References & GC Traversal

**Core rule:** Any native structure holding a `PyObject*` **must** be reachable via `tp_traverse`. Skipping even one arm of a traversal union breaks the cycle detector.

**Lesson 3 — Ghost Reference Cycle (GC invisibility)**
Holding Python objects inside native Zig collections (`std.ArrayList`, BTree, etc.) without `tp_traverse` creates "Ghost References" invisible to the GC.
- **Bug:** Loop → Task → Future → callback → Loop cycle, all in Zig memory, leading to 30GB+ OOM.
- **Lesson:** Any native structure holding a `PyObject` **must** be reachable via `tp_traverse`. Standard reference counting alone is insufficient for event loops.

**Lesson 4 — Safe Traversal of Execution Queues**
Updating a progress marker *after* an operation is standard, but for GC safety it must be **precise**.
- **Bug:** GC ran while a callback was halfway through a queue, visiting already-decref'd objects.
- **Lesson:** Immediately nullify references or update the traversal `offset` as each item is consumed. GC and execution are concurrent in free-threading — there is no "safe time" for invalid pointers.

**Lesson 7 — Precision in Typed Traversal**
`@alignCast` on `?*anyopaque` during `tp_traverse` is a common source of non-deterministic panics.
- **Bug:** `MultiConnectState.traverse_raw` used `@alignCast(@ptrCast(ptr))`, failing under memory pressure.
- **Lesson:** Avoid `@alignCast` in hot GC paths. Refactor to take typed pointers directly; cast only once at the boundary.

**Lesson 11 — Ghost Reference Cycle in Future Callbacks**
`ZigGeneric` callbacks held task pointers invisible to GC.
- **Bug:** `traverse_callbacks_queue` had a no-op `ZigGeneric` arm — GC couldn't see the `Task ← Future` cycle, causing OOM on long-running processes.
- **Fix:** The `ZigGeneric` arm now calls `visit(ptr)` to expose the Task pointer to the GC.
- **Lesson:** Any native structure holding a `PyObject*` must be reachable via `tp_traverse`. Every arm of a traversal union must call `visit`.

**Lesson 14 — Gap in `deinitialize_object_fields` for Optional PyObject-Compatible Structs**
`deinitialize_object_fields()` silently skipped `?*FutureObject` and `?*LoopObject` fields.
- **Bug:** `SocketCreationData` had `future: ?*FutureObject` and `loop: ?*LoopObject` — never decref'd.
- **Lesson:** `deinitialize_object_fields` and `verify_gc_coverage` are **not symmetric**. Always verify that deinit actually decrefs what traverse visits. Write targeted manual decrefs when the generic function has gaps.

---

### Reference Count Discipline

**Core rule:** Track ownership at every call boundary. "Who creates the reference, who consumes it, who releases it?"

**Lesson 30 — Double Incref in `Future.set_exception`**
`z_future_set_exception` called `py_newref(exception)` before passing it to `future_fast_set_exception`, which also called `py_newref` internally — two increments, one store.
- **Lesson:** When a function takes ownership via `py_newref`, all callers must pass raw borrowed references. Use `sys.getrefcount()` tests to verify discipline for frequently-called APIs.

**Lesson 36 — Reference Leak in `Future.get_result` with Exception**
`get_result` called `py_newref(exc)` before passing to `PyErr_SetRaisedException`, which **steals** a reference.
- **Lesson:** `PyErr_SetRaisedException`, `PyTuple_SetItem`, and `PyList_SetItem` steal references. Do **not** call `py_newref` before passing to a stealing API — transfer the reference you already hold directly.

**Lesson 37 — Reference Leak in `Future.cancel(msg=...)`**
`parse_vector_call_kwargs` created a new reference for `msg`; `future_fast_cancel` also created its own — the caller's was never released on the success path.
- **Lesson:** Trace the ownership chain completely. When the callee creates its own reference internally, the caller must release its own after the call, on **both** success and error paths.

**Lesson 38 — Reference Leak in `Task.set_name()`**
`instance.name = PyObject_Str(name)` overwrote the old name without decref'ing it first.
- **Lesson:** Setter pattern: `py_xdecref(old_value); field = new_value;`. Always release the old reference before storing a new one.

**Lesson 39 — Reference Leak in `cancel_future_waiter` for Future Path**
An unnecessary `py_xincref` before calling `future_fast_cancel`, which already increfs internally.
- **Lesson:** When calling a function that borrows and internally increfs its argument, do NOT pre-incref the argument. Check the callee's implementation to understand its contract.

**Lesson 52 — `PyModule_AddObject` Steals References — Don't Also Decref**
`module_cleanup` called `py_decref` on types already owned by the module after `PyModule_AddObject`, causing refcount underflow.
- **Lesson:** `PyModule_AddObject` (like `PyTuple_SetItem`, `PyList_SetItem`) steals the reference. Never decref the object afterward — the module owns it. The correct pattern: either don't decref in cleanup, or `Py_INCREF` before `AddObject` to keep a separate ref.

**Lesson 18 — Python Reference Leaks in Future Done Callbacks**
Cancelled callbacks in `callbacks_queue` were skipped during execution but never decref'd.
- **Fix:** Accept `*CallbacksSetData`, check `if (callback.executed) continue`, mark `executed = true` immediately after freeing. Always call `release_callbacks_queue` in `Future.release` regardless of status.
- **Lesson:** Callback release logic must be completely **idempotent** and track execution state to allow multiple passes. Unexecuted callback references must always be released during resource deallocation.

---

### Use-After-Free & Double-Free

**Lesson 15 — Timer-Triggered Use-After-Free with Deferred Deinit**
`schedule_remaining_connects_callback` stored a `mcs` pointer. If all connects failed before the timer fired, `mcs.deinit()` freed it. Timer CQE then dispatched the callback with a dangling pointer.
- **Fix:** Store timer task ID for cancellation; defer `deinit` until the timer callback runs.
- **Lesson:** Any callback that outlives its `user_data` allocation must be cancellable. Cancel **before** freeing. If cancellation fails (already in-flight), defer freeing until the callback runs.

**Lesson 25 — Borrowed Reference Memory Corruption in `get_extra_info`**
Transport returned cached `PyObject*` without incrementing refcount (borrowed ref). Python decremented it, causing premature deallocation.
- **Fix:** Use `python_c.py_newref(py_sockname)` when returning cached objects.
- **Lesson:** Any native API returning a cached CPython object must return a **new** reference. Borrowing cached references that Python will later decref is a direct path to memory corruption.

**Lesson 26 — Double-Free and Struct Leak in Datagram `sendto` Error Path**
Two identical `errdefer allocator.free(data_buf)` statements caused double-free; `SendToData` struct leaked.
- **Lesson:** Audit duplicate `errdefer` blocks carefully. Each step's `errdefer` must clean up exactly what **that step** allocated.

**Lesson 46 — `RegisteredBufferPool.release()` Has No Overflow Guard**
Double-release caused `free_count` to exceed array bounds, corrupting heap.
- **Fix:** Added `if (self.free_count >= SlotCount) return;` guard.
- **Lesson:** Always validate you're not exceeding capacity before adding items back to a free list. Double-release bugs cause severe memory corruption. Defensive bounds checks prevent security vulnerabilities.

**Lesson 89 — Don't Reinvent the Wheel — Use the Standard Library**
A heuristic check `@intFromPtr(op) <= 0xFFFF` in `py_incref`/`py_decref` skipped refcount operations for what was assumed to be singletons. CPython's singletons are at high addresses, not low.
- **Lesson:** `Py_IncRef`/`Py_DecRef` are safe to call on all valid objects including `None/True/False`. Don't write custom optimization heuristics around standard library APIs without verifying all platform assumptions.

---

### Struct Initialization & Uninitialized Fields

**Lesson 6 — Stack Allocation of Large Structures**
Initializing a large struct via literal `self.* = .{...}` or returning it from a function causes silent `SIGSEGV` (stack overflow) if it's a multi-megabyte struct.
- **Lesson:** Always use in-place initialization (`init(self: *Self)`) and individual field assignments for large structures. Heap-allocate in unit tests.

**Lesson 49 — Uninitialized Struct Field via `allocator.create` + Field-by-Field Assignment**
`allocator.create(ControlData)` returns raw uninitialized memory. A new `record_evicted: bool` field added to `ControlData` was never assigned in the field-by-field init sequence — garbage bytes in Release builds caused `record_evicted` to read as `true`.
- **Fix:** Replaced field-by-field assignment with a struct literal: `control_data.* = ControlData{ .field = value, ... }`. The Zig compiler emits a **compile error** if any field is missing.
- **Lesson:** `allocator.create(T)` returns **uninitialised memory**. Struct field defaults (e.g., `field: bool = false`) are **only applied when using a struct literal**. Always use a struct literal for heap-allocated structs so the compiler enforces completeness. Use `undefined` only for fields provably assigned before any read.

**Lesson 50 — Stale `CompletionRecord` Detection via Generation Counter**
Raw pointer caching in `CompletionRecord` could dereference dangling pointers if a transport closed between push and dispatch.
- **Fix:** Added per-transport `dispatch_generation: u64` counter, stored snapshot at push time, check at dispatch time (`@atomicLoad`/`@atomicStore`).
- **Lesson:** Cache raw pointers in async queues must guard against the target being freed between push and pop. Generation counters (single `u64`, atomic release/acquire ordering) are a robust, lock-free pattern. **Always initialise the counter explicitly in every constructor** — struct-literal defaults don't apply to `tp_alloc` + field-by-field init paths.
