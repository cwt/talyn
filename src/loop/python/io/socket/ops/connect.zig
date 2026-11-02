const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");
const CallbackManager = @import("callback_manager");

const Loop = @import("../../../../main.zig");
const LoopObject = Loop.Python.LoopObject;
const Future = @import("../../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;

const AddressUtils = utils.Address;

const set_future_exception = Future.Python.Result.set_future_exception;

/// BUG-356: `set_future_exception` STEALS the pending Python exception
/// (`PyErr_GetRaisedException`); if none is set it silently does nothing
/// and the future stays pending forever (infinite hang on `await`).
fn ensure_exception(err: anyerror) void {
    if (python_c.PyErr_Occurred() == null) {
        if (err == error.PythonError) {
            python_c.raise_python_runtime_error("Socket operation failed");
        } else {
            utils.handle_zig_function_error(err, {});
        }
    }
}

// ============================================================
// sock_connect
// ============================================================

const SockConnectData = struct {
    future: *FutureObject,
    loop: *LoopObject,
    allocator: std.mem.Allocator,
    addr: utils.Address,
};

fn cleanup_connect(ptr: ?*anyopaque) void {
    const scd: *SockConnectData = @ptrCast(@alignCast(ptr.?));
    python_c.py_decref(@ptrCast(scd.future));
    python_c.py_decref(@ptrCast(scd.loop));
    scd.allocator.destroy(scd);
}

fn sock_connect_callback(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const scd: *SockConnectData = @ptrCast(@alignCast(data.user_data.?));
    // BUG-356: unconditional cleanup — every exit path (success,
    // failure, cancellation) releases the callback state. The
    // manager-side `.cleanup` is nulled (it only ran on error returns,
    // which would double-free with an unconditional defer).
    defer cleanup_connect(@ptrCast(scd));

    if (data.cancelled()) {
        // BUG-356: resolve the future instead of leaving the awaiter
        // hanging.
        const future_data = utils.get_data_ptr(Future, scd.future);
        if (future_data.status == .pending) {
            python_c.raise_python_runtime_error("Socket operation cancelled");
            return set_future_exception(error.PythonError, scd.future);
        }
        return;
    }

    if (io_uring_err != .SUCCESS and io_uring_err != .ALREADY) {
        const errno_val = if (io_uring_res < 0) -io_uring_res else @intFromEnum(io_uring_err);
        const exc = python_c.PyObject_CallFunction(python_c.PyExc_OSError, "is\x00", @as(c_int, @intCast(errno_val)), "Connect call failed\x00") orelse {
            ensure_exception(error.PythonError);
            return set_future_exception(error.PythonError, scd.future);
        };
        defer python_c.py_decref(exc);

        const future_data = utils.get_data_ptr(Future, scd.future);
        if (future_data.status == .pending) {
            try Future.Python.Result.future_fast_set_exception(scd.future, future_data, exc);
        }
        return;
    }

    const future_data = utils.get_data_ptr(Future, scd.future);
    // BUG-353: future_fast_set_result takes its own reference; pass the
    // borrowed None — get_py_none() increfed it and leaked one Py_None
    // per sock_connect call.
    try Future.Python.Result.future_fast_set_result(future_data, python_c.get_py_none_without_incref());
}

pub fn loop_sock_connect(self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t, knames: ?PyObject) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_sock_connect, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames });
}

fn z_loop_sock_connect(self: *LoopObject, args: []const ?PyObject, knames: ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;

    var merged: [2]?PyObject = undefined;
    try python_c.merge_vector_call_args(args, knames, &.{ "sock", "address" }, &merged);
    if (merged[0] == null or merged[1] == null) {
        python_c.raise_python_value_error("socket and address are required\x00");
        return error.PythonError;
    }

    const py_sock = merged[0].?;
    const py_addr = merged[1].?;

    const fileno_attr = python_c.PyObject_GetAttrString(py_sock, "fileno\x00") orelse return error.PythonError;
    defer python_c.py_decref(fileno_attr);
    const py_fd = python_c.PyObject_CallNoArgs(fileno_attr) orelse return error.PythonError;
    defer python_c.py_decref(py_fd);
    const fd_long = python_c.PyLong_AsLong(py_fd);
    if (python_c.PyErr_Occurred() != null) return error.PythonError;
    // BUG-361: PyLong_AsLong yields an i64 - narrowing to fd_t panicked
    // on out-of-range values; raise ValueError instead (Mandate #1).
    const fd: std.posix.fd_t = try utils.checkedNarrow(std.posix.fd_t, fd_long, "invalid file descriptor\x00");

    const py_family = python_c.PyObject_GetAttrString(py_sock, "family\x00") orelse return error.PythonError;
    defer python_c.py_decref(py_family);
    const family_long = python_c.PyLong_AsLong(py_family);
    if (python_c.PyErr_Occurred() != null) return error.PythonError;
    // BUG-361: see the fd narrowing above - sock.family is a Python
    // attribute like any other and must not be trusted.
    const family: i32 = try utils.checkedNarrow(i32, family_long, "invalid address family\x00");

    const addr = try AddressUtils.fromPyAddr(py_addr, family);

    const loop_data = utils.get_data_ptr(Loop, self);
    const fut = try Future.Python.Constructors.fast_new_future(self);
    errdefer python_c.py_decref(@ptrCast(fut));

    const scd = try loop_data.allocator.create(SockConnectData);
    errdefer loop_data.allocator.destroy(scd);
    scd.* = .{
        .future = @ptrCast(python_c.py_newref(@as(PyObject, @ptrCast(fut)))),
        .loop = python_c.py_newref(self),
        .allocator = loop_data.allocator,
        .addr = addr,
    };
    // BUG-310: if io.queue fails the op was never queued, so its cleanup
    // callback never runs; release the owned Python references here.
    errdefer {
        python_c.py_decref(@ptrCast(scd.future));
        python_c.py_decref(@ptrCast(scd.loop));
    }

    _ = try loop_data.io.queue(.{
        .SocketConnect = .{
            .socket_fd = fd,
            .addr = &scd.addr.any,
            .len = scd.addr.getOsSockLen(),
            .callback = .{
                .func = &sock_connect_callback,
                .cleanup = null, // BUG-356: the callback cleans up unconditionally (defer)
                .data = .{ .user_data = scd },
            },
        },
    });

    return fut;
}
