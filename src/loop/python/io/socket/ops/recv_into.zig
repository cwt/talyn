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
// sock_recv_into
// ============================================================

pub fn loop_sock_recv_into(self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t, knames: ?PyObject) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_sock_recv_into, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames });
}

fn z_loop_sock_recv_into(self: *LoopObject, args: []const ?PyObject, knames: ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;

    var merged: [2]?PyObject = undefined;
    try python_c.merge_vector_call_args(args, knames, &.{ "sock", "buf" }, &merged);
    if (merged[0] == null or merged[1] == null) {
        python_c.raise_python_value_error("socket and buffer are required\x00");
        return error.PythonError;
    }

    const py_sock = merged[0].?;
    const py_buf = merged[1].?;

    const fileno_attr = python_c.PyObject_GetAttrString(py_sock, "fileno\x00") orelse return error.PythonError;
    defer python_c.py_decref(fileno_attr);
    const py_fd = python_c.PyObject_CallNoArgs(fileno_attr) orelse return error.PythonError;
    defer python_c.py_decref(py_fd);
    const fd_long = python_c.PyLong_AsLong(py_fd);
    if (python_c.PyErr_Occurred() != null) return error.PythonError;
    // BUG-361: PyLong_AsLong yields an i64 - narrowing to fd_t panicked
    // on out-of-range values; raise ValueError instead (Mandate #1).
    const fd: std.posix.fd_t = try utils.checkedNarrow(std.posix.fd_t, fd_long, "invalid file descriptor\x00");

    var pbuf: python_c.Py_buffer = undefined;
    if (python_c.PyObject_GetBuffer(py_buf, &pbuf, python_c.PyBUF_WRITABLE) < 0) {
        return error.PythonError;
    }
    // BUG-360: an empty buffer object (e.g. bytearray()) has pbuf.buf ==
    // null; casting that to [*]u8 trips the null-pointer safety check
    // (and queues a zero-length recv the caller never meant to run).
    // CPython short-circuits empty buffers to 0 without a syscall —
    // mirror that here.
    if (pbuf.len == 0 or pbuf.buf == null) {
        python_c.PyBuffer_Release(&pbuf);
        const fut = try Future.Python.Constructors.fast_new_future(self);
        errdefer python_c.py_decref(@ptrCast(fut));
        const zero = python_c.PyLong_FromLong(0) orelse return error.PythonError;
        defer python_c.py_decref(zero);
        const zero_data = utils.get_data_ptr(Future, fut);
        try Future.Python.Result.future_fast_set_result(zero_data, zero);
        return fut;
    }
    // We can't release the buffer here because io_uring needs it until callback.
    // So we need to store it in rd.
    errdefer python_c.PyBuffer_Release(&pbuf);

    const loop_data = utils.get_data_ptr(Loop, self);
    const fut = try Future.Python.Constructors.fast_new_future(self);
    errdefer python_c.py_decref(@ptrCast(fut));

    const rd = try loop_data.allocator.create(SockRecvIntoDataWithBuf);
    errdefer loop_data.allocator.destroy(rd);
    rd.* = .{
        .future = @ptrCast(python_c.py_newref(@as(PyObject, @ptrCast(fut)))),
        .loop = python_c.py_newref(self),
        .allocator = loop_data.allocator,
        .pbuf = pbuf,
    };
    // BUG-310: if io.queue fails the op was never queued, so its cleanup
    // callback never runs; release the owned Python references (the buffer
    // view stays valid - it is released with the future's owner below).
    errdefer {
        python_c.py_decref(@ptrCast(rd.future));
        python_c.py_decref(@ptrCast(rd.loop));
    }

    _ = try loop_data.io.queue(.{
        .PerformRead = .{
            .fd = fd,
            .data = .{ .buffer = @as([*]u8, @ptrCast(pbuf.buf))[0..@intCast(pbuf.len)] },
            .callback = .{
                .func = &sock_recv_into_callback_with_buf,
                .cleanup = null, // BUG-356: the callback cleans up unconditionally (defer)
                .data = .{ .user_data = rd },
            },
        },
    });

    return fut;
}

const SockRecvIntoDataWithBuf = struct {
    future: *FutureObject,
    loop: *LoopObject,
    allocator: std.mem.Allocator,
    pbuf: python_c.Py_buffer,
};

fn cleanup_recv_into_with_buf(ptr: ?*anyopaque) void {
    const rd: *SockRecvIntoDataWithBuf = @ptrCast(@alignCast(ptr.?));
    python_c.PyBuffer_Release(&rd.pbuf);
    python_c.py_decref(@ptrCast(rd.future));
    python_c.py_decref(@ptrCast(rd.loop));
    rd.allocator.destroy(rd);
}

fn sock_recv_into_callback_with_buf(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const rd: *SockRecvIntoDataWithBuf = @ptrCast(@alignCast(data.user_data.?));
    // BUG-356: unconditional cleanup — every exit path (success,
    // failure, cancellation) releases the callback state. The
    // manager-side `.cleanup` is nulled (it only ran on error returns,
    // which would double-free with an unconditional defer).
    defer cleanup_recv_into_with_buf(@ptrCast(rd));

    if (data.cancelled()) {
        // BUG-356: resolve the future instead of leaving the awaiter
        // hanging.
        const future_data = utils.get_data_ptr(Future, rd.future);
        if (future_data.status == .pending) {
            python_c.raise_python_runtime_error("Socket operation cancelled");
            return set_future_exception(error.PythonError, rd.future);
        }
        return;
    }

    if (io_uring_err != .SUCCESS) {
        const errno_val = @intFromEnum(io_uring_err);
        const exc = python_c.PyObject_CallFunction(python_c.PyExc_OSError, "is\x00", @as(c_int, @intCast(errno_val)), "Recv_into call failed\x00") orelse {
            ensure_exception(error.PythonError);
            return set_future_exception(error.PythonError, rd.future);
        };
        defer python_c.py_decref(exc);

        const future_data = utils.get_data_ptr(Future, rd.future);
        if (future_data.status == .pending) {
            try Future.Python.Result.future_fast_set_exception(rd.future, future_data, exc);
        }
        return;
    }

    const nread: usize = @intCast(@max(io_uring_res, 0));
    const future_data = utils.get_data_ptr(Future, rd.future);
    // BUG-58: Check for null return from PyLong_FromLong. If allocation
    // fails, dereferencing the null would segfault. Propagate as a future
    // exception instead.
    const py_nread = python_c.PyLong_FromLong(@intCast(nread)) orelse
        return set_future_exception(error.PythonError, rd.future);
    // BUG-353: future_fast_set_result takes its own reference — drop ours.
    defer python_c.py_decref(py_nread);
    try Future.Python.Result.future_fast_set_result(future_data, py_nread);
}
