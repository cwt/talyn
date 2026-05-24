const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const utils = @import("utils");
const CallbackManager = @import("callback_manager");
const Loop = @import("../../../main.zig");
const LoopObject = Loop.Python.LoopObject;
const Future = @import("../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;
const DatagramTransport = @import("../../../../transports/datagram/main.zig");

const DatagramCreationData = struct {
    future: *FutureObject,
    loop: *LoopObject,
    protocol_factory: PyObject,
    py_local_addr: ?PyObject = null,
    py_remote_addr: ?PyObject = null,
    py_family: ?PyObject = null,
    py_reuse_port: ?PyObject = null,
    py_allow_broadcast: ?PyObject = null,
    py_sock: ?PyObject = null,

    local_addresses: ?[]utils.Address = null,
    remote_addresses: ?[]utils.Address = null,

    pub fn deinit(self: *DatagramCreationData) void {
        const loop_data = utils.get_data_ptr(Loop, self.loop);
        const allocator = loop_data.allocator;

        python_c.py_decref(@ptrCast(self.future));
        python_c.py_decref(@ptrCast(self.loop));
        python_c.py_decref(self.protocol_factory);
        python_c.py_xdecref(self.py_local_addr);
        python_c.py_xdecref(self.py_remote_addr);
        python_c.py_xdecref(self.py_family);
        python_c.py_xdecref(self.py_reuse_port);
        python_c.py_xdecref(self.py_allow_broadcast);
        python_c.py_xdecref(self.py_sock);

        if (self.local_addresses) |addrs| allocator.free(addrs);
        if (self.remote_addresses) |addrs| allocator.free(addrs);

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

inline fn z_loop_create_datagram_endpoint(
    self: *LoopObject, args: []?PyObject, knames: ?PyObject
) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len < 1) {
        python_c.raise_python_value_error("protocol_factory is required");
        return error.PythonError;
    }

    const protocol_factory: PyObject = args[0].?;
    const fut = try Future.Python.Constructors.fast_new_future(self);
    errdefer python_c.py_decref(@ptrCast(fut));

    const loop_data = utils.get_data_ptr(Loop, self);
    const allocator = loop_data.allocator;

    const dcd = try allocator.create(DatagramCreationData);
    errdefer allocator.destroy(dcd);

    dcd.* = .{
        .future = @ptrCast(python_c.py_newref(@as(PyObject, @ptrCast(fut)))),
        .loop = python_c.py_newref(self),
        .protocol_factory = python_c.py_newref(protocol_factory),
    };

    try python_c.parse_vector_call_kwargs(
        knames, args.ptr + args.len,
        &.{ "local_addr", "remote_addr", "family", "reuse_port", "allow_broadcast", "sock" },
        &.{ &dcd.py_local_addr, &dcd.py_remote_addr, &dcd.py_family, &dcd.py_reuse_port, &dcd.py_allow_broadcast, &dcd.py_sock },
    );
    python_c.py_xincref(dcd.py_local_addr);
    python_c.py_xincref(dcd.py_remote_addr);
    python_c.py_xincref(dcd.py_family);
    python_c.py_xincref(dcd.py_reuse_port);
    python_c.py_xincref(dcd.py_allow_broadcast);
    python_c.py_xincref(dcd.py_sock);

    if (python_c.PyCallable_Check(protocol_factory) <= 0) {
        dcd.deinit();
        python_c.raise_python_type_error("protocol_factory must be callable");
        return error.PythonError;
    }

    const callback = CallbackManager.Callback{
        .func = &resolve_local_addr,
        .cleanup = null,
        .data = .{ .user_data = dcd },
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);

    return fut;
}

fn get_addr_tuple(addr: PyObject) !struct { host: []const u8, port: u16 } {
    if (python_c.PyTuple_Check(addr) <= 0) return error.PythonError;
    const py_host = python_c.PyTuple_GetItem(addr, 0) orelse return error.PythonError;
    const py_port = python_c.PyTuple_GetItem(addr, 1) orelse return error.PythonError;

    var c_size: python_c.Py_ssize_t = 0;
    const host_ptr = python_c.PyUnicode_AsUTF8AndSize(py_host, &c_size) orelse return error.PythonError;
    return .{
        .host = host_ptr[0..@intCast(c_size)],
        .port = @intCast(python_c.PyLong_AsInt(py_port)),
    };
}

fn resolve_local_addr(data: *const CallbackManager.CallbackData) !void {
    const dcd: *DatagramCreationData = @alignCast(@ptrCast(data.user_data.?));
    if (data.cancelled) return dcd.deinit();

    const loop_data = utils.get_data_ptr(Loop, dcd.loop);

    if (dcd.py_local_addr) |la| {
        const addr_info = get_addr_tuple(la) catch |err| return set_future_exception(err, dcd.future);
        const resolver_callback = CallbackManager.Callback{
            .func = &local_addr_resolved_callback,
            .cleanup = null,
            .data = .{ .user_data = dcd },
        };
        const addresses = try loop_data.dns.lookup(addr_info.host, &resolver_callback) orelse return;
        dcd.local_addresses = try loop_data.allocator.dupe(utils.Address, addresses);
        // Update ports
        for (dcd.local_addresses.?) |*addr| addr.setPort(addr_info.port);
    }

    const callback = CallbackManager.Callback{
        .func = &resolve_remote_addr,
        .cleanup = null,
        .data = .{ .user_data = dcd },
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
}

fn local_addr_resolved_callback(data: *const CallbackManager.CallbackData) !void {
    const dcd: *DatagramCreationData = @alignCast(@ptrCast(data.user_data.?));
    if (data.cancelled) return dcd.deinit();

    const loop_data = utils.get_data_ptr(Loop, dcd.loop);
    const addr_info = get_addr_tuple(dcd.py_local_addr.?) catch |err| return set_future_exception(err, dcd.future);
    const addresses = try loop_data.dns.lookup(addr_info.host, null) orelse return set_future_exception(error.PythonError, dcd.future);
    dcd.local_addresses = try loop_data.allocator.dupe(utils.Address, addresses);
    for (dcd.local_addresses.?) |*addr| addr.setPort(addr_info.port);

    const callback = CallbackManager.Callback{
        .func = &resolve_remote_addr,
        .cleanup = null,
        .data = .{ .user_data = dcd },
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
}

fn resolve_remote_addr(data: *const CallbackManager.CallbackData) !void {
    const dcd: *DatagramCreationData = @alignCast(@ptrCast(data.user_data.?));
    if (data.cancelled) return dcd.deinit();

    const loop_data = utils.get_data_ptr(Loop, dcd.loop);

    if (dcd.py_remote_addr) |ra| {
        const addr_info = get_addr_tuple(ra) catch |err| return set_future_exception(err, dcd.future);
        const resolver_callback = CallbackManager.Callback{
            .func = &remote_addr_resolved_callback,
            .cleanup = null,
            .data = .{ .user_data = dcd },
        };
        const addresses = try loop_data.dns.lookup(addr_info.host, &resolver_callback) orelse return;
        dcd.remote_addresses = try loop_data.allocator.dupe(utils.Address, addresses);
        for (dcd.remote_addresses.?) |*addr| addr.setPort(addr_info.port);
    }

    const callback = CallbackManager.Callback{
        .func = &create_endpoint,
        .cleanup = null,
        .data = .{ .user_data = dcd },
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
}

fn remote_addr_resolved_callback(data: *const CallbackManager.CallbackData) !void {
    const dcd: *DatagramCreationData = @alignCast(@ptrCast(data.user_data.?));
    if (data.cancelled) return dcd.deinit();

    const loop_data = utils.get_data_ptr(Loop, dcd.loop);
    const addr_info = get_addr_tuple(dcd.py_remote_addr.?) catch |err| return set_future_exception(err, dcd.future);
    const addresses = try loop_data.dns.lookup(addr_info.host, null) orelse return set_future_exception(error.PythonError, dcd.future);
    dcd.remote_addresses = try loop_data.allocator.dupe(utils.Address, addresses);
    for (dcd.remote_addresses.?) |*addr| addr.setPort(addr_info.port);

    const callback = CallbackManager.Callback{
        .func = &create_endpoint,
        .cleanup = null,
        .data = .{ .user_data = dcd },
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
}

fn create_endpoint(data: *const CallbackManager.CallbackData) !void {
    const dcd: *DatagramCreationData = @alignCast(@ptrCast(data.user_data.?));
    defer dcd.deinit();
    if (data.cancelled) return;

    // Pick family
    var family: u32 = std.posix.AF.INET;
    if (dcd.py_family) |f| {
        family = @intCast(python_c.PyLong_AsLong(f));
    } else if (dcd.remote_addresses) |addrs| {
        family = addrs[0].any.family;
    } else if (dcd.local_addresses) |addrs| {
        family = addrs[0].any.family;
    }

    const socket_ret = std.os.linux.socket(family, @as(u32, @intCast(std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC)), 0);
    if (std.posix.errno(socket_ret) != .SUCCESS) return error.SystemResources;
    const fd: std.posix.fd_t = @intCast(socket_ret);
    errdefer _ = std.os.linux.close(fd);

    if (dcd.py_reuse_port) |rp| {
        if (python_c.PyObject_IsTrue(rp) != 0) {
            const val: c_int = 1;
            try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, std.mem.asBytes(&val));
        }
    }

    if (dcd.py_allow_broadcast) |ab| {
        if (python_c.PyObject_IsTrue(ab) != 0) {
            const val: c_int = 1;
            try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.BROADCAST, std.mem.asBytes(&val));
        }
    }

    if (dcd.local_addresses) |addrs| {
        // Try each until one binds
        var bound = false;
        for (addrs) |*addr| {
            if (addr.any.family != family) continue;
            const bind_ret = std.os.linux.bind(fd, @ptrCast(&addr.any), addr.getOsSockLen());
            if (std.posix.errno(bind_ret) == .SUCCESS) {
                bound = true;
                break;
            }
        }
        if (!bound) return set_future_exception(error.SystemResources, dcd.future);
    }

    if (dcd.remote_addresses) |addrs| {
        // Connect to first matching
        var connected = false;
        for (addrs) |*addr| {
            if (addr.any.family != family) continue;
            const connect_ret = std.os.linux.connect(fd, @ptrCast(&addr.any), addr.getOsSockLen());
            if (std.posix.errno(connect_ret) == .SUCCESS) {
                connected = true;
                break;
            }
        }
        if (!connected) return set_future_exception(error.SystemResources, dcd.future);
    }

    const protocol = python_c.PyObject_CallNoArgs(dcd.protocol_factory) orelse return error.PythonError;
    errdefer python_c.py_decref(protocol);

    const transport = try DatagramTransport.Constructors.new_datagram_transport(protocol, dcd.loop, fd);
    errdefer python_c.py_decref(@ptrCast(transport));

    const connection_made = python_c.PyObject_GetAttrString(protocol, "connection_made\x00") orelse return error.PythonError;
    defer python_c.py_decref(connection_made);
    const ret = python_c.PyObject_CallOneArg(connection_made, @ptrCast(transport)) orelse return error.PythonError;
    python_c.py_decref(ret);

    try DatagramTransport.ReadTransport.queue_read(transport);
const result_tuple = python_c.PyTuple_Pack(2, @as(PyObject, @ptrCast(transport)), protocol)
    orelse return error.PythonError;
defer python_c.py_decref(result_tuple);

// Decref local references as PyTuple_Pack increments them
python_c.py_decref(@ptrCast(transport));
python_c.py_decref(protocol);

const future_data = utils.get_data_ptr(Future, dcd.future);
try Future.Python.Result.future_fast_set_result(future_data, result_tuple);
}


pub fn loop_create_datagram_endpoint(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_create_datagram_endpoint, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames },
    );
}
