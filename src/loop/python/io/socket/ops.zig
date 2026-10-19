const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");
const CallbackManager = @import("callback_manager");

const Loop = @import("../../../main.zig");
const LoopObject = Loop.Python.LoopObject;
const Future = @import("../../../../future/main.zig");
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
// sock_accept
// ============================================================

const AcceptData = struct {
    future: *FutureObject,
    loop: *LoopObject,
    socket_fd: std.posix.fd_t,
    family: i32,
    allocator: std.mem.Allocator,
    // BUG-360: zero-fill the storage — the kernel writes only as many
    // bytes as the peer address needs (an unnamed AF_UNIX client writes
    // just the 2-byte family), so anything left undefined leaks previous
    // allocator contents into the Python-side address object.
    addr: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage),
    addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage),
};

fn cleanup_accept(ptr: ?*anyopaque) void {
    const ad: *AcceptData = @ptrCast(@alignCast(ptr.?));
    python_c.py_decref(@ptrCast(ad.future));
    python_c.py_decref(@ptrCast(ad.loop));
    ad.allocator.destroy(ad);
}

fn sock_accept_callback(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const ad: *AcceptData = @ptrCast(@alignCast(data.user_data.?));
    // BUG-356: unconditional cleanup — every exit path (success, failure,
    // cancellation) releases the callback state. The manager-side
    // `.cleanup` is nulled (it only ran on error returns, which double-
    // freed with an unconditional defer).
    defer cleanup_accept(@ptrCast(ad));

    if (data.cancelled()) {
        // BUG-356: resolve the future instead of leaving the awaiter
        // hanging.
        const future_data = utils.get_data_ptr(Future, ad.future);
        if (future_data.status == .pending) {
            python_c.raise_python_runtime_error("Socket operation cancelled");
            return set_future_exception(error.PythonError, ad.future);
        }
        return;
    }

    if (io_uring_err != .SUCCESS or io_uring_res < 0) {
        const errno_val = if (io_uring_res < 0) -io_uring_res else @intFromEnum(io_uring_err);
        const exc = python_c.PyObject_CallFunction(python_c.PyExc_OSError, "is\x00", @as(c_int, @intCast(errno_val)), "Accept call failed\x00") orelse {
            ensure_exception(error.PythonError);
            return set_future_exception(error.PythonError, ad.future);
        };
        defer python_c.py_decref(exc);

        const future_data = utils.get_data_ptr(Future, ad.future);
        if (future_data.status == .pending) {
            try Future.Python.Result.future_fast_set_exception(ad.future, future_data, exc);
        }
        return;
    }

    const client_fd: std.posix.fd_t = @intCast(io_uring_res);
    var owns_fd = true;
    defer if (owns_fd) {
        _ = std.os.linux.close(client_fd);
    };

    // Convert addr to Python tuple.
    // BUG-360: honour the kernel's addrlen the way CPython does — an
    // unnamed AF_UNIX peer writes only the 2-byte family (the zeroed
    // path stays unread), and that must surface as '' like
    // socket.accept does, not as garbage bytes.
    const unnamed_unix = ad.family == std.posix.AF.UNIX and
        ad.addrlen <= @offsetOf(std.posix.sockaddr.un, "path");
    const py_addr = if (unnamed_unix) blk: {
        const empty = python_c.PyUnicode_FromStringAndSize("", 0) orelse {
            ensure_exception(error.PythonError);
            return set_future_exception(error.PythonError, ad.future);
        };
        break :blk empty;
    } else AddressUtils.toPyAddr(utils.Address.initPosix(@ptrCast(&ad.addr))) catch |err| {
        ensure_exception(err);
        return set_future_exception(err, ad.future);
    };
    defer python_c.py_decref(py_addr);

    const py_client_fd = python_c.PyLong_FromLong(client_fd) orelse {
        ensure_exception(error.PythonError);
        return set_future_exception(error.PythonError, ad.future);
    };
    defer python_c.py_decref(py_client_fd);

    const socket_class = utils.PythonImports.get("socket_class");

    const py_family = switch (ad.family) {
        std.posix.AF.INET => utils.PythonImports.get("py_af_inet"),
        std.posix.AF.INET6 => utils.PythonImports.get("py_af_inet6"),
        std.posix.AF.UNIX => utils.PythonImports.get("py_af_unix"),
        else => blk: {
            const py_val = python_c.PyLong_FromLong(ad.family) orelse {
                ensure_exception(error.PythonError);
                return set_future_exception(error.PythonError, ad.future);
            };
            break :blk py_val;
        },
    };
    defer if (ad.family != std.posix.AF.INET and ad.family != std.posix.AF.INET6 and ad.family != std.posix.AF.UNIX) {
        python_c.py_decref(py_family);
    };

    const py_type = utils.PythonImports.get("py_sock_stream");

    // Create Python socket object
    // socket.socket(family, type, proto, fileno=fd)
    const kwargs = python_c.PyDict_New() orelse {
        ensure_exception(error.PythonError);
        return set_future_exception(error.PythonError, ad.future);
    };
    defer python_c.py_decref(kwargs);
    _ = python_c.PyDict_SetItemString(kwargs, "fileno\x00", py_client_fd);

    const args = python_c.PyTuple_Pack(2, py_family, py_type) orelse {
        ensure_exception(error.PythonError);
        return set_future_exception(error.PythonError, ad.future);
    };
    defer python_c.py_decref(args);

    const py_sock = python_c.PyObject_Call(socket_class, args, kwargs) orelse {
        // BUG-356: resolve the future (the accepted fd is closed by the
        // owns_fd defer above) instead of leaking it and hanging the
        // awaiter.
        ensure_exception(error.PythonError);
        return set_future_exception(error.PythonError, ad.future);
    };
    owns_fd = false;
    defer python_c.py_decref(py_sock);

    const result_tuple = python_c.PyTuple_Pack(2, py_sock, py_addr) orelse {
        ensure_exception(error.PythonError);
        return set_future_exception(error.PythonError, ad.future);
    };
    defer python_c.py_decref(result_tuple);

    const future_data = utils.get_data_ptr(Future, ad.future);
    try Future.Python.Result.future_fast_set_result(future_data, result_tuple);
}

pub fn loop_sock_accept(self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t, knames: ?PyObject) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_sock_accept, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames });
}

fn z_loop_sock_accept(self: *LoopObject, args: []const ?PyObject, knames: ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;

    var merged: [1]?PyObject = undefined;
    try python_c.merge_vector_call_args(args, knames, &.{"sock"}, &merged);
    if (merged[0] == null) {
        python_c.raise_python_value_error("socket is required\x00");
        return error.PythonError;
    }

    const py_sock = merged[0].?;
    const fileno_attr = python_c.PyObject_GetAttrString(py_sock, "fileno\x00") orelse return error.PythonError;
    defer python_c.py_decref(fileno_attr);
    const py_fd = python_c.PyObject_CallNoArgs(fileno_attr) orelse return error.PythonError;
    defer python_c.py_decref(py_fd);
    const fd_long = python_c.PyLong_AsLong(py_fd);
    if (python_c.PyErr_Occurred() != null) return error.PythonError;
    // BUG-361: PyLong_AsLong yields an i64 - narrowing to fd_t panicked
    // on out-of-range values; raise ValueError instead (Mandate #1).
    const fd: std.posix.fd_t = try utils.checkedNarrow(std.posix.fd_t, fd_long, "invalid file descriptor\x00");

    const family_attr = python_c.PyObject_GetAttrString(py_sock, "family\x00") orelse return error.PythonError;
    defer python_c.py_decref(family_attr);
    const family_long = python_c.PyLong_AsLong(family_attr);
    if (python_c.PyErr_Occurred() != null) return error.PythonError;
    // BUG-361: see the fd narrowing above - sock.family is a Python
    // attribute like any other and must not be trusted.
    const family: i32 = try utils.checkedNarrow(i32, family_long, "invalid address family\x00");

    const loop_data = utils.get_data_ptr(Loop, self);
    const fut = try Future.Python.Constructors.fast_new_future(self);
    errdefer python_c.py_decref(@ptrCast(fut));

    const ad = try loop_data.allocator.create(AcceptData);
    errdefer loop_data.allocator.destroy(ad);
    ad.* = .{
        .future = @ptrCast(python_c.py_newref(@as(PyObject, @ptrCast(fut)))),
        .loop = python_c.py_newref(self),
        .socket_fd = fd,
        .family = family,
        .allocator = loop_data.allocator,
    };
    // BUG-310: if io.queue fails the op was never queued, so its cleanup
    // callback never runs; release the owned Python references here.
    errdefer {
        python_c.py_decref(@ptrCast(ad.future));
        python_c.py_decref(@ptrCast(ad.loop));
    }

    _ = try loop_data.io.queue(.{
        .SocketAccept = .{
            .socket_fd = fd,
            .addr = @ptrCast(&ad.addr),
            .addrlen = &ad.addrlen,
            .flags = @as(u32, @intCast(std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC)),
            .callback = .{
                .func = &sock_accept_callback,
                .cleanup = null, // BUG-356: the callback cleans up unconditionally (defer)
                .data = .{ .user_data = ad },
            },
        },
    });

    return fut;
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

// ============================================================
// sock_recvfrom
// ============================================================

const SockRecvFromData = struct {
    future: *FutureObject,
    loop: *LoopObject,
    allocator: std.mem.Allocator,
    buf: []u8,
    msg: std.posix.msghdr = undefined,
    iov: std.posix.iovec = undefined,
    // BUG-360: zero-filled — with namelen = 0 the kernel writes nothing
    // here at all (see sock_recvfrom_callback).
    addr: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage),
};

fn cleanup_recvfrom(ptr: ?*anyopaque) void {
    const rd: *SockRecvFromData = @ptrCast(@alignCast(ptr.?));
    python_c.py_decref(@ptrCast(rd.future));
    python_c.py_decref(@ptrCast(rd.loop));
    rd.allocator.free(rd.buf);
    rd.allocator.destroy(rd);
}

fn sock_recvfrom_callback(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const rd: *SockRecvFromData = @ptrCast(@alignCast(data.user_data.?));
    // BUG-356: unconditional cleanup — every exit path (success,
    // failure, cancellation) releases the callback state. The
    // manager-side `.cleanup` is nulled (it only ran on error returns,
    // which would double-free with an unconditional defer).
    defer cleanup_recvfrom(@ptrCast(rd));

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
        const exc = python_c.PyObject_CallFunction(python_c.PyExc_OSError, "is\x00", @as(c_int, @intCast(errno_val)), "Recvfrom call failed\x00") orelse {
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

    // BUG-360: mirror CPython's socket.recvfrom: when the kernel left
    // msg.namelen at 0 (an unnamed/unbound AF_UNIX datagram sender), the
    // address buffer was never written at all and the source address is
    // *None*, not a fabricated one from never-initialized storage.
    var py_addr: PyObject = undefined;
    var own_addr = false;
    if (rd.msg.namelen == 0) {
        // BUG-353: Py_None is immortal on 3.12+; borrow it.
        py_addr = python_c.get_py_none_without_incref();
    } else {
        py_addr = AddressUtils.toPyAddr(utils.Address.initPosix(@ptrCast(&rd.addr))) catch |err| {
            // BUG-356: resolve the future — the cleanup defer releases the
            // receive buffer; a bare error return hung the awaiter forever.
            ensure_exception(err);
            return set_future_exception(err, rd.future);
        };
        own_addr = true;
    }
    defer if (own_addr) python_c.py_decref(py_addr);

    const result_tuple = python_c.PyTuple_Pack(2, py_data, py_addr) orelse {
        ensure_exception(error.PythonError);
        return set_future_exception(error.PythonError, rd.future);
    };
    defer python_c.py_decref(result_tuple);

    const future_data = utils.get_data_ptr(Future, rd.future);
    try Future.Python.Result.future_fast_set_result(future_data, result_tuple);
}

pub fn loop_sock_recvfrom(self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t, knames: ?PyObject) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_sock_recvfrom, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames });
}

fn z_loop_sock_recvfrom(self: *LoopObject, args: []const ?PyObject, knames: ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;

    var merged: [2]?PyObject = undefined;
    try python_c.merge_vector_call_args(args, knames, &.{ "sock", "bufsize" }, &merged);
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

    const rd = try loop_data.allocator.create(SockRecvFromData);
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

    rd.iov = .{ .base = buf.ptr, .len = buf.len };
    rd.msg = .{
        .name = @ptrCast(&rd.addr),
        .namelen = @sizeOf(std.posix.sockaddr.storage),
        .iov = @ptrCast(&rd.iov),
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    _ = try loop_data.io.queue(.{
        .PerformRecvMsg = .{
            .fd = fd,
            .msg = &rd.msg,
            .callback = .{
                .func = &sock_recvfrom_callback,
                .cleanup = null, // BUG-356: the callback cleans up unconditionally (defer)
                .data = .{ .user_data = rd },
            },
        },
    });

    return fut;
}

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
