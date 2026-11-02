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
// sock_recv
// ============================================================

const SockRecvData = struct {
    future: *FutureObject,
    loop: *LoopObject,
    allocator: std.mem.Allocator,
    buf: []u8,
};

fn cleanup_recv(ptr: ?*anyopaque) void {
    const rd: *SockRecvData = @ptrCast(@alignCast(ptr.?));
    python_c.py_decref(@ptrCast(rd.future));
    python_c.py_decref(@ptrCast(rd.loop));
    rd.allocator.free(rd.buf);
    rd.allocator.destroy(rd);
}

fn sock_recv_callback(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const rd: *SockRecvData = @ptrCast(@alignCast(data.user_data.?));
    // BUG-356: unconditional cleanup — every exit path (success,
    // failure, cancellation) releases the callback state. The
    // manager-side `.cleanup` is nulled (it only ran on error returns,
    // which would double-free with an unconditional defer).
    defer cleanup_recv(@ptrCast(rd));

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
        const exc = python_c.PyObject_CallFunction(python_c.PyExc_OSError, "is\x00", @as(c_int, @intCast(errno_val)), "Recv call failed\x00") orelse {
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
    const py_data = python_c.PyBytes_FromStringAndSize(rd.buf.ptr, @intCast(nread)) orelse {
        ensure_exception(error.PythonError);
        return set_future_exception(error.PythonError, rd.future);
    };
    defer python_c.py_decref(py_data);

    const future_data = utils.get_data_ptr(Future, rd.future);
    try Future.Python.Result.future_fast_set_result(future_data, py_data);
}

pub fn loop_sock_recv(self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t, knames: ?PyObject) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_sock_recv, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames });
}

fn z_loop_sock_recv(self: *LoopObject, args: []const ?PyObject, knames: ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;

    var merged: [2]?PyObject = undefined;
    try python_c.merge_vector_call_args(args, knames, &.{ "sock", "n" }, &merged);
    if (merged[0] == null or merged[1] == null) {
        python_c.raise_python_value_error("socket and nbytes are required\x00");
        return error.PythonError;
    }

    const py_sock = merged[0].?;
    const py_nbytes = merged[1].?;
    const nbytes_sz = python_c.PyLong_AsSsize_t(py_nbytes);
    if (python_c.PyErr_Occurred() != null) return error.PythonError;
    // BUG-324: an unchecked @intCast panicked on negative nbytes
    // (Debug/ReleaseSafe) or truncated into a bogus allocation size
    // (ReleaseFast); raise ValueError instead.
    if (nbytes_sz < 0) {
        python_c.raise_python_value_error("nbytes must be non-negative\x00");
        return error.PythonError;
    }
    const nbytes: usize = @intCast(nbytes_sz);

    const fileno_attr = python_c.PyObject_GetAttrString(py_sock, "fileno\x00") orelse return error.PythonError;
    defer python_c.py_decref(fileno_attr);
    const py_fd = python_c.PyObject_CallNoArgs(fileno_attr) orelse return error.PythonError;
    defer python_c.py_decref(py_fd);
    const fd_long = python_c.PyLong_AsLong(py_fd);
    if (python_c.PyErr_Occurred() != null) return error.PythonError;
    // BUG-361: PyLong_AsLong yields an i64 - narrowing to fd_t panicked
    // on out-of-range values; raise ValueError instead (Mandate #1).
    const fd: std.posix.fd_t = try utils.checkedNarrow(std.posix.fd_t, fd_long, "invalid file descriptor\x00");

    const loop_data = utils.get_data_ptr(Loop, self);
    const fut = try Future.Python.Constructors.fast_new_future(self);
    errdefer python_c.py_decref(@ptrCast(fut));

    const buf = try loop_data.allocator.alloc(u8, nbytes);
    errdefer loop_data.allocator.free(buf);

    const rd = try loop_data.allocator.create(SockRecvData);
    errdefer loop_data.allocator.destroy(rd);
    rd.* = .{
        .future = @ptrCast(python_c.py_newref(@as(PyObject, @ptrCast(fut)))),
        .loop = python_c.py_newref(self),
        .allocator = loop_data.allocator,
        .buf = buf,
    };
    // BUG-310: if io.queue fails the op was never queued, so its cleanup
    // callback never runs; release the owned Python references here.
    errdefer {
        python_c.py_decref(@ptrCast(rd.future));
        python_c.py_decref(@ptrCast(rd.loop));
    }

    _ = try loop_data.io.queue(.{
        .PerformRead = .{
            .fd = fd,
            .data = .{ .buffer = buf },
            .callback = .{
                .func = &sock_recv_callback,
                .cleanup = null, // BUG-356: the callback cleans up unconditionally (defer)
                .data = .{ .user_data = rd },
            },
        },
    });

    return fut;
}
