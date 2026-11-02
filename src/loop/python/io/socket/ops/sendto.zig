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

const ensure_exception = @import("common.zig").ensure_exception;

// ============================================================
// sock_sendto
// ============================================================

const SockSendToData = struct {
    future: *FutureObject,
    loop: *LoopObject,
    allocator: std.mem.Allocator,
    buf: []u8,
    msg: std.posix.msghdr_const = undefined,
    iov: std.posix.iovec_const = undefined,
    addr: utils.Address,
};

fn cleanup_sendto(ptr: ?*anyopaque) void {
    const sd: *SockSendToData = @ptrCast(@alignCast(ptr.?));
    python_c.py_decref(@ptrCast(sd.future));
    python_c.py_decref(@ptrCast(sd.loop));
    sd.allocator.free(sd.buf);
    sd.allocator.destroy(sd);
}

fn sock_sendto_callback(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const sd: *SockSendToData = @ptrCast(@alignCast(data.user_data.?));
    // BUG-356: unconditional cleanup — every exit path (success,
    // failure, cancellation) releases the callback state. The
    // manager-side `.cleanup` is nulled (it only ran on error returns,
    // which would double-free with an unconditional defer).
    defer cleanup_sendto(@ptrCast(sd));

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
        const exc = python_c.PyObject_CallFunction(python_c.PyExc_OSError, "is\x00", @as(c_int, @intCast(errno_val)), "Sendto call failed\x00") orelse {
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

    const future_data = utils.get_data_ptr(Future, sd.future);
    // BUG-58: Check for null return from PyLong_FromLong. If allocation
    // fails, dereferencing the null would segfault. Propagate as a future
    // exception instead.
    const py_res = python_c.PyLong_FromLong(@intCast(io_uring_res)) orelse
        return set_future_exception(error.PythonError, sd.future);
    // BUG-353: future_fast_set_result takes its own reference — drop ours.
    defer python_c.py_decref(py_res);
    try Future.Python.Result.future_fast_set_result(future_data, py_res);
}

pub fn loop_sock_sendto(self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t, knames: ?PyObject) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_sock_sendto, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames });
}

fn z_loop_sock_sendto(self: *LoopObject, args: []const ?PyObject, knames: ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;

    var merged: [3]?PyObject = undefined;
    try python_c.merge_vector_call_args(args, knames, &.{ "sock", "data", "address" }, &merged);
    if (merged[0] == null or merged[1] == null or merged[2] == null) {
        python_c.raise_python_value_error("socket, data and address are required\x00");
        return error.PythonError;
    }

    const py_sock = merged[0].?;
    const py_data = merged[1].?;
    const py_addr = merged[2].?;

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

    var pbuf: python_c.Py_buffer = undefined;
    if (python_c.PyObject_GetBuffer(py_data, &pbuf, python_c.PyBUF_SIMPLE) < 0) {
        return error.PythonError;
    }
    defer python_c.PyBuffer_Release(&pbuf);

    const loop_data = utils.get_data_ptr(Loop, self);
    const fut = try Future.Python.Constructors.fast_new_future(self);
    errdefer python_c.py_decref(@ptrCast(fut));

    const data_len: usize = @intCast(pbuf.len);
    const data_buf = try loop_data.allocator.alloc(u8, data_len);
    errdefer loop_data.allocator.free(data_buf);
    // BUG-360: an empty buffer has pbuf.buf == null — see sock_sendall.
    if (data_len > 0 and pbuf.buf != null) {
        @memcpy(data_buf, @as([*]const u8, @ptrCast(pbuf.buf))[0..data_len]);
    }

    const sd = try loop_data.allocator.create(SockSendToData);
    errdefer loop_data.allocator.destroy(sd);
    sd.* = .{
        .future = @ptrCast(python_c.py_newref(@as(PyObject, @ptrCast(fut)))),
        .loop = python_c.py_newref(self),
        .allocator = loop_data.allocator,
        .buf = data_buf,
        .addr = addr,
    };
    // BUG-310: if io.queue fails the op was never queued, so its cleanup
    // callback never runs; release the owned Python references here.
    errdefer {
        python_c.py_decref(@ptrCast(sd.future));
        python_c.py_decref(@ptrCast(sd.loop));
    }

    sd.iov = .{ .base = data_buf.ptr, .len = data_buf.len };
    sd.msg = .{
        .name = &sd.addr.any,
        .namelen = sd.addr.getOsSockLen(),
        .iov = @ptrCast(&sd.iov),
        // BUG-360: zero-length payloads must keep a msg_iovlen of 0 —
        // io_uring's send path rejects a zero-length iovec (EFAULT) but
        // delivers an empty datagram through the syscall semantics.
        .iovlen = if (data_buf.len == 0) 0 else 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    _ = try loop_data.io.queue(.{
        .PerformSendMsg = .{
            .fd = fd,
            .msg = &sd.msg,
            .callback = .{
                .func = &sock_sendto_callback,
                .cleanup = null, // BUG-356: the callback cleans up unconditionally (defer)
                .data = .{ .user_data = sd },
            },
        },
    });

    return fut;
}
