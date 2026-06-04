[⬅️ Back to Lessons Index](../lessons-learned.md)

# Zig-Specific Patterns

Lessons about Zig idioms: `errdefer` discipline, struct literal initialization, `defer` ordering, alignment for C struct mappings, const-folding, and the `?T` vs `error{T}!T` distinction.

---

### Struct Initialization

**Lesson 49 — Always Use Struct Literals for Heap-Allocated Structs**
`allocator.create(T)` returns **uninitialised memory**. Field defaults (e.g., `field: bool = false`) are only applied in struct literals. Field-by-field assignment after `create` silently leaves any newly-added fields uninitialized — in Debug builds, Zig fills with `0xaa`; in Release builds, bytes are unpredictable heap data.
- **Lesson:** Always use a struct literal (`ptr.* = T{ .field = value, ... }`) for heap-allocated structs. The compiler emits a **compile error** if any field is missing. Use `undefined` only for fields provably assigned before any read.

**Lesson 50 (cross-reference)** — Always initialize generation counters explicitly in every constructor/init path. Struct-literal defaults don't apply to `tp_alloc` + field-by-field assignment. See [Memory & Reference Counting](01-memory-and-reference-counting.md).

---

### `errdefer` — Resource Cleanup Discipline

**Lesson 77 — `errdefer` After Every Resource Acquisition**
In `create_server`, the fd was duplicated with `dup()` so `StreamServer` owned its own copy. The original `errdefer` only cleaned up `address_list` — not the dup'd fd. If any subsequent operation failed after the dup, the fd would leak.
- **Fix:** Added `errdefer _ = std.os.linux.close(server_data.socket_fd);` immediately after the dup succeeds.
- **Lesson:** Add an `errdefer` immediately after **every** resource acquisition:
  1. Acquire resource R.
  2. Add `errdefer cleanup(R);` immediately.
  3. Continue with code that might fail.
  This applies to file descriptors, heap allocations, locks, database transactions, and reference counts. The "I added the errdefer later" anti-pattern is a common source of leaks.

**Lesson 88 — Cleanup on Every Error Path**
In `PyInit_talyn_zig`, if `initialize_talyn_types` succeeded but `initialize_python_module` failed, the type-initialization side effects were never cleaned up — a classic partial-init leak from a chain of `catch return null` calls.
- **Lesson:** The chain `a() catch return null; b() catch return null; c() catch return null;` is a leak waiting to happen. When `c()` fails, both X (from `a()`) and Y (from `b()`) leak. Fix with:
  1. `errdefer cleanup_a();` immediately after each acquisition.
  2. Explicit `if-else` blocks.
  3. RAII/ScopeGuard patterns.

---

### `defer` Ordering

**Lesson 32 — Defer Ordering and Incomplete Cleanup**
Zig's `defer` statements execute in **LIFO (Last In, First Out)** order. Adding `defer py_decref(handle)` before `defer PyContext_Exit(py_context)` caused the handle to be decref'd before the context was exited — the handle holds the context reference.
- **Lesson:** When multiple defers have dependencies (A holds a reference to B), the defer that should run LAST must be declared FIRST. Always verify defer ordering when cleaning up interdependent resources.

---

### Optional vs Error Union

**Lesson 54 — `?T` vs `error{T}!T` — The `try` Keyword Only Works on Error Unions**
Passing `PyLong_FromLong(...)` (which returns `?*PyObject`) directly inside a `try` expression does nothing for the null case — `try` only propagates `error union` failures, not `optional` nulls.
- **Lesson:**
  ```zig
  // WRONG: `try` does nothing for an optional.
  const x = try someFuncReturningOptional();

  // RIGHT: capture, then `orelse` to handle null.
  const x = someFuncReturningOptional() orelse return error.Failed;
  ```
  Every C Python API function that "may return NULL" must be handled with `orelse`, not `try`. Capture into a `const`, check `orelse`, then use it — never pass directly as a function argument.

**Lesson 55 — `.?` Unwrap-Else-Panic Is Almost Never Correct in Concurrent Code**
Zig's `.?` operator panics when the optional is null — appropriate for truly impossible states, dangerous for concurrent state lookups where the target can be removed between the trigger and dispatch.
- **Lesson:** **Any time you write `.?` on a `?T` returned by a lookup function, ask: "can this lookup fail at runtime?"** If yes, use `orelse`. In event loops, a panic in a callback is unrecoverable — always handle lookup-failure cases explicitly.

---

### Alignment for C-Struct Mappings

**Lesson 102 — Aligning Python C-Mappings for LLVM Vectorization**
Under `ReleaseFast`, the compiler aggressively vectorized read/write patterns for Python transport and future structures. Fields mapped to Python objects lacked explicit alignment declarations, causing `movdqa` (aligned vector move) violations on unaligned structures — segfaults only in `ReleaseFast` mode.
- **Fix:** Added explicit alignment declarations using `@alignOf(PyObject)` or matching structures on fields inside `src/future/python/main.zig`, `src/transports/datagram/main.zig`, and `src/transports/stream/main.zig`.
- **Lesson:** When matching C-structures (like Python's custom objects) within Zig, do not rely on implicit alignment. `ReleaseFast` vectorizers assume standard pointer alignment and emit aligned instruction variants. Always explicitly declare alignments matching the target C structures.

**Lesson 103 — Const Declarations and Type Folding**
Type specifications/descriptors (`loop_spec`, `datagram_spec`, `stream_spec`) were declared as `const`. Under `ReleaseFast` LLVM aggressively folded these descriptors, resulting in missing or incorrectly optimized type checks at runtime.
- **Fix:** Changed specifications to `var` declarations, preventing the compiler from statically const-folding them.
- **Lesson:** Type descriptors or registry configurations meant to interact with dynamic runtime environments (like Python's C API type registration) should be declared as `var` if the optimizer could aggressively fold or prune them. Const-correctness is good, but `const` in Zig gives LLVM license to fold at compile time.

---

### C-String vs Length-Based APIs

**Lesson 87 — Don't Mix C-String and Length-Based String APIs**
`std.fmt.allocPrint` with format string `"Talyn.Task_{x:0>16}\x00"` produced a `[]u8` slice whose length included the null terminator. `PyUnicode_FromStringAndSize(ptr, len)` then created a Python string with an embedded NUL byte.
- **Fix:** Removed the `\x00` from the format string. `PyUnicode_FromStringAndSize` takes explicit length — a null terminator is unnecessary and harmful.
- **Lesson:** C strings use a null terminator to mark the end. Length-based strings (Python's `PyUnicode_FromStringAndSize`, Rust's `&str`, Zig's `[]u8`) use an explicit length. Mixing them causes embedded NUL bytes (C string + length API) or missing terminators (length string + C API). Always know which API you're using.
