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

fn set_future_exception(err: anyerror, future: *FutureObject) !void {
    utils.handle_zig_function_error(err, {});
    const exc = python_c.PyErr_GetRaisedException() orelse return error.PythonError;
    defer python_c.py_decref(exc);
    const future_data = utils.get_data_ptr(Future, future);
    try Future.Python.Result.future_fast_set_exception(future, future_data, exc);
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
    addr: std.posix.sockaddr.storage = undefined,
    addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage),
};

fn sock_accept_callback(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const ad: *AcceptData = @alignCast(@ptrCast(data.user_data.?));
    defer {
        python_c.py_decref(@ptrCast(ad.future));
        python_c.py_decref(@ptrCast(ad.loop));
        ad.allocator.destroy(ad);
    }

    if (data.cancelled()) return;

    if (io_uring_err != .SUCCESS or io_uring_res < 0) {
        const errno_val = if (io_uring_res < 0) -io_uring_res else @intFromEnum(io_uring_err);
        const exc = python_c.PyObject_CallFunction(
            python_c.PyExc_OSError, "is\x00",
            @as(c_int, @intCast(errno_val)),
            "Accept call failed\x00"
        ) orelse return set_future_exception(error.PythonError, ad.future);
        defer python_c.py_decref(exc);
        
        const future_data = utils.get_data_ptr(Future, ad.future);
        try Future.Python.Result.future_fast_set_exception(
ad.future, future_data, exc);
        return;
    }

    const client_fd: std.posix.fd_t = @intCast(io_uring_res);
    
    // Convert addr to Python tuple
    const py_addr = try AddressUtils.toPyAddr(utils.Address.initPosix(@ptrCast(&ad.addr)));
    defer python_c.py_decref(py_addr);
    
    const py_client_fd = python_c.PyLong_FromLong(client_fd) orelse return error.PythonError;
    defer python_c.py_decref(py_client_fd);
    
    const socket_class = utils.PythonImports.socket_class;
    
    const py_family = switch (ad.family) {
        std.posix.AF.INET => utils.PythonImports.py_af_inet,
        std.posix.AF.INET6 => utils.PythonImports.py_af_inet6,
        std.posix.AF.UNIX => utils.PythonImports.py_af_unix,
        else => blk: {
            const py_val = python_c.PyLong_FromLong(ad.family) orelse return error.PythonError;
            break :blk py_val;
        },
    };
    defer if (ad.family != std.posix.AF.INET and ad.family != std.posix.AF.INET6 and ad.family != std.posix.AF.UNIX) {
        python_c.py_decref(py_family);
    };
    
    const py_type = utils.PythonImports.py_sock_stream;
    
    // Create Python socket object
    // socket.socket(family, type, proto, fileno=fd)
    const kwargs = python_c.PyDict_New() orelse return error.PythonError;
    defer python_c.py_decref(kwargs);
    _ = python_c.PyDict_SetItemString(kwargs, "fileno\x00", py_client_fd);
    
    const args = python_c.PyTuple_Pack(2, py_family, py_type) orelse return error.PythonError;
    defer python_c.py_decref(args);
    
    const py_sock = python_c.PyObject_Call(socket_class, args, kwargs) orelse return set_future_exception(error.PythonError, ad.future);
    defer python_c.py_decref(py_sock);

    const result_tuple = python_c.PyTuple_Pack(2, py_sock, py_addr) orelse return error.PythonError;
    defer python_c.py_decref(result_tuple);

    const future_data = utils.get_data_ptr(Future, ad.future);
    try Future.Python.Result.future_fast_set_result(future_data, result_tuple);
}

pub fn loop_sock_accept(
    self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_sock_accept, .{ self.?, args.?[0..@as(usize, @intCast(nargs))] });
}

fn z_loop_sock_accept(self: *LoopObject, args: []const ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len < 1) {
        python_c.raise_python_value_error("socket is required\x00");
        return error.PythonError;
    }

    const py_sock = args[0].?;
    const fileno_attr = python_c.PyObject_GetAttrString(py_sock, "fileno\x00") orelse return error.PythonError;
    defer python_c.py_decref(fileno_attr);
    const py_fd = python_c.PyObject_CallNoArgs(fileno_attr) orelse return error.PythonError;
    defer python_c.py_decref(py_fd);
    const fd_long = python_c.PyLong_AsLong(py_fd);
    // BUG-73: Check for PyErr_Occurred() after PyLong_AsLong.
    // If the Python value is not an integer (or doesn't fit
    // in a C long), PyLong_AsLong returns -1 and sets a
    // Python exception. Without this check, we'd continue
    // with a garbage -1 value and a pending exception.
    if (python_c.PyErr_Occurred() != null) return error.PythonError;
    const fd: std.posix.fd_t = @intCast(fd_long);

    const py_family = python_c.PyObject_GetAttrString(py_sock, "family\x00") orelse return error.PythonError;
    defer python_c.py_decref(py_family);
    const family_long = python_c.PyLong_AsLong(py_family);
    if (python_c.PyErr_Occurred() != null) return error.PythonError;
    const family: i32 = @intCast(family_long);

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

    _ = try loop_data.io.queue(.{
        .SocketAccept = .{
            .socket_fd = fd,
            .addr = @ptrCast(&ad.addr),
            .addrlen = &ad.addrlen,
            .callback = .{
                .func = &sock_accept_callback,
                .cleanup = null,
                .data = .{ .user_data = ad },
            },
        }
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

fn sock_connect_callback(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const scd: *SockConnectData = @alignCast(@ptrCast(data.user_data.?));
    defer {
        python_c.py_decref(@ptrCast(scd.future));
        python_c.py_decref(@ptrCast(scd.loop));
        scd.allocator.destroy(scd);
    }

    if (data.cancelled()) return;

    if (io_uring_err != .SUCCESS and io_uring_err != .ALREADY) {
        const errno_val = if (io_uring_res < 0) -io_uring_res else @intFromEnum(io_uring_err);
        const exc = python_c.PyObject_CallFunction(
            python_c.PyExc_OSError, "is\x00",
            @as(c_int, @intCast(errno_val)),
            "Connect call failed\x00"
        ) orelse return set_future_exception(error.PythonError, scd.future);
        defer python_c.py_decref(exc);
        
        const future_data = utils.get_data_ptr(Future, scd.future);
        try Future.Python.Result.future_fast_set_exception(
scd.future, future_data, exc);
        return;
    }

    const future_data = utils.get_data_ptr(Future, scd.future);
    try Future.Python.Result.future_fast_set_result(future_data,
 python_c.get_py_none());
}

pub fn loop_sock_connect(
    self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_sock_connect, .{ self.?, args.?[0..@as(usize, @intCast(nargs))] });
}

fn z_loop_sock_connect(self: *LoopObject, args: []const ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len < 2) {
        python_c.raise_python_value_error("socket and address are required\x00");
        return error.PythonError;
    }

    const py_sock = args[0].?;
    const py_addr = args[1].?;
    
    const fileno_attr = python_c.PyObject_GetAttrString(py_sock, "fileno\x00") orelse return error.PythonError;
    defer python_c.py_decref(fileno_attr);
    const py_fd = python_c.PyObject_CallNoArgs(fileno_attr) orelse return error.PythonError;
    defer python_c.py_decref(py_fd);
    const fd: std.posix.fd_t = @intCast(python_c.PyLong_AsLong(py_fd));

    const py_family = python_c.PyObject_GetAttrString(py_sock, "family\x00") orelse return error.PythonError;
    defer python_c.py_decref(py_family);
    const family: i32 = @intCast(python_c.PyLong_AsLong(py_family));

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

    _ = try loop_data.io.queue(.{
        .SocketConnect = .{
            .socket_fd = fd,
            .addr = &scd.addr.any,
            .len = scd.addr.getOsSockLen(),
            .callback = .{
                .func = &sock_connect_callback,
                .cleanup = null,
                .data = .{ .user_data = scd },
            },
        }
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

fn sock_recv_callback(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const rd: *SockRecvData = @alignCast(@ptrCast(data.user_data.?));
    defer {
        python_c.py_decref(@ptrCast(rd.future));
        python_c.py_decref(@ptrCast(rd.loop));
        rd.allocator.free(rd.buf);
        rd.allocator.destroy(rd);
    }

    if (data.cancelled()) return;

    if (io_uring_err != .SUCCESS) {
        const errno_val = @intFromEnum(io_uring_err);
        const exc = python_c.PyObject_CallFunction(
            python_c.PyExc_OSError, "is\x00",
            @as(c_int, @intCast(errno_val)),
            "Recv call failed\x00"
        ) orelse return set_future_exception(error.PythonError, rd.future);
        defer python_c.py_decref(exc);
        
        const future_data = utils.get_data_ptr(Future, rd.future);
        try Future.Python.Result.future_fast_set_exception(
rd.future, future_data, exc);
        return;
    }

    const nread: usize = @intCast(@max(io_uring_res, 0));
    const py_data = python_c.PyBytes_FromStringAndSize(rd.buf.ptr, @intCast(nread)) orelse return error.PythonError;
    defer python_c.py_decref(py_data);

    const future_data = utils.get_data_ptr(Future, rd.future);
    try Future.Python.Result.future_fast_set_result(future_data,
 py_data);
}

pub fn loop_sock_recv(
    self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_sock_recv, .{ self.?, args.?[0..@as(usize, @intCast(nargs))] });
}

fn z_loop_sock_recv(self: *LoopObject, args: []const ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len < 2) {
        python_c.raise_python_value_error("socket and nbytes are required\x00");
        return error.PythonError;
    }

    const py_sock = args[0].?;
    const py_nbytes = args[1].?;
    const nbytes: usize = @intCast(python_c.PyLong_AsSsize_t(py_nbytes));

    const fileno_attr = python_c.PyObject_GetAttrString(py_sock, "fileno\x00") orelse return error.PythonError;
    defer python_c.py_decref(fileno_attr);
    const py_fd = python_c.PyObject_CallNoArgs(fileno_attr) orelse return error.PythonError;
    defer python_c.py_decref(py_fd);
    const fd: std.posix.fd_t = @intCast(python_c.PyLong_AsLong(py_fd));

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

    _ = try loop_data.io.queue(.{
        .PerformRead = .{
            .fd = fd,
            .data = .{ .buffer = buf },
            .callback = .{
                .func = &sock_recv_callback,
                .cleanup = null,
                .data = .{ .user_data = rd },
            },
        }
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

fn sock_sendall_callback(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const sd: *SockSendAllData = @alignCast(@ptrCast(data.user_data.?));
    
    if (data.cancelled()) {
        python_c.py_decref(@ptrCast(sd.future));
        python_c.py_decref(@ptrCast(sd.loop));
        sd.allocator.free(sd.data);
        sd.allocator.destroy(sd);
        return;
    }

    if (io_uring_err != .SUCCESS) {
        defer {
            python_c.py_decref(@ptrCast(sd.future));
            python_c.py_decref(@ptrCast(sd.loop));
            sd.allocator.free(sd.data);
            sd.allocator.destroy(sd);
        }
        const errno_val = @intFromEnum(io_uring_err);
        const exc = python_c.PyObject_CallFunction(
            python_c.PyExc_OSError, "is\x00",
            @as(c_int, @intCast(errno_val)),
            "Sendall call failed\x00"
        ) orelse return set_future_exception(error.PythonError, sd.future);
        defer python_c.py_decref(exc);
        
        const future_data = utils.get_data_ptr(Future, sd.future);
        try Future.Python.Result.future_fast_set_exception(
sd.future, future_data, exc);
        return;
    }

    const nwritten: usize = @intCast(@max(io_uring_res, 0));
    sd.offset += nwritten;

    if (sd.offset < sd.data.len) {
        // Re-queue remaining data
        const loop_data = utils.get_data_ptr(Loop, sd.loop);
        _ = try loop_data.io.queue(.{
            .PerformWrite = .{
                .fd = sd.fd,
                .data = sd.data[sd.offset..],
                .callback = .{
                    .func = &sock_sendall_callback,
                    .cleanup = null,
                    .data = .{ .user_data = sd },
                },
            }
        });
        return;
    }

    // Success
    defer {
        python_c.py_decref(@ptrCast(sd.future));
        python_c.py_decref(@ptrCast(sd.loop));
        sd.allocator.free(sd.data);
        sd.allocator.destroy(sd);
    }
    const future_data = utils.get_data_ptr(Future, sd.future);
    try Future.Python.Result.future_fast_set_result(future_data,
 python_c.get_py_none());
}

pub fn loop_sock_sendall(
    self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_sock_sendall, .{ self.?, args.?[0..@as(usize, @intCast(nargs))] });
}

fn z_loop_sock_sendall(self: *LoopObject, args: []const ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len < 2) {
        python_c.raise_python_value_error("socket and data are required\x00");
        return error.PythonError;
    }

    const py_sock = args[0].?;
    const py_data = args[1].?;

    const fileno_attr = python_c.PyObject_GetAttrString(py_sock, "fileno\x00") orelse return error.PythonError;
    defer python_c.py_decref(fileno_attr);
    const py_fd = python_c.PyObject_CallNoArgs(fileno_attr) orelse return error.PythonError;
    defer python_c.py_decref(py_fd);
    const fd: std.posix.fd_t = @intCast(python_c.PyLong_AsLong(py_fd));

    var pbuf: python_c.Py_buffer = undefined;
    if (python_c.PyObject_GetBuffer(py_data, &pbuf, python_c.PyBUF_SIMPLE) < 0) {
        return error.PythonError;
    }
    defer python_c.PyBuffer_Release(&pbuf);

    const loop_data = utils.get_data_ptr(Loop, self);
    const fut = try Future.Python.Constructors.fast_new_future(self);
    errdefer python_c.py_decref(@ptrCast(fut));

    // Copy data to local buffer for async send
    const data_len: usize = @intCast(pbuf.len);
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

    _ = try loop_data.io.queue(.{
        .PerformWrite = .{
            .fd = fd,
            .data = data_buf,
            .callback = .{
                .func = &sock_sendall_callback,
                .cleanup = null,
                .data = .{ .user_data = sd },
            },
        }
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
    addr: std.posix.sockaddr.storage = undefined,
};

fn sock_recvfrom_callback(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const rd: *SockRecvFromData = @alignCast(@ptrCast(data.user_data.?));
    defer {
        python_c.py_decref(@ptrCast(rd.future));
        python_c.py_decref(@ptrCast(rd.loop));
        rd.allocator.free(rd.buf);
        rd.allocator.destroy(rd);
    }

    if (data.cancelled()) return;

    if (io_uring_err != .SUCCESS) {
        const errno_val = @intFromEnum(io_uring_err);
        const exc = python_c.PyObject_CallFunction(
            python_c.PyExc_OSError, "is\x00",
            @as(c_int, @intCast(errno_val)),
            "Recvfrom call failed\x00"
        ) orelse return set_future_exception(error.PythonError, rd.future);
        defer python_c.py_decref(exc);
        
        const future_data = utils.get_data_ptr(Future, rd.future);
        try Future.Python.Result.future_fast_set_exception(
rd.future, future_data, exc);
        return;
    }

    const nread: usize = @intCast(@max(io_uring_res, 0));
    const py_data = python_c.PyBytes_FromStringAndSize(rd.buf.ptr, @intCast(nread)) orelse return error.PythonError;
    defer python_c.py_decref(py_data);
    
    const py_addr = try AddressUtils.toPyAddr(utils.Address.initPosix(@ptrCast(&rd.addr)));
    defer python_c.py_decref(py_addr);

    const result_tuple = python_c.PyTuple_Pack(2, py_data, py_addr) orelse return error.PythonError;
    defer python_c.py_decref(result_tuple);

    const future_data = utils.get_data_ptr(Future, rd.future);
    try Future.Python.Result.future_fast_set_result(future_data,
 result_tuple);
}

pub fn loop_sock_recvfrom(
    self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_sock_recvfrom, .{ self.?, args.?[0..@as(usize, @intCast(nargs))] });
}

fn z_loop_sock_recvfrom(self: *LoopObject, args: []const ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len < 2) {
        python_c.raise_python_value_error("socket and nbytes are required\x00");
        return error.PythonError;
    }

    const py_sock = args[0].?;
    const py_nbytes = args[1].?;
    const nbytes: usize = @intCast(python_c.PyLong_AsSsize_t(py_nbytes));

    const fileno_attr = python_c.PyObject_GetAttrString(py_sock, "fileno\x00") orelse return error.PythonError;
    defer python_c.py_decref(fileno_attr);
    const py_fd = python_c.PyObject_CallNoArgs(fileno_attr) orelse return error.PythonError;
    defer python_c.py_decref(py_fd);
    const fd: std.posix.fd_t = @intCast(python_c.PyLong_AsLong(py_fd));

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
                .cleanup = null,
                .data = .{ .user_data = rd },
            },
        }
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

fn sock_sendto_callback(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const sd: *SockSendToData = @alignCast(@ptrCast(data.user_data.?));
    defer {
        python_c.py_decref(@ptrCast(sd.future));
        python_c.py_decref(@ptrCast(sd.loop));
        sd.allocator.free(sd.buf);
        sd.allocator.destroy(sd);
    }

    if (data.cancelled()) return;

    if (io_uring_err != .SUCCESS) {
        const errno_val = @intFromEnum(io_uring_err);
        const exc = python_c.PyObject_CallFunction(
            python_c.PyExc_OSError, "is\x00",
            @as(c_int, @intCast(errno_val)),
            "Sendto call failed\x00"
        ) orelse return set_future_exception(error.PythonError, sd.future);
        defer python_c.py_decref(exc);
        
        const future_data = utils.get_data_ptr(Future, sd.future);
        try Future.Python.Result.future_fast_set_exception(
sd.future, future_data, exc);
        return;
    }

    const future_data = utils.get_data_ptr(Future, sd.future);
    // BUG-58: Check for null return from PyLong_FromLong. If allocation
    // fails, dereferencing the null would segfault. Propagate as a future
    // exception instead.
    const py_res = python_c.PyLong_FromLong(@intCast(io_uring_res)) orelse
        return set_future_exception(error.PythonError, sd.future);
    try Future.Python.Result.future_fast_set_result(future_data, py_res);
}

pub fn loop_sock_sendto(
    self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_sock_sendto, .{ self.?, args.?[0..@as(usize, @intCast(nargs))] });
}

fn z_loop_sock_sendto(self: *LoopObject, args: []const ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len < 3) {
        python_c.raise_python_value_error("socket, data and address are required\x00");
        return error.PythonError;
    }

    const py_sock = args[0].?;
    const py_data = args[1].?;
    const py_addr = args[2].?;

    const fileno_attr = python_c.PyObject_GetAttrString(py_sock, "fileno\x00") orelse return error.PythonError;
    defer python_c.py_decref(fileno_attr);
    const py_fd = python_c.PyObject_CallNoArgs(fileno_attr) orelse return error.PythonError;
    defer python_c.py_decref(py_fd);
    const fd: std.posix.fd_t = @intCast(python_c.PyLong_AsLong(py_fd));

    const py_family = python_c.PyObject_GetAttrString(py_sock, "family\x00") orelse return error.PythonError;
    defer python_c.py_decref(py_family);
    const family: i32 = @intCast(python_c.PyLong_AsLong(py_family));

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
    @memcpy(data_buf, @as([*]const u8, @ptrCast(pbuf.buf))[0..data_len]);

    const sd = try loop_data.allocator.create(SockSendToData);
    errdefer loop_data.allocator.destroy(sd);
    sd.* = .{
        .future = @ptrCast(python_c.py_newref(@as(PyObject, @ptrCast(fut)))),
        .loop = python_c.py_newref(self),
        .allocator = loop_data.allocator,
        .buf = data_buf,
        .addr = addr,
    };
    
    sd.iov = .{ .base = data_buf.ptr, .len = data_buf.len };
    sd.msg = .{
        .name = &sd.addr.any,
        .namelen = sd.addr.getOsSockLen(),
        .iov = @ptrCast(&sd.iov),
        .iovlen = 1,
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
                .cleanup = null,
                .data = .{ .user_data = sd },
            },
        }
    });

    return fut;
}

// ============================================================
// sock_recv_into
// ============================================================

const SockRecvIntoData = struct {
    future: *FutureObject,
    loop: *LoopObject,
    allocator: std.mem.Allocator,
};

fn sock_recv_into_callback(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const rd: *SockRecvIntoData = @alignCast(@ptrCast(data.user_data.?));
    defer {
        python_c.py_decref(@ptrCast(rd.future));
        python_c.py_decref(@ptrCast(rd.loop));
        rd.allocator.destroy(rd);
    }

    if (data.cancelled()) return;

    if (io_uring_err != .SUCCESS) {
        const errno_val = @intFromEnum(io_uring_err);
        const exc = python_c.PyObject_CallFunction(
            python_c.PyExc_OSError, "is\x00",
            @as(c_int, @intCast(errno_val)),
            "Recv_into call failed\x00"
        ) orelse return set_future_exception(error.PythonError, rd.future);
        defer python_c.py_decref(exc);
        
        const future_data = utils.get_data_ptr(Future, rd.future);
        try Future.Python.Result.future_fast_set_exception(
rd.future, future_data, exc);
        return;
    }

    const nread: usize = @intCast(@max(io_uring_res, 0));
    const future_data = utils.get_data_ptr(Future, rd.future);
    // BUG-58: Check for null return from PyLong_FromLong. If allocation
    // fails, dereferencing the null would segfault. Propagate as a future
    // exception instead.
    const py_nread = python_c.PyLong_FromLong(@intCast(nread)) orelse
        return set_future_exception(error.PythonError, rd.future);
    try Future.Python.Result.future_fast_set_result(future_data, py_nread);
}

pub fn loop_sock_recv_into(
    self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_sock_recv_into, .{ self.?, args.?[0..@as(usize, @intCast(nargs))] });
}

fn z_loop_sock_recv_into(self: *LoopObject, args: []const ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len < 2) {
        python_c.raise_python_value_error("socket and buffer are required\x00");
        return error.PythonError;
    }

    const py_sock = args[0].?;
    const py_buf = args[1].?;

    const fileno_attr = python_c.PyObject_GetAttrString(py_sock, "fileno\x00") orelse return error.PythonError;
    defer python_c.py_decref(fileno_attr);
    const py_fd = python_c.PyObject_CallNoArgs(fileno_attr) orelse return error.PythonError;
    defer python_c.py_decref(py_fd);
    const fd: std.posix.fd_t = @intCast(python_c.PyLong_AsLong(py_fd));

    var pbuf: python_c.Py_buffer = undefined;
    if (python_c.PyObject_GetBuffer(py_buf, &pbuf, python_c.PyBUF_WRITABLE) < 0) {
        return error.PythonError;
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
        .base = .{
            .future = @ptrCast(python_c.py_newref(@as(PyObject, @ptrCast(fut)))),
            .loop = python_c.py_newref(self),
            .allocator = loop_data.allocator,
        },
        .pbuf = pbuf,
    };

    _ = try loop_data.io.queue(.{
        .PerformRead = .{
            .fd = fd,
            .data = .{ .buffer = @as([*]u8, @ptrCast(pbuf.buf))[0..@intCast(pbuf.len)] },
            .callback = .{
                .func = &sock_recv_into_callback_with_buf,
                .cleanup = null,
                .data = .{ .user_data = rd },
            },
        }
    });

    return fut;
}

const SockRecvIntoDataWithBuf = struct {
    base: SockRecvIntoData,
    pbuf: python_c.Py_buffer,
};

fn sock_recv_into_callback_with_buf(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();
    const rd: *SockRecvIntoDataWithBuf = @alignCast(@ptrCast(data.user_data.?));
    defer {
        python_c.PyBuffer_Release(&rd.pbuf);
        python_c.py_decref(@ptrCast(rd.base.future));
        python_c.py_decref(@ptrCast(rd.base.loop));
        rd.base.allocator.destroy(rd);
    }

    if (data.cancelled()) return;

    if (io_uring_err != .SUCCESS) {
        const errno_val = @intFromEnum(io_uring_err);
        const exc = python_c.PyObject_CallFunction(
            python_c.PyExc_OSError, "is\x00",
            @as(c_int, @intCast(errno_val)),
            "Recv_into call failed\x00"
        ) orelse return set_future_exception(error.PythonError, rd.base.future);
        defer python_c.py_decref(exc);
        
        const future_data = utils.get_data_ptr(Future, rd.base.future);
        try Future.Python.Result.future_fast_set_exception(
rd.base.future, future_data, exc);
        return;
    }

    const nread: usize = @intCast(@max(io_uring_res, 0));
    const future_data = utils.get_data_ptr(Future, rd.base.future);
    // BUG-58: Check for null return from PyLong_FromLong. If allocation
    // fails, dereferencing the null would segfault. Propagate as a future
    // exception instead.
    const py_nread = python_c.PyLong_FromLong(@intCast(nread)) orelse
        return set_future_exception(error.PythonError, rd.base.future);
    try Future.Python.Result.future_fast_set_result(future_data, py_nread);
}
