const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");
const CallbackManager = @import("callback_manager");

const Loop = @import("../../../../main.zig");
const LoopObject = Loop.Python.LoopObject;
const Future = @import("../../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;

const set_future_exception = Future.Python.Result.set_future_exception;

const ensure_exception = @import("common.zig").ensure_exception;

// ============================================================
// sock_sendall
// ============================================================

const SockSendAllData = struct {
    future: *FutureObject,
    loop: *LoopObject,
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    data: []u8,
    offset: usize = 0,
};

fn cleanup_sendall(ptr: ?*anyopaque) void {
    const sd: *SockSendAllData = @ptrCast(@alignCast(ptr.?));
    python_c.py_decref(@ptrCast(sd.future));
    python_c.py_decref(@ptrCast(sd.loop));
    sd.allocator.free(sd.data);
    sd.allocator.destroy(sd);
}

fn sock_sendall_callback(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const sd: *SockSendAllData = @ptrCast(@alignCast(data.user_data.?));
    // BUG-356: every terminal exit path (final completion, failure,
    // cancellation) releases the callback state; only a successful
    // partial-write re-queue keeps `sd` alive for the next SQE.
    var requeued = false;
    defer if (!requeued) cleanup_sendall(@ptrCast(sd));

    if (data.cancelled()) {
        // BUG-356: resolve the future instead of leaving the awaiter
        // hanging.
        const future_data = utils.get_data_ptr(Future, sd.future);
        if (future_data.status == .pending) {
            python_c.raise_python_runtime_error("Socket operation cancelled");
            return set_future_exception(error.PythonError, sd.future);
        }
        return;
    }

    if (io_uring_err != .SUCCESS) {
        const errno_val = @intFromEnum(io_uring_err);
        const exc = python_c.PyObject_CallFunction(python_c.PyExc_OSError, "is\x00", @as(c_int, @intCast(errno_val)), "Sendall call failed\x00") orelse {
            ensure_exception(error.PythonError);
            return set_future_exception(error.PythonError, sd.future);
        };
        defer python_c.py_decref(exc);

        const future_data = utils.get_data_ptr(Future, sd.future);
        if (future_data.status == .pending) {
            try Future.Python.Result.future_fast_set_exception(sd.future, future_data, exc);
        }
        return;
    }

    const nwritten: usize = @intCast(@max(io_uring_res, 0));
    sd.offset += nwritten;

    if (sd.offset < sd.data.len) {
        // Re-queue remaining data - NOT finished, do not cleanup sd!
        const loop_data = utils.get_data_ptr(Loop, sd.loop);
        _ = loop_data.io.queue(.{
            .PerformWrite = .{
                .fd = sd.fd,
                .data = sd.data[sd.offset..],
                .callback = .{
                    .func = &sock_sendall_callback,
                    .cleanup = null, // BUG-356: the callback cleans up via defer
                    .data = .{ .user_data = sd },
                },
            },
        }) catch |err| {
            ensure_exception(err);
            return set_future_exception(err, sd.future);
        };
        requeued = true;
        return;
    }

    // Success
    const future_data = utils.get_data_ptr(Future, sd.future);
    // BUG-353: pass the borrowed None (see sock_connect_callback).
    try Future.Python.Result.future_fast_set_result(future_data, python_c.get_py_none_without_incref());
}

pub fn loop_sock_sendall(self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t, knames: ?PyObject) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_sock_sendall, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames });
}

fn z_loop_sock_sendall(self: *LoopObject, args: []const ?PyObject, knames: ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;

    var merged: [2]?PyObject = undefined;
    try python_c.merge_vector_call_args(args, knames, &.{ "sock", "data" }, &merged);
    if (merged[0] == null or merged[1] == null) {
        python_c.raise_python_value_error("socket and data are required\x00");
        return error.PythonError;
    }

    const py_sock = merged[0].?;
    const py_data = merged[1].?;

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
    if (python_c.PyObject_GetBuffer(py_data, &pbuf, python_c.PyBUF_SIMPLE) < 0) {
        return error.PythonError;
    }
    defer python_c.PyBuffer_Release(&pbuf);

    const data_len: usize = @intCast(pbuf.len);

    // BUG-360: for empty data, (a) a fresh empty bytearray() carries
    // pbuf.buf == null, so the [*]const u8 cast below would trip the
    // null-pointer safety check, and (b) io_uring rejects zero-length
    // write SQEs (EFAULT). CPython's sock_sendall(b'') performs no
    // syscall at all, so resolve the future immediately.
    if (data_len == 0 or pbuf.buf == null) {
        const fut = try Future.Python.Constructors.fast_new_future(self);
        errdefer python_c.py_decref(@ptrCast(fut));
        const future_data = utils.get_data_ptr(Future, fut);
        // BUG-353: future_fast_set_result takes its own reference; pass
        // the borrowed None.
        try Future.Python.Result.future_fast_set_result(future_data, python_c.get_py_none_without_incref());
        return fut;
    }

    const loop_data = utils.get_data_ptr(Loop, self);
    const fut = try Future.Python.Constructors.fast_new_future(self);
    errdefer python_c.py_decref(@ptrCast(fut));

    // Copy data to local buffer for async send.
    const data_buf = try loop_data.allocator.alloc(u8, data_len);
    errdefer loop_data.allocator.free(data_buf);
    @memcpy(data_buf, @as([*]const u8, @ptrCast(pbuf.buf))[0..data_len]);

    const sd = try loop_data.allocator.create(SockSendAllData);
    errdefer loop_data.allocator.destroy(sd);
    sd.* = .{
        .future = @ptrCast(python_c.py_newref(@as(PyObject, @ptrCast(fut)))),
        .loop = python_c.py_newref(self),
        .allocator = loop_data.allocator,
        .fd = fd,
        .data = data_buf,
    };
    // BUG-310: if io.queue fails the op was never queued, so its cleanup
    // callback never runs; release the owned Python references here.
    errdefer {
        python_c.py_decref(@ptrCast(sd.future));
        python_c.py_decref(@ptrCast(sd.loop));
    }

    _ = try loop_data.io.queue(.{
        .PerformWrite = .{
            .fd = fd,
            .data = data_buf,
            .callback = .{
                .func = &sock_sendall_callback,
                .cleanup = null, // BUG-356: the callback cleans up unconditionally (defer)
                .data = .{ .user_data = sd },
            },
        },
    });

    return fut;
}
