const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const PyTypeObject = *python_c.PyTypeObject;

const std = @import("std");
const Atomic = std.atomic.Value;

pub var asyncio_module: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var sys_module: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var weakref_module: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var socket_module: Atomic(?PyObject) = Atomic(?PyObject).init(null);

pub var socket_class: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var base_event_loop: Atomic(?PyObject) = Atomic(?PyObject).init(null);

pub var asyncio_protocol: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var asyncio_buffered_protocol: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var asyncio_datagram_protocol: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var asyncio_subprocess_protocol: Atomic(?PyObject) = Atomic(?PyObject).init(null);

pub var asyncio_transport: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var asyncio_datagram_transport: Atomic(?PyObject) = Atomic(?PyObject).init(null);

pub var invalid_state_exc: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var cancelled_error_exc: Atomic(?PyObject) = Atomic(?PyObject).init(null);

pub var set_running_loop: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var enter_task_func: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var leave_task_func: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var py_enter_task_func: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var py_leave_task_func: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var py_current_task_func: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var register_task_func: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var py_register_task_func: Atomic(?PyObject) = Atomic(?PyObject).init(null);

pub var get_asyncgen_hooks: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var set_asyncgen_hooks: Atomic(?PyObject) = Atomic(?PyObject).init(null);

pub var py_af_inet: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var py_af_inet6: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var py_af_unix: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var py_sock_stream: Atomic(?PyObject) = Atomic(?PyObject).init(null);
pub var py_sock_dgram: Atomic(?PyObject) = Atomic(?PyObject).init(null);

pub fn get(comptime name: []const u8) PyObject {
    return @field(@This(), name).load(.acquire).?;
}

/// Register a talyn task in asyncio's task registries so `asyncio.all_tasks()`
/// sees it (BUG-268). Covers both the C registry (the default `all_tasks`)
/// and the pure-Python `_scheduled_tasks` WeakSet (`_py_all_tasks`). Both
/// registries are weak/self-cleaning on completion, so no unregister is
/// needed. Registration is best-effort: errors are cleared because a missing
/// registry must never fail task creation.
pub fn register_asyncio_task(task: PyObject) void {
    // P23 stage 2: with the accelerator present, the C `_register_task` alone
    // maintains the asyncio task registries — the pure-Python registrar frame
    // (~300-600 ns per task) was the bulk of the v0.9.x task-spawn regression
    // (docs/development/priorities/23-...md). The dual-registry contract
    // (tests/test_task_registry.py: visible in BOTH the _asyncio registry and
    // asyncio.tasks._py_all_tasks) is satisfied by binding `asyncio.tasks.
    // _py_all_tasks` to the accelerator's all_tasks at init (see
    // initialize_python_imports) — zero per-task Python work while both
    // readers see every pending talyn task. When the accelerator is ABSENT,
    // the pure-Python registrar is used (BUG-398 fallback semantics).
    if (register_task_func.load(.acquire)) |func| {
        if (python_c.PyObject_CallOneArg(func, task)) |ret| {
            // BUG-373: the registrar's return value (Py_None or a patched
            // result) is owned — it was discarded, leaking one reference
            // per task registration.
            python_c.py_decref(ret);
        } else {
            python_c.PyErr_Clear();
        }
        return;
    }
    // Only the pure-Python registry exists (no C accelerator) —
    // register the task there so asyncio.all_tasks() sees it.
    if (py_register_task_func.load(.acquire)) |func| {
        if (python_c.PyObject_CallOneArg(func, task)) |ret| {
            python_c.py_decref(ret);
        } else {
            python_c.PyErr_Clear();
        }
    }
}

pub fn initialize_python_imports() !void {
    errdefer release_python_imports();
    const a_mod = python_c.PyImport_ImportModule("asyncio\x00") orelse return error.PythonError;
    asyncio_module.store(a_mod, .release);
    const s_mod = python_c.PyImport_ImportModule("sys\x00") orelse return error.PythonError;
    sys_module.store(s_mod, .release);
    weakref_module.store(python_c.PyImport_ImportModule("weakref\x00") orelse return error.PythonError, .release);
    socket_module.store(python_c.PyImport_ImportModule("socket\x00") orelse return error.PythonError, .release);

    base_event_loop.store(python_c.PyObject_GetAttrString(a_mod, "AbstractEventLoop\x00") orelse return error.PythonError, .release);

    socket_class.store(python_c.PyObject_GetAttrString(socket_module.load(.acquire).?, "socket\x00") orelse return error.PythonError, .release);

    invalid_state_exc.store(python_c.PyObject_GetAttrString(a_mod, "InvalidStateError\x00") orelse return error.PythonError, .release);
    cancelled_error_exc.store(python_c.PyObject_GetAttrString(a_mod, "CancelledError\x00") orelse return error.PythonError, .release);

    asyncio_protocol.store(python_c.PyObject_GetAttrString(a_mod, "Protocol\x00") orelse return error.PythonError, .release);
    asyncio_buffered_protocol.store(python_c.PyObject_GetAttrString(a_mod, "BufferedProtocol\x00") orelse return error.PythonError, .release);
    asyncio_datagram_protocol.store(python_c.PyObject_GetAttrString(a_mod, "DatagramProtocol\x00") orelse return error.PythonError, .release);
    asyncio_subprocess_protocol.store(python_c.PyObject_GetAttrString(a_mod, "SubprocessProtocol\x00") orelse return error.PythonError, .release);

    asyncio_transport.store(python_c.PyObject_GetAttrString(a_mod, "Transport\x00") orelse return error.PythonError, .release);
    asyncio_datagram_transport.store(python_c.PyObject_GetAttrString(a_mod, "DatagramTransport\x00") orelse return error.PythonError, .release);

    set_running_loop.store(python_c.PyObject_GetAttrString(a_mod, "_set_running_loop\x00") orelse return error.PythonError, .release);
    enter_task_func.store(python_c.PyObject_GetAttrString(a_mod, "_enter_task\x00") orelse return error.PythonError, .release);
    leave_task_func.store(python_c.PyObject_GetAttrString(a_mod, "_leave_task\x00") orelse return error.PythonError, .release);
    register_task_func.store(python_c.PyObject_GetAttrString(a_mod, "_register_task\x00") orelse return error.PythonError, .release);


    // The pure-Python registry aliases (_scheduled_tasks WeakSet / the
    // _current_tasks dict). They are what asyncio.all_tasks()/current_task()
    // read when the C accelerator is absent or when the registries are
    // explicitly switched back (e.g. the stdlib free-threading tests). The
    // task registry is weak/self-cleaning on completion, so tasks only need
    // to be registered at creation — see BUG-268.
    {
        const tasks_mod = python_c.PyImport_ImportModule("asyncio.tasks\x00") orelse return error.PythonError;
        defer python_c.py_decref(tasks_mod);
        py_register_task_func.store(python_c.PyObject_GetAttrString(tasks_mod, "_py_register_task\x00") orelse return error.PythonError, .release);
        py_enter_task_func.store(python_c.PyObject_GetAttrString(tasks_mod, "_py_enter_task\x00") orelse return error.PythonError, .release);
        py_leave_task_func.store(python_c.PyObject_GetAttrString(tasks_mod, "_py_leave_task\x00") orelse return error.PythonError, .release);
        py_current_task_func.store(python_c.PyObject_GetAttrString(tasks_mod, "_py_current_task\x00") orelse return error.PythonError, .release);

        // P23: when the accelerator is present, bind `asyncio.tasks._py_all_tasks`
        // to the accelerator's `asyncio.all_tasks` as a pure-registry view. The
        // BUG-268 contract (tests/test_task_registry.py) requires tasks to be
        // visible in BOTH registries; with the view-bound registry, every pending
        // talyn task (registered once, natively, through the C registrar) is
        // visible through both readers with ZERO per-task Python work — the
        // pure-Python registrar frame is only needed when the accelerator is
        // absent (BUG-398 fallback, see register_asyncio_task).
        if (register_task_func.load(.acquire) != null) {
            const accel_all_tasks = python_c.PyObject_GetAttrString(a_mod, "all_tasks\x00") orelse return error.PythonError;
            defer python_c.py_decref(accel_all_tasks);
            // PyObject_SetAttrString stores its own reference to the value;
            // our borrowed reference is released by the deferred decref.
            if (python_c.PyObject_SetAttrString(tasks_mod, "_py_all_tasks\x00", accel_all_tasks) < 0) {
                python_c.PyErr_Clear();
            }
        }
    }

    get_asyncgen_hooks.store(python_c.PyObject_GetAttrString(s_mod, "get_asyncgen_hooks\x00") orelse return error.PythonError, .release);
    set_asyncgen_hooks.store(python_c.PyObject_GetAttrString(s_mod, "set_asyncgen_hooks\x00") orelse return error.PythonError, .release);

    py_af_inet.store(python_c.PyLong_FromLong(std.posix.AF.INET) orelse return error.PythonError, .release);
    py_af_inet6.store(python_c.PyLong_FromLong(std.posix.AF.INET6) orelse return error.PythonError, .release);
    py_af_unix.store(python_c.PyLong_FromLong(std.posix.AF.UNIX) orelse return error.PythonError, .release);
    py_sock_stream.store(python_c.PyLong_FromLong(std.posix.SOCK.STREAM) orelse return error.PythonError, .release);
    py_sock_dgram.store(python_c.PyLong_FromLong(std.posix.SOCK.DGRAM) orelse return error.PythonError, .release);
}

pub fn release_python_imports() void {
    const decls = comptime std.meta.declarations(@This());
    inline for (decls) |decl| {
        const decl_name = if (comptime @typeInfo(@TypeOf(decl)) == .@"struct") decl.name else decl;
        const T = @TypeOf(@field(@This(), decl_name));
        if (T != Atomic(?PyObject)) continue;
        const field = &@field(@This(), decl_name);
        // BUG-305: swap-extract instead of load-then-store so exactly one
        // caller (thread) receives the reference and drops it. Under
        // free-threading a load/store pair would let two threads both see
        // the same non-null value and double-decref it; swap guarantees
        // single ownership transfer per cached reference.
        // Optional pointers have plain pointer ABI in Zig, so the atomic
        // operates on a single word with null as the empty sentinel.
        const val = field.swap(null, .acq_rel);
        if (val) |v| {
            python_c.py_decref(v);
        }
    }
}
