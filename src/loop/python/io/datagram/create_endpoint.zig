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
const Resolv = @import("../../../dns/resolv.zig");

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
    dns_timeout: ?Resolv.DnsTimeout = null,

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

const set_future_exception = Future.Python.Result.set_future_exception;

/// BUG-355: `set_future_exception` STEALS the pending Python exception
/// (`PyErr_GetRaisedException`); if none is set it silently does nothing
/// and the future stays pending forever (infinite hang on `await`).
fn ensure_exception(err: anyerror) void {
    if (python_c.PyErr_Occurred() == null) {
        if (err == error.PythonError) {
            python_c.raise_python_runtime_error("DNS resolution failed");
        } else {
            utils.handle_zig_function_error(err, {});
        }
    }
}

/// BUG-355: fail the endpoint creation — resolve the future (unless it is
/// already resolved/cancelled), release the creation data, and surface the
/// error. Every failure path of the DNS resolution chain must go through
/// here: `set_future_exception` returns void, so a plain return leaked
/// `dcd` and left the awaiting coroutine hanging forever.
fn fail_endpoint(err: anyerror, dcd: *DatagramCreationData) !void {
    defer dcd.deinit();
    const future = dcd.future;
    const future_data = utils.get_data_ptr(Future, future);
    if (future_data.status != .pending) {
        // Already resolved or cancelled — nothing to notify.
        return;
    }
    ensure_exception(err);
    return set_future_exception(err, future);
}

inline fn z_loop_create_datagram_endpoint(self: *LoopObject, args: []?PyObject, knames: ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len < 1) {
        python_c.raise_python_value_error("protocol_factory is required");
        return error.PythonError;
    }

    const protocol_factory: PyObject = args[0].?;
    if (python_c.PyCallable_Check(protocol_factory) <= 0) {
        python_c.raise_python_type_error("protocol_factory must be callable");
        return error.PythonError;
    }

    var py_local_addr: ?PyObject = null;
    var py_remote_addr: ?PyObject = null;
    var py_family: ?PyObject = null;
    var py_reuse_port: ?PyObject = null;
    var py_allow_broadcast: ?PyObject = null;
    var py_sock: ?PyObject = null;
    var py_dns_timeout: ?PyObject = null;

    // BUG-352: every populated slot below owns a reference —
    // `parse_vector_call_kwargs` returns NEW references.
    try python_c.parse_vector_call_kwargs(
        knames,
        args.ptr + args.len,
        &.{ "local_addr", "remote_addr", "family", "reuse_port", "allow_broadcast", "sock", "dns_timeout" },
        &.{ &py_local_addr, &py_remote_addr, &py_family, &py_reuse_port, &py_allow_broadcast, &py_sock, &py_dns_timeout },
    );
    errdefer {
        python_c.py_xdecref(py_local_addr);
        python_c.py_xdecref(py_remote_addr);
        python_c.py_xdecref(py_family);
        python_c.py_xdecref(py_reuse_port);
        python_c.py_xdecref(py_allow_broadcast);
        python_c.py_xdecref(py_sock);
        python_c.py_xdecref(py_dns_timeout);
    }

    var dns_timeout: ?Resolv.DnsTimeout = null;
    if (py_dns_timeout) |pt| {
        dns_timeout = try Resolv.parse_dns_timeout(pt);
        // Done with the value — it was converted to a plain struct.
        python_c.py_decref(pt);
        py_dns_timeout = null;
    }

    const fut = try Future.Python.Constructors.fast_new_future(self);
    errdefer python_c.py_decref(@ptrCast(fut));

    const loop_data = utils.get_data_ptr(Loop, self);
    const allocator = loop_data.allocator;

    const dcd = try allocator.create(DatagramCreationData);

    // BUG-352: TRANSFER the owned references instead of taking a second
    // `py_newref` — that second ref was never balanced by deinit(),
    // leaking one reference per keyword argument on every call. The
    // locals are nulled afterwards so the errdefer above becomes a no-op.
    dcd.* = .{
        .future = @ptrCast(python_c.py_newref(@as(PyObject, @ptrCast(fut)))),
        .loop = python_c.py_newref(self),
        .protocol_factory = python_c.py_newref(protocol_factory),
        .py_local_addr = py_local_addr,
        .py_remote_addr = py_remote_addr,
        .py_family = py_family,
        .py_reuse_port = py_reuse_port,
        .py_allow_broadcast = py_allow_broadcast,
        .py_sock = py_sock,
        .dns_timeout = dns_timeout,
    };
    py_local_addr = null;
    py_remote_addr = null;
    py_family = null;
    py_reuse_port = null;
    py_allow_broadcast = null;
    py_sock = null;
    errdefer dcd.deinit();

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
    const port_val = python_c.PyLong_AsInt(py_port);
    if (port_val == -1 and python_c.PyErr_Occurred() != null) return error.PythonError;
    // BUG-361: negative/huge ports panicked the u16 narrowing.
    if (port_val < 0 or port_val > 65535) {
        python_c.raise_python_value_error("port must be 0-65535\x00");
        return error.PythonError;
    }
    return .{
        .host = host_ptr[0..@intCast(c_size)],
        .port = @intCast(port_val),
    };
}

fn resolve_local_addr(data: *const CallbackManager.CallbackData) !void {
    const dcd: *DatagramCreationData = @ptrCast(@alignCast(data.user_data.?));
    // BUG-355: a cancelled dispatch must still resolve the future and
    // release the creation data — the silent return left the future
    // pending forever.
    if (data.cancelled()) return fail_endpoint(error.PythonError, dcd);

    const loop_data = utils.get_data_ptr(Loop, dcd.loop);

    if (dcd.py_sock != null) {
        const callback = CallbackManager.Callback{
            .func = &resolve_remote_addr,
            .cleanup = null,
            .data = .{ .user_data = dcd },
        };
        Loop.Scheduling.Soon.dispatch(loop_data, &callback) catch |err| return fail_endpoint(err, dcd);
        return;
    }

    if (dcd.py_local_addr) |la| {
        const addr_info = get_addr_tuple(la) catch |err| return fail_endpoint(err, dcd);
        const resolver_callback = CallbackManager.Callback{
            .func = &local_addr_resolved_callback,
            .cleanup = null,
            .data = .{ .user_data = dcd },
        };
        // Note: a null return WITH a registered resolver callback means
        // the query was queued asynchronously — the callback chain
        // continues there.
        const addresses = (loop_data.dns.lookup(addr_info.host, &resolver_callback, dcd.dns_timeout) catch |err| return fail_endpoint(err, dcd)) orelse return;
        dcd.local_addresses = loop_data.allocator.dupe(utils.Address, addresses) catch |err| return fail_endpoint(err, dcd);
        // Update ports
        for (dcd.local_addresses.?) |*addr| addr.setPort(addr_info.port);
    }

    const callback = CallbackManager.Callback{
        .func = &resolve_remote_addr,
        .cleanup = null,
        .data = .{ .user_data = dcd },
    };
    Loop.Scheduling.Soon.dispatch(loop_data, &callback) catch |err| return fail_endpoint(err, dcd);
}

fn local_addr_resolved_callback(data: *const CallbackManager.CallbackData) !void {
    const dcd: *DatagramCreationData = @ptrCast(@alignCast(data.user_data.?));
    if (data.cancelled()) return fail_endpoint(error.PythonError, dcd);

    const loop_data = utils.get_data_ptr(Loop, dcd.loop);
    const addr_info = get_addr_tuple(dcd.py_local_addr.?) catch |err| return fail_endpoint(err, dcd);
    // BUG-355: with a null resolver callback this is a synchronous
    // lookup failure — raise an exception before set_future_exception
    // (which silently does nothing without a pending exception) and
    // release the creation data.
    const addresses = (loop_data.dns.lookup(addr_info.host, null, dcd.dns_timeout) catch |err| return fail_endpoint(err, dcd)) orelse return fail_endpoint(error.PythonError, dcd);
    dcd.local_addresses = loop_data.allocator.dupe(utils.Address, addresses) catch |err| return fail_endpoint(err, dcd);
    for (dcd.local_addresses.?) |*addr| addr.setPort(addr_info.port);

    const callback = CallbackManager.Callback{
        .func = &resolve_remote_addr,
        .cleanup = null,
        .data = .{ .user_data = dcd },
    };
    Loop.Scheduling.Soon.dispatch(loop_data, &callback) catch |err| return fail_endpoint(err, dcd);
}

fn resolve_remote_addr(data: *const CallbackManager.CallbackData) !void {
    const dcd: *DatagramCreationData = @ptrCast(@alignCast(data.user_data.?));
    // BUG-355: see resolve_local_addr — resolve the future and release
    // the creation data instead of leaving it pending forever.
    if (data.cancelled()) return fail_endpoint(error.PythonError, dcd);

    const loop_data = utils.get_data_ptr(Loop, dcd.loop);

    if (dcd.py_remote_addr) |ra| {
        const addr_info = get_addr_tuple(ra) catch |err| return fail_endpoint(err, dcd);
        const resolver_callback = CallbackManager.Callback{
            .func = &remote_addr_resolved_callback,
            .cleanup = null,
            .data = .{ .user_data = dcd },
        };
        const addresses = (loop_data.dns.lookup(addr_info.host, &resolver_callback, dcd.dns_timeout) catch |err| return fail_endpoint(err, dcd)) orelse return;
        dcd.remote_addresses = loop_data.allocator.dupe(utils.Address, addresses) catch |err| return fail_endpoint(err, dcd);
        for (dcd.remote_addresses.?) |*addr| addr.setPort(addr_info.port);
    }

    const callback = CallbackManager.Callback{
        .func = &create_endpoint,
        .cleanup = null,
        .data = .{ .user_data = dcd },
    };
    Loop.Scheduling.Soon.dispatch(loop_data, &callback) catch |err| return fail_endpoint(err, dcd);
}

fn remote_addr_resolved_callback(data: *const CallbackManager.CallbackData) !void {
    const dcd: *DatagramCreationData = @ptrCast(@alignCast(data.user_data.?));
    if (data.cancelled()) return fail_endpoint(error.PythonError, dcd);

    const loop_data = utils.get_data_ptr(Loop, dcd.loop);

    const addr_info = get_addr_tuple(dcd.py_remote_addr.?) catch |err| return fail_endpoint(err, dcd);
    // BUG-355: see local_addr_resolved_callback — synchronous lookup
    // failure needs an exception before set_future_exception, and the
    // creation data must be released.
    const addresses = (loop_data.dns.lookup(addr_info.host, null, dcd.dns_timeout) catch |err| return fail_endpoint(err, dcd)) orelse return fail_endpoint(error.PythonError, dcd);
    dcd.remote_addresses = loop_data.allocator.dupe(utils.Address, addresses) catch |err| return fail_endpoint(err, dcd);
    for (dcd.remote_addresses.?) |*addr| addr.setPort(addr_info.port);

    const callback = CallbackManager.Callback{
        .func = &create_endpoint,
        .cleanup = null,
        .data = .{ .user_data = dcd },
    };
    Loop.Scheduling.Soon.dispatch(loop_data, &callback) catch |err| return fail_endpoint(err, dcd);
}

fn z_create_endpoint(dcd: *DatagramCreationData) !void {
    var owns_fd = true;
    var fd: std.posix.fd_t = undefined;
    var family: u32 = std.posix.AF.INET;

    if (dcd.py_sock) |sock_obj| {
        const raw_fd = python_c.PyObject_CallMethod(sock_obj, "fileno\x00", null) orelse return error.PythonError;
        defer python_c.py_decref(raw_fd);
        const lfd = python_c.PyLong_AsLong(raw_fd);
        const dup_ret = std.os.linux.dup(@intCast(lfd));
        if (utils.getSyscallErrno(dup_ret) != .SUCCESS) return error.SystemResources;
        fd = @intCast(dup_ret);
        // Set nonblocking and cloexec
        const flags = std.os.linux.fcntl(fd, std.os.linux.F.GETFL, 0);
        _ = std.os.linux.fcntl(fd, std.os.linux.F.SETFL, flags | std.posix.SOCK.NONBLOCK);
        _ = std.os.linux.fcntl(fd, std.os.linux.F.SETFD, std.os.linux.FD_CLOEXEC);

        var sock_addr: std.posix.sockaddr.storage = undefined;
        var sock_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
        if (std.os.linux.getsockname(fd, @ptrCast(&sock_addr), &sock_len) == 0) {
            const sa: *const std.posix.sockaddr = @ptrCast(&sock_addr);
            family = sa.family;
        }
    } else {
        // Pick family
        if (dcd.py_family) |f| {
            const f_val = python_c.PyLong_AsLong(f);
            if (python_c.PyErr_Occurred() != null) return error.PythonError;
            // BUG-361: negative/out-of-range families panicked the u32
            // narrowing.
            family = try utils.checkedNarrow(u32, f_val, "invalid address family\x00");
        } else if (dcd.remote_addresses) |addrs| {
            family = addrs[0].any.family;
        } else if (dcd.local_addresses) |addrs| {
            family = addrs[0].any.family;
        }

        const socket_ret = std.os.linux.socket(family, @as(u32, @intCast(std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC)), 0);
        const socket_err = utils.getSyscallErrno(socket_ret);
        if (socket_err != .SUCCESS) return utils.socketSyscallError(socket_err);
        fd = @intCast(socket_ret);
    }
    defer {
        if (owns_fd) _ = std.os.linux.close(fd);
    }

    if (dcd.py_reuse_port) |rp| {
        const rc = python_c.PyObject_IsTrue(rp);
        if (rc < 0) return error.PythonError;
        if (rc == 1) {
            const val: c_int = 1;
            try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, std.mem.asBytes(&val));
        }
    }

    if (dcd.py_allow_broadcast) |ab| {
        const rc = python_c.PyObject_IsTrue(ab);
        if (rc < 0) return error.PythonError;
        if (rc == 1) {
            const val: c_int = 1;
            try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.BROADCAST, std.mem.asBytes(&val));
        }
    }

    if (dcd.py_sock == null and dcd.local_addresses != null) {
        // Try each until one binds
        const addrs = dcd.local_addresses.?;
        var bound = false;
        for (addrs) |*addr| {
            const bind_ret = std.os.linux.bind(fd, @ptrCast(&addr.any), addr.getOsSockLen());
            if (utils.getSyscallErrno(bind_ret) == .SUCCESS) {
                bound = true;
                break;
            }
        }
        if (!bound) return error.SystemResources;
    }

    if (dcd.remote_addresses) |addrs| {
        // Connect to first matching
        var connected = false;
        for (addrs) |*addr| {
            if (addr.any.family != family) continue;
            const connect_ret = std.os.linux.connect(fd, @ptrCast(&addr.any), addr.getOsSockLen());
            if (utils.getSyscallErrno(connect_ret) == .SUCCESS) {
                connected = true;
                break;
            }
        }
        if (!connected) return error.SystemResources;
    }

    const protocol = python_c.PyObject_CallNoArgs(dcd.protocol_factory) orelse return error.PythonError;
    defer python_c.py_decref(protocol);

    const transport = try DatagramTransport.Constructors.new_datagram_transport(protocol, dcd.loop, fd);
    owns_fd = false;
    defer python_c.py_decref(@ptrCast(transport));

    const connection_made = python_c.PyObject_GetAttrString(protocol, "connection_made\x00") orelse return error.PythonError;
    defer python_c.py_decref(connection_made);
    const ret = python_c.PyObject_CallOneArg(connection_made, @ptrCast(transport)) orelse return error.PythonError;
    defer python_c.py_decref(ret);

    try DatagramTransport.ReadTransport.queue_read(transport);
    const result_tuple = python_c.PyTuple_Pack(2, @as(PyObject, @ptrCast(transport)), protocol) orelse return error.PythonError;
    defer python_c.py_decref(result_tuple);

    const future_data = utils.get_data_ptr(Future, dcd.future);
    try Future.Python.Result.future_fast_set_result(future_data, result_tuple);
}

fn create_endpoint(data: *const CallbackManager.CallbackData) !void {
    const dcd: *DatagramCreationData = @ptrCast(@alignCast(data.user_data.?));
    defer dcd.deinit();
    if (data.cancelled()) {
        // BUG-355: the DNS layer cancelled this dispatch (e.g. query send
        // failed on all nameservers) — the silent `return` left the
        // future pending forever. Resolve it with an exception instead
        // (the `defer dcd.deinit()` above owns the cleanup here — do NOT
        // use fail_endpoint, it would deinit twice).
        const future = dcd.future;
        const future_data = utils.get_data_ptr(Future, future);
        if (future_data.status == .pending) {
            python_c.raise_python_runtime_error("DNS resolution cancelled");
            return set_future_exception(error.PythonError, future);
        }
        return;
    }

    z_create_endpoint(dcd) catch |err| {
        // BUG-355: ensure an exception is pending — several error paths
        // (setsockopt, queue failures) return Zig errors without setting
        // one, and set_future_exception silently no-ops then, leaving
        // the future pending forever.
        ensure_exception(err);
        return set_future_exception(err, dcd.future);
    };
}

pub fn loop_create_datagram_endpoint(self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_create_datagram_endpoint,
        .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames },
    );
}
