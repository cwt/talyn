[⬅️ Back to Lessons Index](../lessons-learned.md)

# Python C API Correctness

Lessons about exception handling, context management, NULL return checks, reference ownership contracts, and CPython internals.

---

### Setting Exceptions — Never Return NULL Without One

**Lesson 27 — Setting Python Exceptions on Type/Value Verification**
Returning `error.PythonError` (or a `NULL` PyObject) in native code without calling `raise_python_type_error` / `raise_python_value_error` first causes CPython to raise a fatal `SystemError: <method ...> returned NULL without setting an exception`.
- **Lesson:** Never return `error.PythonError` (or a `NULL` PyObject) without ensuring a Python-level exception has been set via `PyErr_SetString` (or `raise_python_*` wrappers). Any un-exceptioned NULL return results in a fatal interpreter-level `SystemError`.

**Lesson 95 — Always Check `PyErr_Occurred` After Python C API Calls That Can Fail**
`PyLong_AsLong(py_fd)` returns `-1` and sets a Python exception on failure. The code used the return value directly with `@intCast`, leaving the Python exception pending and treating `-1` as a valid fd.
- **Fix:** After every `PyLong_AsLong` call, check `python_c.PyErr_Occurred()`. If non-null, return `error.PythonError`.
- **Lesson:** For any function that returns a sentinel value (NULL, -1, 0) and sets an error indicator (errno, `PyErr`, `GetLastError`), **always check the failure signal before using the return value**. Pattern:
  - `n = PyLong_AsLong(o); if (PyErr_Occurred()) return -1;`
  - `o = PyObject_GetAttrString(...); if (o == NULL) return NULL;`
  - `r = PyObject_Call(...); if (r == NULL) return NULL;`

**Lesson 54 — Always Check `?*PyObject` Return Values, Even When "Steering" with `try`**
Three call sites passed the result of `PyLong_FromLong(...)` directly to `future_fast_set_result` using `try`. The `try` keyword only catches errors from `future_fast_set_result`, **not** from `PyLong_FromLong` (which returns `?*PyObject`, not an error union). If `PyLong_FromLong` returned `null`, `future_fast_set_result` received `null` and segfaulted.
- **Fix:** Capture the result, check for null with `orelse`, propagate as a future exception.
- **Lesson:** Zig has **two distinct "can fail" representations**:
  - `?T` (optional) — use `orelse` to handle null.
  - `error{T}!T` (error union) — use `try` to propagate errors.
  The `try` keyword does **nothing** for optionals. Every C Python API function that returns `?*PyObject` must be handled with `orelse`, never assumed to succeed. Capture → check → use; never pass directly as a function argument.

---

### CPython Context Management

**Lesson 28 — Context Stack Leak on Callback Execution Error**
In `callback_for_python_generic_callbacks`, `PyContext_Enter(py_context)` was called but, on any subsequent failure, the function returned `error.PythonError` without calling `PyContext_Exit`. This permanently corrupted the current thread's context variable stack.
- **Fix:** Added `defer _ = python_c.PyContext_Exit(py_context);` immediately after the successful `PyContext_Enter`. Zig's `defer` ensures cleanup on all exit paths.
- **Lesson:** When acquiring a reversible resource (like entering a CPython context), always use `defer` to guarantee cleanup on all exit paths. Manual cleanup before each `return` is fragile and inevitably misses edge cases. `PyContext_Enter`/`PyContext_Exit` pairs are particularly dangerous because a leaked entry corrupts global interpreter state for all subsequent operations.

**Lesson 32 — Defer Ordering and Incomplete Cleanup in Callback Execution**
Adding `defer py_decref(handle)` after the context defer created a use-after-free: Zig defers execute in LIFO order, so the handle was decref'd BEFORE the context was exited, but the handle holds the context reference.
- **Fix:** Declare defers in the correct order:
  ```zig
  defer python_c.py_decref(@ptrCast(handle));  // declared first, runs LAST
  defer _ = python_c.PyContext_Exit(py_context); // declared second, runs FIRST
  ```
- **Lesson:** Zig's `defer` statements execute in **LIFO (Last In, First Out) order**. When multiple defers have dependencies (object A holds a reference to object B), the defer that should run LAST must be declared FIRST. Always verify defer ordering when cleaning up interdependent resources. Partial cleanup is worse than no cleanup — it creates subtle use-after-free bugs harder to debug than obvious leaks.

**Lesson 35 — Context Leak in Task Throw Execution**
In `_execute_task_throw`, `PyContext_Enter` was called before `PyObject_GetAttrString(task.coro, "throw")`. If the attribute lookup failed, the function returned without calling `PyContext_Exit`.
- **Lesson:** This is the same pattern as Lesson 28 in a different code path. When entering a CPython context, ensure `PyContext_Exit` is called on **ALL** exit paths, including early returns. Always audit every `return` statement after `PyContext_Enter`. Using `defer` is the safest approach.

---

### Exception Swallowing

**Lesson 97 — Never Silently Swallow Exceptions**
14 SSL protocol callbacks used `except Exception: pass`, silently dropping exceptions from user protocol methods (`connection_lost`, `data_received`, etc.) — impossible to debug.
- **Fix:** Replaced all 14 `pass` statements with `logger.exception("Unhandled exception in event loop callback")`.
- **Lesson:** Never use `except Exception: pass`. If you must swallow an exception (to prevent the event loop from crashing), always log it first with the full traceback. Pattern:
  - **Silent swallow** (`pass`) — exception is lost, no record.
  - **Log and swallow** (`logger.exception(...)`) — recorded, debuggable.
  - **Re-raise** (`raise`) — propagates, may crash the loop.
  The "silent swallow" anti-pattern is the worst kind of bug because the code "works" but produces wrong results.

---

### Practical Ownership Quick Reference

| API | Ownership Semantics |
|-----|---------------------|
| `PyModule_AddObject` | Steals reference on success |
| `PyTuple_SetItem` | Steals reference |
| `PyList_SetItem` | Steals reference |
| `PyErr_SetRaisedException` | Steals reference |
| `Py_IncRef` / `Py_DecRef` | No stealing |
| `PyObject_GetAttrString` | Returns new reference |
| `PyObject_Call` | Returns new reference |
| `PyLong_FromLong` | Returns new reference or NULL |
| `py_newref` (talyn wrapper) | Returns new reference |
