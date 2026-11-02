const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const CallbackManager = @import("callback_manager");

const Loop = @import("../../../../main.zig");

const Future = @import("../../../../../future/main.zig");

const Stream = @import("../../../../../transports/stream/main.zig");
const types = @import("types.zig");
const set_future_exception = Future.Python.Result.set_future_exception;
const TransportCreationData = types.TransportCreationData;

pub fn z_create_transport_and_set_future_result(data: *TransportCreationData) !void {
    const protocol = python_c.PyObject_CallNoArgs(data.protocol_factory) orelse return error.PythonError;
    defer python_c.py_decref(protocol);

    // BUG-328: adopt the caller's connected socket. Dup first (the
    // transport gets its own descriptor number that outlives the caller's
    // object), then close the CALLER'S SOCKET OBJECT the way CPython's
    // _SelectorTransport._call_connection_lost closes the wrapped socket -
    // a caller object left holding the connection keeps it open forever
    // (the peer never sees EOF, wedging accept loops and cascading into
    // accept-queue exhaustion and SYN-SENT hangs), and closing only the
    // raw fd number would leave the object wrapping a descriptor that may
    // later be REUSED by an unrelated socket.
    var adopted_fd: std.posix.fd_t = -1;
    errdefer if (adopted_fd >= 0) {
        _ = std.os.linux.close(adopted_fd);
    };
    if (data.py_sock) |py_sock| {
        const dup_ret = std.os.linux.dup(data.socket_fd);
        if (utils.getSyscallErrno(dup_ret) != .SUCCESS) return error.SystemResources;
        adopted_fd = @intCast(dup_ret);

        const close_method = python_c.PyObject_GetAttrString(py_sock, "close\x00") orelse {
            python_c.PyErr_Clear();
            return error.PythonError;
        };
        defer python_c.py_decref(close_method);
        if (python_c.PyObject_CallNoArgs(close_method)) |res| {
            python_c.py_decref(res);
        } else {
            // Best effort - a raising close() must not fail the connection;
            // the connection itself is already the transport's (dup).
            python_c.PyErr_Clear();
        }
    }

    const transport_fd: std.posix.fd_t = if (adopted_fd >= 0) adopted_fd else data.socket_fd;
    const transport = try Stream.Constructors.new_stream_transport_with_owns_fd(protocol, data.loop, transport_fd, data.zero_copying, true);
    data.fd_created = false;
    // Ownership of adopted_fd transferred to the transport (owns_fd=true);
    // the transport's own teardown closes it - disarm the errdefer above so
    // a later failure does not double-close.
    adopted_fd = -1;
    defer python_c.py_decref(@ptrCast(transport));

    const connection_made_func = python_c.PyObject_GetAttrString(protocol, "connection_made\x00") orelse return error.PythonError;
    defer python_c.py_decref(connection_made_func);

    const ret = python_c.PyObject_CallOneArg(connection_made_func, @ptrCast(transport)) orelse return error.PythonError;
    defer python_c.py_decref(ret);

    const result_tuple = python_c.PyTuple_Pack(2, @as(PyObject, @ptrCast(transport)), protocol) orelse return error.PythonError;
    defer python_c.py_decref(result_tuple);

    const future_data = utils.get_data_ptr(Future, data.future);
    try Future.Python.Result.future_fast_set_result(future_data, result_tuple);
}

pub fn create_transport_and_set_future_result(data: *const CallbackManager.CallbackData) !void {
    const transport_creation_data_ptr: *TransportCreationData = @ptrCast(@alignCast(data.user_data.?));

    const loop = transport_creation_data_ptr.loop;
    const loop_data = utils.get_data_ptr(Loop, loop);
    const allocator = loop_data.allocator;

    defer allocator.destroy(transport_creation_data_ptr);

    var transport_creation_data = transport_creation_data_ptr.*;
    defer {
        python_c.py_decref(transport_creation_data.protocol_factory);
        python_c.py_decref(@ptrCast(transport_creation_data.loop));
        python_c.py_decref(@ptrCast(transport_creation_data.future));
        python_c.py_xdecref(transport_creation_data.py_sock);

        if (transport_creation_data.fd_created) {
            _ = std.os.linux.close(@intCast(transport_creation_data.socket_fd));
        }
    }
    if (data.cancelled()) return;

    z_create_transport_and_set_future_result(&transport_creation_data) catch |err| {
        return set_future_exception(err, transport_creation_data.future);
    };
}

// -----------------------------------------------------------------
