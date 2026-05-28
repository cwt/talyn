const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const CallbackManager = @import("callback_manager");

const Loop = @import("../../../main.zig");
const LoopObject = Loop.Python.LoopObject;

const Future = @import("../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;

const StreamServer = @import("../../../../transports/streamserver/main.zig");

const ServerCreationData = struct {
    py_host: ?PyObject = null,
    py_port: ?PyObject = null,
    py_family: ?PyObject = null,
    py_flags: ?PyObject = null,
    py_sock: ?PyObject = null,
    py_backlog: ?PyObject = null,
    py_reuse_address: ?PyObject = null,
    py_reuse_port: ?PyObject = null,
    protocol_factory: ?PyObject = null,
    future: ?*FutureObject = null,
    loop: ?*LoopObject = null,

    pub fn deinit(self: *ServerCreationData) void {
        const loop_data = utils.get_data_ptr(Loop, self.loop.?);
        const allocator = loop_data.allocator;

        python_c.deinitialize_object_fields(self, &.{});
        allocator.destroy(self);
    }
};

const ServerSocketData = struct {
    creation_data: *ServerCreationData,
    address_list: ?[]utils.Address = null,
    socket_fd: std.posix.fd_t = -1,

    pub fn deinit(self: *ServerSocketData) void {
        const loop_data = utils.get_data_ptr(Loop, self.creation_data.loop.?);
        const allocator = loop_data.allocator;

        if (self.address_list) |v| {
            allocator.free(v);
        }
        self.creation_data.deinit();
        allocator.destroy(self);
    }
};

fn set_future_exception(err: anyerror, future: *FutureObject) !void {
    utils.handle_zig_function_error(err, {});
    const exc = python_c.PyErr_GetRaisedException() orelse return error.PythonError;
    defer python_c.py_decref(exc);
    const future_data = utils.get_data_ptr(Future, future);
    try Future.Python.Result.future_fast_set_exception(future, future_data, exc);
}

fn get_host_slice(data: *ServerCreationData) ![]const u8 {
    const py_host = data.py_host orelse {
        python_c.raise_python_value_error("Host is required\x00");
        return error.PythonError;
    };

    if (!python_c.unicode_check(py_host)) {
        python_c.raise_python_value_error("Host must be a valid string\x00");
        return error.PythonError;
    }

    var host_ptr_length: python_c.Py_ssize_t = undefined;
    const host_ptr = python_c.PyUnicode_AsUTF8AndSize(py_host, &host_ptr_length)
        orelse return error.PythonError;

    return host_ptr[0..@intCast(host_ptr_length)];
}

inline fn z_loop_create_server(
    self: *LoopObject, args: []?PyObject, knames: ?PyObject
) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len < 2) {
        python_c.raise_python_value_error("protocol_factory and host are required\x00");
        return error.PythonError;
    }

    const protocol_factory: PyObject = args[0].?;

    if (python_c.PyCallable_Check(protocol_factory) <= 0) {
        python_c.raise_python_type_error("protocol_factory must be callable\x00");
        return error.PythonError;
    }

    var creation_data = ServerCreationData{};

    // Parse kwargs first to check for sock
    try python_c.parse_vector_call_kwargs(
        knames, args.ptr + args.len,
        &.{ "family\x00", "flags\x00", "sock\x00", "backlog\x00", "reuse_address\x00", "reuse_port\x00" },
        &.{ &creation_data.py_family, &creation_data.py_flags, &creation_data.py_sock, &creation_data.py_backlog, &creation_data.py_reuse_address, &creation_data.py_reuse_port },
    );

    // Only set host/port if sock is not provided
    if (creation_data.py_sock == null) {
        creation_data.py_host = python_c.py_newref(args[1].?);
        if (args.len > 2) creation_data.py_port = python_c.py_newref(args[2].?);
    }

    const loop_data = utils.get_data_ptr(Loop, self);
    const allocator = loop_data.allocator;

    const fut = try Future.Python.Constructors.fast_new_future(self);
    errdefer python_c.py_decref(@ptrCast(fut));

    creation_data.loop = python_c.py_newref(self);
    creation_data.future = python_c.py_newref(fut);
    creation_data.protocol_factory = python_c.py_newref(protocol_factory);

    const creation_data_ptr = try allocator.create(ServerCreationData);
    creation_data_ptr.* = creation_data;
    errdefer allocator.destroy(creation_data_ptr);

    if (creation_data.py_sock) |sock| {
        const fileno_func = python_c.PyObject_GetAttrString(sock, "fileno\x00")
            orelse return error.PythonError;
        defer python_c.py_decref(fileno_func);

        const py_fd = python_c.PyObject_CallNoArgs(fileno_func)
            orelse return error.PythonError;
        defer python_c.py_decref(py_fd);

        const fd = python_c.PyLong_AsLongLong(py_fd);
        if (fd < 0) {
            _ = python_c.PyErr_Occurred() orelse {
                python_c.raise_python_value_error("Invalid fd\x00");
            };
            return error.PythonError;
        }

        const getsockname_func = python_c.PyObject_GetAttrString(sock, "getsockname\x00")
            orelse return error.PythonError;
        defer python_c.py_decref(getsockname_func);

        const py_addr = python_c.PyObject_CallNoArgs(getsockname_func)
            orelse return error.PythonError;
        defer python_c.py_decref(py_addr);

        const py_family_attr = python_c.PyObject_GetAttrString(sock, "family\x00")
            orelse return error.PythonError;
        defer python_c.py_decref(py_family_attr);

        const family = python_c.PyLong_AsLong(py_family_attr);
        if (family == -1 and python_c.PyErr_Occurred() != null) return error.PythonError;

        const addr: utils.Address = switch (@as(i32, @intCast(family))) {
            std.posix.AF.INET => blk: {
                if (python_c.PyTuple_Check(py_addr) == 0) return error.InvalidAddress;
                const py_ip = python_c.PyTuple_GetItem(py_addr, 0) orelse return error.PythonError;
                const py_port_item = python_c.PyTuple_GetItem(py_addr, 1) orelse return error.PythonError;
                const port_val = python_c.PyLong_AsInt(py_port_item);
                if (port_val == -1 and python_c.PyErr_Occurred() != null) return error.PythonError;

                var ip_bytes: [4]u8 = undefined;
                const ip_str = python_c.PyUnicode_AsUTF8AndSize(py_ip, null) orelse return error.PythonError;
                var ip_parts = std.mem.splitSequence(u8, ip_str[0..std.mem.len(ip_str)], ".");
                var i: usize = 0;
                while (ip_parts.next()) |part| : (i += 1) {
                    if (i >= 4) break;
                    ip_bytes[i] = try std.fmt.parseInt(u8, part, 10);
                }
                break :blk utils.Address.initIp4(ip_bytes, @intCast(port_val));
            },
            std.posix.AF.INET6 => blk: {
                if (python_c.PyTuple_Check(py_addr) == 0) return error.InvalidAddress;
                const py_ip = python_c.PyTuple_GetItem(py_addr, 0) orelse return error.PythonError;
                const py_port_item = python_c.PyTuple_GetItem(py_addr, 1) orelse return error.PythonError;
                const port_val = python_c.PyLong_AsInt(py_port_item);
                if (port_val == -1 and python_c.PyErr_Occurred() != null) return error.PythonError;

                const ip_str = python_c.PyUnicode_AsUTF8AndSize(py_ip, null) orelse return error.PythonError;
                break :blk try utils.Address.parseIp6(ip_str[0..std.mem.len(ip_str)], @intCast(port_val));
            },
            else => return error.UnsupportedAddressFamily,
        };

        const server_data = try allocator.create(ServerSocketData);
        errdefer allocator.destroy(server_data);
        server_data.* = .{
            .creation_data = creation_data_ptr,
            .address_list = try allocator.dupe(utils.Address, &.{addr}),
            .socket_fd = @intCast(fd),
        };
        errdefer allocator.free(server_data.address_list.?);

        // Duplicate the fd so the StreamServer owns its own copy
        // The original fd is owned by the Python socket object which may be GC'd
        const dup_fd = std.os.linux.dup(@intCast(fd));
        if (@as(i32, @intCast(dup_fd)) < 0) {
            return error.SystemResources;
        }
        server_data.socket_fd = @intCast(dup_fd);

        const callback = CallbackManager.Callback{
            .func = &create_server_socket,
            .cleanup = null,
            .data = .{
                .user_data = server_data,
            },
        };
        try Loop.Scheduling.Soon.dispatch(loop_data, &callback);

        python_c.deinitialize_object_fields(creation_data_ptr, &.{"future", "protocol_factory"});
        return python_c.py_newref(fut);
    }

    const callback = CallbackManager.Callback{
        .func = &try_resolve_server_host,
        .cleanup = null,
        .data = .{
            .user_data = creation_data_ptr,
        },
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);

    return python_c.py_newref(fut);
}

// -----------------------------------------------------------------
// STEP 1: Resolve host

fn z_try_resolve_server_host(creation_data: *ServerCreationData) !void {
    const hostname = try get_host_slice(creation_data);

    const loop_data = utils.get_data_ptr(Loop, creation_data.loop.?);
    const allocator = loop_data.allocator;

    const server_data = try allocator.create(ServerSocketData);
    errdefer allocator.destroy(server_data);
    server_data.creation_data = creation_data;
    server_data.address_list = null;

    if (hostname.len == 0) {
        const allow_ipv6 = loop_data.dns.ipv6_supported;
        var list = std.ArrayList(utils.Address){ .items = &.{}, .capacity = 0 };
        try list.append(allocator, utils.Address.initIp4(.{0, 0, 0, 0}, 0));
        if (allow_ipv6) {
            try list.append(allocator, utils.Address.initIp6(.{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, 0, 0, 0));
        }
        server_data.address_list = try list.toOwnedSlice(allocator);
        const callback = CallbackManager.Callback{
            .func = &create_server_socket,
            .cleanup = null,
            .data = .{
                .user_data = server_data,
            },
        };
        try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
        return;
    }

    const resolver_callback = CallbackManager.Callback{
        .func = &server_host_resolved_callback,
        .cleanup = null,
        .data = .{
            .user_data = server_data,
        },
    };
    const address_list = try loop_data.dns.lookup(hostname, &resolver_callback) orelse return;

    server_data.address_list = try allocator.dupe(utils.Address, address_list);
    errdefer allocator.free(server_data.address_list.?);

    const callback = CallbackManager.Callback{
        .func = &create_server_socket,
        .cleanup = null,
        .data = .{
            .user_data = server_data,
        },
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
}

fn try_resolve_server_host(data: *const CallbackManager.CallbackData) !void {
    const creation_data: *ServerCreationData = @alignCast(@ptrCast(data.user_data.?));
    errdefer creation_data.deinit();

    if (data.cancelled()) {
        python_c.raise_python_runtime_error("Event for server host resolution cancelled\x00");
        return set_future_exception(error.PythonError, creation_data.future.?);
    }

    z_try_resolve_server_host(creation_data) catch |err| {
        return set_future_exception(err, creation_data.future.?);
    };
}

// -----------------------------------------------------------------
// STEP 2: Host resolved

fn z_server_host_resolved_callback(server_data: *ServerSocketData) !void {
    const creation_data = server_data.creation_data;
    const loop_data = utils.get_data_ptr(Loop, creation_data.loop.?);
    const allocator = loop_data.allocator;

    const host = try get_host_slice(creation_data);
    const address_list = try loop_data.dns.lookup(host, null) orelse {
        python_c.raise_python_runtime_error("Failed to resolve host\x00");
        return set_future_exception(error.PythonError, creation_data.future.?);
    };

    if (address_list.len == 0) {
        python_c.raise_python_runtime_error("No addresses to bind to\x00");
        return set_future_exception(error.PythonError, creation_data.future.?);
    }

    server_data.address_list = try allocator.dupe(utils.Address, address_list);
    errdefer allocator.free(server_data.address_list.?);

    const callback = CallbackManager.Callback{
        .func = &create_server_socket,
        .cleanup = null,
        .data = .{
            .user_data = server_data,
        },
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
}

fn server_host_resolved_callback(data: *const CallbackManager.CallbackData) !void {
    const server_data: *ServerSocketData = @alignCast(@ptrCast(data.user_data.?));
    errdefer server_data.deinit();

    if (data.cancelled()) {
        python_c.raise_python_runtime_error("Server host resolution cancelled\x00");
        return set_future_exception(error.PythonError, server_data.creation_data.future.?);
    }

    z_server_host_resolved_callback(server_data) catch |err| {
        return set_future_exception(err, server_data.creation_data.future.?);
    };
}

// -----------------------------------------------------------------
// STEP 3: Create socket, bind, listen, start serving

fn z_create_server_socket(server_data: *ServerSocketData) !void {
    const creation_data = server_data.creation_data;
    const address_list = server_data.address_list orelse {
        python_c.raise_python_runtime_error("No addresses to bind to\x00");
        return set_future_exception(error.PythonError, creation_data.future.?);
    };

    const port: u16 = blk: {
        if (creation_data.py_port) |p| {
            const val = python_c.PyLong_AsInt(p);
            if (val == -1 and python_c.PyErr_Occurred() != null) return error.PythonError;
            break :blk @intCast(val);
        }
        break :blk 0;
    };

    const requested_family: ?i32 = if (creation_data.py_family) |f| blk: {
        const val = python_c.PyLong_AsLong(f);
        if (val == -1 and python_c.PyErr_Occurred() != null) return error.PythonError;
        break :blk @intCast(val);
    } else null;

    const backlog: c_int = blk: {
        if (creation_data.py_backlog) |b| {
            break :blk @intCast(python_c.PyLong_AsInt(b));
        }
        break :blk 100;
    };

    const reuse_address: bool = if (creation_data.py_reuse_address) |r|
        python_c.PyObject_IsTrue(r) != 0
    else
        true;

    const reuse_port: bool = if (creation_data.py_reuse_port) |r|
        python_c.PyObject_IsTrue(r) != 0
    else
        false;

    const servers_list = python_c.PyList_New(0) orelse return error.PythonError;
    errdefer python_c.py_decref(servers_list);

    var last_err: ?anyerror = null;

    for (address_list) |addr| {
        if (requested_family) |rf| {
            if (addr.any.family != rf) continue;
        }

        var addr_with_port = addr;
        addr_with_port.setPort(port);

        const fd: std.posix.fd_t = if (server_data.socket_fd >= 0)
            server_data.socket_fd
        else blk: {
            const flags: u32 = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;
            const fd_ret = std.os.linux.socket(addr_with_port.any.family, flags, std.os.linux.IPPROTO.TCP);
            if (utils.getSyscallErrno(fd_ret) != .SUCCESS) {
                last_err = error.SystemResources;
                continue;
            }
            break :blk @intCast(fd_ret);
        };

        if (server_data.socket_fd < 0) {
            errdefer _ = std.os.linux.close(fd);

            if (reuse_address) {
                const val: c_int = 1;
                _ = std.os.linux.setsockopt(fd, std.os.linux.SOL.SOCKET, std.os.linux.SO.REUSEADDR, @as([*]const u8, @ptrCast(std.mem.asBytes(&val))), @sizeOf(c_int));
            }
            if (reuse_port) {
                const val: c_int = 1;
                _ = std.os.linux.setsockopt(fd, std.os.linux.SOL.SOCKET, std.os.linux.SO.REUSEPORT, @as([*]const u8, @ptrCast(std.mem.asBytes(&val))), @sizeOf(c_int));
            }

            const bind_rc = std.os.linux.bind(fd, @ptrCast(&addr_with_port.any), addr_with_port.getOsSockLen());
            std.debug.print("Z_BIND FD: {}, RET: {}, ERR: {}\n", .{fd, bind_rc, utils.getSyscallErrno(bind_rc)});
            if (utils.getSyscallErrno(bind_rc) != .SUCCESS) {
                if (utils.getSyscallErrno(bind_rc) == .ADDRNOTAVAIL) {
                    last_err = error.AddressNotAvailable;
                } else {
                    last_err = error.SystemResources;
                }
                continue;
            }

            const listen_rc = std.os.linux.listen(fd, @intCast(backlog));
            if (utils.getSyscallErrno(listen_rc) != .SUCCESS) {
                last_err = error.SystemResources;
                continue;
            }
        }

        const py_fd = python_c.PyLong_FromLong(@intCast(fd)) orelse return error.PythonError;
        defer python_c.py_decref(py_fd);

        const py_family_obj = python_c.PyLong_FromLong(@intCast(addr_with_port.any.family)) orelse return error.PythonError;
        defer python_c.py_decref(py_family_obj);

        const py_backlog_obj = python_c.PyLong_FromLong(@intCast(backlog)) orelse return error.PythonError;
        defer python_c.py_decref(py_backlog_obj);

        const protocol_factory = creation_data.protocol_factory.?;
        const loop_obj = creation_data.loop.?;

        const server = python_c.PyObject_CallFunction(
            @as(*python_c.PyObject, @ptrCast(StreamServer.StreamServerType.?)), "OOOOO\x00",
            @as(*python_c.PyObject, @ptrCast(loop_obj)), protocol_factory, py_fd, py_family_obj, py_backlog_obj
        ) orelse return error.PythonError;
        errdefer python_c.py_decref(server);

        const server_ptr: *StreamServer.StreamServerObject = @ptrCast(server);

        StreamServer.start_serving(server_ptr) catch |err| {
            python_c.py_decref(server);
            last_err = err;
            continue;
        };

        if (python_c.PyList_Append(servers_list, server) != 0) return error.PythonError;
        python_c.py_decref(server);
    }

    if (python_c.PyList_Size(servers_list) == 0) {
        if (last_err) |err| {
            if (err == error.AddressNotAvailable) {
                const exception = python_c.PyObject_CallFunction(
                    python_c.PyExc_OSError, "is\x00",
                    @as(c_int, 99), // EADDRNOTAVAIL
                    "Cannot assign requested address\x00"
                ) orelse return error.PythonError;
                python_c.PyErr_SetRaisedException(exception);
                return error.PythonError;
            }
            return err;
        }
        python_c.raise_python_runtime_error("Failed to bind to any address\x00");
        return error.PythonError;
    }
    const future_data = utils.get_data_ptr(Future, server_data.creation_data.future.?);
    try Future.Python.Result.future_fast_set_result(future_data, servers_list);
    python_c.py_decref(servers_list);
}

fn create_server_socket(data: *const CallbackManager.CallbackData) !void {
    const server_data: *ServerSocketData = @alignCast(@ptrCast(data.user_data.?));
    defer server_data.deinit();

    if (data.cancelled()) {
        python_c.raise_python_runtime_error("Server socket creation cancelled\x00");
        return set_future_exception(error.PythonError, server_data.creation_data.future.?);
    }

    z_create_server_socket(server_data) catch |err| {
        return set_future_exception(err, server_data.creation_data.future.?);
    };
}

// -----------------------------------------------------------------

pub fn loop_create_server(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_create_server, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames },
    );
}
