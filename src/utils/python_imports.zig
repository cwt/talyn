const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const PyTypeObject = *python_c.PyTypeObject;

const std = @import("std");
const Atomic = std.atomic.Value;

pub var asyncio_module: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var sys_module: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var weakref_module: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var socket_module: Atomic(PyObject) = Atomic(PyObject).init(undefined);

pub var socket_class: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var base_event_loop: Atomic(PyObject) = Atomic(PyObject).init(undefined);

pub var asyncio_protocol: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var asyncio_buffered_protocol: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var asyncio_datagram_protocol: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var asyncio_subprocess_protocol: Atomic(PyObject) = Atomic(PyObject).init(undefined);

pub var asyncio_transport: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var asyncio_datagram_transport: Atomic(PyObject) = Atomic(PyObject).init(undefined);

pub var invalid_state_exc: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var cancelled_error_exc: Atomic(PyObject) = Atomic(PyObject).init(undefined);

pub var set_running_loop: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var enter_task_func: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var leave_task_func: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var register_task_func: Atomic(PyObject) = Atomic(PyObject).init(undefined);

pub var get_asyncgen_hooks: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var set_asyncgen_hooks: Atomic(PyObject) = Atomic(PyObject).init(undefined);

pub var py_af_inet: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var py_af_inet6: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var py_af_unix: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var py_sock_stream: Atomic(PyObject) = Atomic(PyObject).init(undefined);
pub var py_sock_dgram: Atomic(PyObject) = Atomic(PyObject).init(undefined);

pub fn get(comptime name: []const u8) PyObject {
    return @field(@This(), name).load(.acquire);
}

pub fn initialize_python_imports() !void {
    const a_mod = python_c.PyImport_ImportModule("asyncio\x00") orelse return error.PythonError;
    asyncio_module.store(a_mod, .release);
    const s_mod = python_c.PyImport_ImportModule("sys\x00") orelse return error.PythonError;
    sys_module.store(s_mod, .release);
    weakref_module.store(python_c.PyImport_ImportModule("weakref\x00") orelse return error.PythonError, .release);
    socket_module.store(python_c.PyImport_ImportModule("socket\x00") orelse return error.PythonError, .release);

    base_event_loop.store(python_c.PyObject_GetAttrString(a_mod, "AbstractEventLoop\x00")
        orelse return error.PythonError, .release);

    socket_class.store(python_c.PyObject_GetAttrString(socket_module.load(.acquire), "socket\x00")
        orelse return error.PythonError, .release);

    invalid_state_exc.store(python_c.PyObject_GetAttrString(a_mod, "InvalidStateError\x00")
        orelse return error.PythonError, .release);
    cancelled_error_exc.store(python_c.PyObject_GetAttrString(a_mod, "CancelledError\x00")
        orelse return error.PythonError, .release);

    asyncio_protocol.store(python_c.PyObject_GetAttrString(a_mod, "Protocol\x00")
        orelse return error.PythonError, .release);
    asyncio_buffered_protocol.store(python_c.PyObject_GetAttrString(a_mod, "BufferedProtocol\x00")
        orelse return error.PythonError, .release);
    asyncio_datagram_protocol.store(python_c.PyObject_GetAttrString(a_mod, "DatagramProtocol\x00")
        orelse return error.PythonError, .release);
    asyncio_subprocess_protocol.store(python_c.PyObject_GetAttrString(a_mod, "SubprocessProtocol\x00")
        orelse return error.PythonError, .release);

    asyncio_transport.store(python_c.PyObject_GetAttrString(a_mod, "Transport\x00")
        orelse return error.PythonError, .release);
    asyncio_datagram_transport.store(python_c.PyObject_GetAttrString(a_mod, "DatagramTransport\x00")
        orelse return error.PythonError, .release);

    set_running_loop.store(python_c.PyObject_GetAttrString(a_mod, "_set_running_loop\x00")
        orelse return error.PythonError, .release);
    enter_task_func.store(python_c.PyObject_GetAttrString(a_mod, "_enter_task\x00")
        orelse return error.PythonError, .release);
    leave_task_func.store(python_c.PyObject_GetAttrString(a_mod, "_leave_task\x00")
        orelse return error.PythonError, .release);
    register_task_func.store(python_c.PyObject_GetAttrString(a_mod, "_register_task\x00")
        orelse return error.PythonError, .release);

    get_asyncgen_hooks.store(python_c.PyObject_GetAttrString(s_mod, "get_asyncgen_hooks\x00")
        orelse return error.PythonError, .release);
    set_asyncgen_hooks.store(python_c.PyObject_GetAttrString(s_mod, "set_asyncgen_hooks\x00")
        orelse return error.PythonError, .release);

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
        if (T != Atomic(PyObject)) continue;
        const field = &@field(@This(), decl.name);
        const val = field.load(.acquire);
        if (@intFromPtr(val) != 0) {
            python_c.py_decref(val);
        }
        field.store(undefined, .release);
    }
}
