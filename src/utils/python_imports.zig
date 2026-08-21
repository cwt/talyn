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
    if (register_task_func.load(.acquire)) |func| {
        _ = python_c.PyObject_CallOneArg(func, task) orelse python_c.PyErr_Clear();
    }
    if (py_register_task_func.load(.acquire)) |func| {
        if (register_task_func.load(.acquire)) |cfunc| {
            if (cfunc != func) {
                _ = python_c.PyObject_CallOneArg(func, task) orelse python_c.PyErr_Clear();
            }
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
        const T = @TypeOf(@field(@This(), decl.name));
        if (T != Atomic(?PyObject)) continue;
        const field = &@field(@This(), decl.name);
        const val = field.load(.acquire);
        if (val) |v| {
            python_c.py_decref(v);
        }
        field.store(null, .release);
    }
}
