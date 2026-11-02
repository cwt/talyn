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
