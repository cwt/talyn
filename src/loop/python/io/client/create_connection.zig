const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const CallbackManager = @import("callback_manager");

const Loop = @import("../../../main.zig");
const LoopObject = Loop.Python.LoopObject;

const Future = @import("../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;

const Stream = @import("../../../../transports/stream/main.zig");
const Resolv = @import("../../../dns/resolv.zig");

const SocketCreationData = struct {
    py_host: ?PyObject = null,
    py_port: ?PyObject = null,
    py_ssl: ?PyObject = null,
    py_family: ?PyObject = null,
    py_proto: ?PyObject = null,
    py_local_addr: ?PyObject = null,
    py_server_hostname: ?PyObject = null,
    py_ssl_handshake_timeout: ?PyObject = null,
    py_ssl_shutdown_timeout: ?PyObject = null,
    py_happy_eyeballs_delay: ?PyObject = null, // Happy eyeballs? hahaha
    py_interleave: ?PyObject = null,
    py_all_errors: ?PyObject = null,
    py_dns_timeout: ?PyObject = null,
    dns_timeout: ?Resolv.DnsTimeout = null,

    protocol_factory: ?PyObject = null,
    future: ?*FutureObject = null,
    loop: ?*LoopObject = null,

    comptime {
        python_c.verify_gc_coverage(@This(), &.{});
    }

    pub fn deinit(self: *SocketCreationData) void {
        const loop_data = utils.get_data_ptr(Loop, self.loop.?);
        const allocator = loop_data.allocator;

        if (self.future) |f| {
            python_c.py_decref(@ptrCast(f));
            self.future = null;
        }
        if (self.loop) |l| {
            python_c.py_decref(@ptrCast(l));
            self.loop = null;
        }

        python_c.deinitialize_object_fields(self, &.{});
        allocator.destroy(self);
    }

    pub fn traverse(ptr: ?*anyopaque, visit_ptr: ?*anyopaque, arg: ?*anyopaque) c_int {
        const visit: python_c.visitproc = @ptrCast(visit_ptr);
        const self: ?*SocketCreationData = @alignCast(@ptrCast(ptr));
        if (self) |s| {
            return python_c.py_visit(s, visit, arg);
        }
        return 0;
    }
};

const TransportCreationData = struct {
    protocol_factory: PyObject,
    future: *FutureObject,
    loop: *LoopObject,
    socket_fd: std.posix.fd_t,
    zero_copying: bool,
    fd_created: bool = true,
    owns_fd: bool = true,
    python_payload: CallbackManager.PythonPayload = .{},
    dns_timeout: ?Resolv.DnsTimeout = null,

    comptime {
        python_c.verify_gc_coverage(@This(), &.{});
    }

    pub fn traverse(ptr: ?*anyopaque, visit_ptr: ?*anyopaque, arg: ?*anyopaque) c_int {
        const visit: python_c.visitproc = @ptrCast(visit_ptr);
        const self: ?*TransportCreationData = @alignCast(@ptrCast(ptr));
        if (self) |s| {
            var vret = visit.?(@ptrCast(s.protocol_factory), arg);
            if (vret != 0) return vret;
            vret = visit.?(@ptrCast(s.future), arg);
            if (vret != 0) return vret;
            vret = visit.?(@ptrCast(s.loop), arg);
            if (vret != 0) return vret;
        }
        return 0;
    }
};

fn set_future_exception(err: anyerror, future: *FutureObject) !void {
    utils.handle_zig_function_error(err, {});
    const exc = python_c.PyErr_GetRaisedException() orelse return error.PythonError;
    defer python_c.py_decref(exc);

    const future_data = utils.get_data_ptr(Future, future);
    try Future.Python.Result.future_fast_set_exception(future, future_data, exc);
}

inline fn z_loop_create_connection(
    self: *LoopObject, args: []?PyObject, knames: ?PyObject
) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len < 1) {
        python_c.raise_python_value_error("Invalid number of arguments\x00");
        return error.PythonError;
    } 

    const protocol_factory: PyObject = args[0].?;
    var py_sock: ?PyObject = null;

    var creation_data = SocketCreationData{};

    if (args.len > 1) {
        creation_data.py_host = python_c.py_newref(args[1].?);
    }

    if (args.len > 2) {
        creation_data.py_port = python_c.py_newref(args[2].?);
    }

    try python_c.parse_vector_call_kwargs(
        knames, args.ptr + args.len,
        &.{
            "host\x00",
            "port\x00",
            "ssl\x00",
            "family\x00",
            "proto\x00",
            "sock\x00",
            "local_addr\x00",
            "server_hostname\x00",
            "ssl_handshake_timeout\x00",
            "ssl_shutdown_timeout\x00",
            "happy_eyeballs_delay\x00",
            "interleave\x00",
            "all_errors\x00",
            "dns_timeout\x00"
        },
        &.{
            &creation_data.py_host,
            &creation_data.py_port,
            &creation_data.py_ssl,
            &creation_data.py_family,
            &creation_data.py_proto,
            &py_sock,
            &creation_data.py_local_addr,
            &creation_data.py_server_hostname,
            &creation_data.py_ssl_handshake_timeout,
            &creation_data.py_ssl_shutdown_timeout,
            &creation_data.py_happy_eyeballs_delay,
            &creation_data.py_interleave,
            &creation_data.py_all_errors,
            &creation_data.py_dns_timeout
        },
    );
    defer {
        python_c.py_xdecref(py_sock);
    }
    errdefer python_c.deinitialize_object_fields(&creation_data, &.{"future", "protocol_factory"});

    if (python_c.PyCallable_Check(protocol_factory) <= 0) {
        python_c.raise_python_value_error("Invalid protocol_factory. It must be a callable");
        return error.PythonError;
    }

    const loop_data = utils.get_data_ptr(Loop, self);
    const allocator = loop_data.allocator;

    const fut = try Future.Python.Constructors.fast_new_future(self);
    errdefer python_c.py_decref(@ptrCast(fut));

    if (py_sock) |v| {
        if (creation_data.py_host != null or creation_data.py_port != null) {
            python_c.raise_python_value_error("host/port and sock can not be specified at the same time");
            return error.PythonError;
        }

        const fileno_func = python_c.PyObject_GetAttrString(v, "fileno\x00")
            orelse return error.PythonError;
        defer python_c.py_decref(fileno_func);

        const py_fd = python_c.PyObject_CallNoArgs(fileno_func)
            orelse return error.PythonError;
        defer python_c.py_decref(py_fd);

        const fd = python_c.PyLong_AsLongLong(py_fd);
        // BUG-35: Use `< 0` not `<= 0` so fd 0 (stdin) is
        // accepted. The `<= 0` check rejected stdin as invalid.
        if (fd < 0) {
            _ = python_c.PyErr_Occurred() orelse {
                python_c.raise_python_value_error("Invalid fd\x00");
            };
            return error.PythonError;
        }

        const transport_creation_data = try allocator.create(TransportCreationData);
        errdefer allocator.destroy(transport_creation_data);

        const dns_timeout_val = blk: {
            if (creation_data.py_dns_timeout) |py_dns_timeout| {
                const timeout_val = python_c.PyFloat_AsDouble(py_dns_timeout);
                const result: ?Resolv.DnsTimeout = if (timeout_val == -1.0 and python_c.PyErr_Occurred() != null) null else Resolv.timeout_from_secs(timeout_val);
                break :blk result;
            } else break :blk null;
        };

        transport_creation_data.* = .{
            .protocol_factory = protocol_factory,
            .future = fut,
            .loop = python_c.py_newref(self),
            .socket_fd = @intCast(fd),
            .zero_copying = false, // Caller owns the fd (e.g. accept()'d socket).
            .fd_created = false, // Caller owns the fd (e.g. accept()'d socket).
            .owns_fd = false,     // Don't close the fd on transport close.
            .dns_timeout = dns_timeout_val,
            .python_payload = .{
                .module_ptr = @ptrCast(self),
                .callback_ptr = @ptrCast(fut),
                .traverse = &TransportCreationData.traverse,
            }
        };
        errdefer python_c.py_decref(@ptrCast(self));

        const callback = CallbackManager.Callback{
            .func = &create_transport_and_set_future_result,
            .cleanup = null,
            .data = CallbackManager.CallbackData.init_python(transport_creation_data, &transport_creation_data.python_payload),
        };
        try Loop.Scheduling.Soon.dispatch(loop_data, &callback);

        python_c.deinitialize_object_fields(&creation_data, &.{"future", "protocol_factory"});
        return python_c.py_newref(fut);
    }

    creation_data.loop = python_c.py_newref(self);
    creation_data.future = python_c.py_newref(fut);
    creation_data.protocol_factory = python_c.py_newref(protocol_factory);

    const creation_data_ptr = try allocator.create(SocketCreationData);
    creation_data_ptr.* = creation_data;
    errdefer allocator.destroy(creation_data_ptr);

    const callback = CallbackManager.Callback{
        .func = &try_resolv_host,
        .cleanup = null,
        .data = .{
            .user_data = creation_data_ptr,
        },
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);

    return python_c.py_newref(fut);
}

pub fn loop_create_connection(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_create_connection, .{
            self.?, args.?[0..@as(usize, @intCast(nargs))], knames,
        }
    );
}

// -----------------------------------------------------------------
// STEP#1: Try resolve host

const SocketConnectionMethod = union(enum) {
    Single: usize, // Blocking task id
    HappyEyeballs: []usize, // Blocking task id per address
};

const SocketConnectionData = struct {
    creation_data: *SocketCreationData,
    address_list: ?[]utils.Address,
    local_addr_list: ?[]utils.Address,
    method: SocketConnectionMethod,
    python_payload: CallbackManager.PythonPayload = .{},
    dns_timeout: ?Resolv.DnsTimeout = null,

    comptime {
        python_c.verify_gc_coverage(@This(), &.{ "creation_data", "address_list", "local_addr_list" });
    }

    pub fn deinit(self: *SocketConnectionData) void {
        const loop_data = utils.get_data_ptr(Loop, self.creation_data.loop.?);
        const allocator = loop_data.allocator;

        self.creation_data.deinit();
        if (self.address_list) |v| {
            allocator.free(v);
        }

        if (self.local_addr_list) |v| {
            allocator.free(v);
        }

        allocator.destroy(self);
    }

    pub fn traverse(ptr: ?*anyopaque, visit_ptr: ?*anyopaque, arg: ?*anyopaque) c_int {
        const self: ?*SocketConnectionData = @alignCast(@ptrCast(ptr));
        if (self) |s| {
            return SocketCreationData.traverse(s.creation_data, visit_ptr, arg);
        }
        return 0;
    }
};

fn get_host_slice(data: *SocketCreationData) ![]const u8 {
    const py_host = data.py_host orelse {
        python_c.raise_python_value_error("Host is required");
        return error.PythonError;
    };

    if (!python_c.unicode_check(py_host)) {
        python_c.raise_python_value_error("Host must be a valid string");
        return error.PythonError;
    }

    var host_ptr_lenght: python_c.Py_ssize_t = undefined;
    const host_ptr = python_c.PyUnicode_AsUTF8AndSize(py_host, &host_ptr_lenght)
        orelse return error.PythonError;

    return host_ptr[0..@intCast(host_ptr_lenght)];
}


fn z_try_resolv_host(creation_data: *SocketCreationData) !void {
    const hostname = try get_host_slice(creation_data);

    const loop_data = utils.get_data_ptr(Loop, creation_data.loop.?);
    const allocator = loop_data.allocator;

    const connection_data = try allocator.create(SocketConnectionData);
    errdefer allocator.destroy(connection_data);
    connection_data.creation_data = creation_data;
    connection_data.address_list = null;
    connection_data.local_addr_list = null;
    connection_data.dns_timeout = creation_data.dns_timeout;
    connection_data.python_payload = .{
        .module_ptr = @ptrCast(creation_data.loop.?),
        .callback_ptr = @ptrCast(creation_data.future.?),
        .traverse = &SocketConnectionData.traverse,
    };

    const resolver_callback = CallbackManager.Callback{
        .func = &host_resolved_callback,
        .cleanup = null,
        .data = CallbackManager.CallbackData.init_python(connection_data, &connection_data.python_payload),
    };
    const address_list = try loop_data.dns.lookup(hostname, &resolver_callback, connection_data.dns_timeout) orelse return;

    connection_data.address_list = try allocator.dupe(utils.Address, address_list);
    errdefer allocator.free(connection_data.address_list.?);

    const callback = CallbackManager.Callback{
        .func = &create_socket_connection,
        .cleanup = null,
        .data = CallbackManager.CallbackData.init_python(connection_data, &connection_data.python_payload),
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
}

fn try_resolv_host(data: *const CallbackManager.CallbackData) !void {
    const socket_creation_data_ptr: *SocketCreationData = @alignCast(@ptrCast(data.user_data.?));
    errdefer python_c.deinitialize_object_fields(socket_creation_data_ptr, &.{});

    if (data.cancelled()) {
        python_c.raise_python_runtime_error("Event for trying host resolution cancelled");
        return set_future_exception(error.PythonError, socket_creation_data_ptr.future.?);
    }

    z_try_resolv_host(socket_creation_data_ptr) catch |err| {
        return set_future_exception(err, socket_creation_data_ptr.future.?);
    };
}

// -----------------------------------------------------------------
// Step#2: Process host resolution result

fn z_host_resolved_callback(connection_data: *SocketConnectionData) !void {
    const creation_data = connection_data.creation_data;
    const loop_data = utils.get_data_ptr(Loop, creation_data.loop.?);
    const allocator = loop_data.allocator;

    const host = try get_host_slice(creation_data);
    const address_list = try loop_data.dns.lookup(host, null, creation_data.dns_timeout) orelse {
        python_c.raise_python_runtime_error("Failed to resolve host");
        return set_future_exception(error.PythonError, creation_data.future.?);
    };

    connection_data.address_list = try allocator.dupe(utils.Address, address_list);
    const callback = CallbackManager.Callback{
        .func = &create_socket_connection,
        .cleanup = null,
        .data = CallbackManager.CallbackData.init_python(connection_data, &connection_data.python_payload),
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
}

fn host_resolved_callback(data: *const CallbackManager.CallbackData) !void {
    const connection_data: *SocketConnectionData = @alignCast(@ptrCast(data.user_data.?));
    errdefer connection_data.deinit();

    if (data.cancelled()) {
        python_c.raise_python_runtime_error("Host resolution failed");
        return set_future_exception(error.PythonError, connection_data.creation_data.future.?);
    }

    z_host_resolved_callback(connection_data) catch |err| {
        return set_future_exception(err, connection_data.creation_data.future.?);
    };
}

// -----------------------------------------------------------------
// STEP#3: Create socket and submit connect events

// -----------------------------------------------------------------
// STEP#3: Create socket and submit connect events

fn interleave_address_list(allocator: std.mem.Allocator, address_list: []utils.Address, interleave: usize) !void {
    const tmp_list = try allocator.alloc(utils.Address, address_list.len * 2);
    defer allocator.free(tmp_list);

    var ipv4_addresses: usize = 0;
    var ipv6_addresses: usize = 0;

    for (address_list) |*address| {
        switch (address.any.family) {
            std.posix.AF.INET => {
                tmp_list[ipv4_addresses] = address.*;
                ipv4_addresses += 1;
            },
            std.posix.AF.INET6 => {
                tmp_list[address_list.len + ipv6_addresses] = address.*;
                ipv6_addresses += 1;
            },
            else => return error.InvalidOperation
        }
    }

    if (ipv6_addresses == 0 or ipv4_addresses == 0) {
        return;
    }

    var interleave_count: usize = interleave;
    var ipv4_index: usize = 0;
    var ipv6_index: usize = 0;
    for (address_list) |*v| {
        if (interleave_count == 0 or ipv6_index >= ipv6_addresses) {
            // BUG-72: Previously used `ipv4_addresses -= 1` to
            // pick from the end of the IPv4 section, which
            // reversed the order within the IPv4 family. Now
            // use a forward-running index. Same fix for IPv6.
            v.* = tmp_list[ipv4_index];
            ipv4_index += 1;
            interleave_count = interleave;
        } else {
            v.* = tmp_list[address_list.len + ipv6_index];
            ipv6_index += 1;
            interleave_count -= 1;
        }
    }
}

const MultiConnectState = struct {
    connection_data: *SocketConnectionData,
    pending: usize,
    succeeded: bool,
    timer_scheduled: bool,
    timer_fired: bool,
    failed_count: usize,
    task_ids: std.ArrayListUnmanaged(usize),
    all_errors: bool,
    exceptions: ?PyObject = null,
    python_payload: CallbackManager.PythonPayload = .{},

    comptime {
        python_c.verify_gc_coverage(@This(), &.{ "connection_data" });
    }

    pub fn init(allocator: std.mem.Allocator, connection_data: *SocketConnectionData, all_errors: bool) !*MultiConnectState {
        const self = try allocator.create(MultiConnectState);
        self.* = .{
            .connection_data = connection_data,
            .pending = 0,
            .succeeded = false,
            .timer_scheduled = false,
            .timer_fired = false,
            .failed_count = 0,
            .task_ids = .{ .items = &.{}, .capacity = 0 },
            .all_errors = all_errors,
            .python_payload = .{
                .module_ptr = @ptrCast(connection_data.creation_data.loop.?),
                .callback_ptr = @ptrCast(connection_data.creation_data.future.?),
                .traverse = &MultiConnectState.traverse_raw,
            }
        };
        if (all_errors) {
            self.exceptions = python_c.PyList_New(0) orelse return error.PythonError;
        }
        return self;
    }

    pub fn deinit(self: *MultiConnectState) void {
        const loop = self.connection_data.creation_data.loop.?;
        const loop_data = utils.get_data_ptr(Loop, loop);
        const allocator = loop_data.allocator;

        for (self.task_ids.items) |task_id| {
            _ = Loop.Scheduling.IO.queue(&loop_data.io, .{ .Cancel = task_id }) catch {};
        }
        self.task_ids.deinit(allocator);
        if (self.exceptions) |e| python_c.py_decref(e);
        self.connection_data.deinit();
        allocator.destroy(self);
    }

    pub fn traverse_raw(ptr: ?*anyopaque, visit_ptr: ?*anyopaque, arg: ?*anyopaque) c_int {
        const visit: python_c.visitproc = @ptrCast(visit_ptr);
        const self: ?*MultiConnectState = @alignCast(@ptrCast(ptr));
        if (self) |s| {
            if (s.exceptions) |e| {
                const vret = visit.?(@ptrCast(e), arg);
                if (vret != 0) return vret;
            }

            const creation_data = s.connection_data.creation_data;
            if (creation_data.future) |f| {
                const vret = visit.?(@ptrCast(f), arg);
                if (vret != 0) return vret;
            }
            if (creation_data.loop) |l| {
                const vret = visit.?(@ptrCast(l), arg);
                if (vret != 0) return vret;
            }
            if (creation_data.protocol_factory) |pf| {
                const vret = visit.?(@ptrCast(pf), arg);
                if (vret != 0) return vret;
            }
        }

        return 0;
    }
};

fn create_socket_and_submit_connect_req(address: *const utils.Address, data: *SocketData, loop: *Loop) !usize {
    const flags = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;
    const socket_ret = std.os.linux.socket(address.any.family, flags, std.os.linux.IPPROTO.TCP);
    if (utils.getSyscallErrno(socket_ret) != .SUCCESS) return error.SystemResources;
    const socket_fd: std.posix.fd_t = @intCast(socket_ret);
    errdefer _ = std.os.linux.close(socket_fd);

    data.socket_fd = socket_fd;
    errdefer data.socket_fd = -1;

    const task_id = try Loop.Scheduling.IO.queue(
        &loop.io, .{
            .SocketConnect = .{
                .addr = &address.any,
                .len = address.getOsSockLen(),
                .socket_fd = socket_fd,
                .callback = .{
                    .func = &socket_connected_callback,
                    .cleanup = null,
                    .data = CallbackManager.CallbackData.init_python(data, &data.python_payload),
                },
            },
        }
    );

    return task_id;
}

fn submit_connect_for_address(
    mcs: *MultiConnectState, address: *const utils.Address, allocator: std.mem.Allocator, loop: *Loop
) !void {
    const socket_data = try allocator.create(SocketData);
    errdefer allocator.destroy(socket_data);
    socket_data.* = .{
        .multi_state = mcs,
        .socket_fd = -1,
        .python_payload = .{
            .module_ptr = @ptrCast(mcs.connection_data.creation_data.loop.?),
            .callback_ptr = @ptrCast(mcs.connection_data.creation_data.future.?),
            .traverse = &SocketData.traverse,
        }
    };

    const task_id = create_socket_and_submit_connect_req(address, socket_data, loop) catch |err| {
        allocator.destroy(socket_data);
        return err;
    };
    try mcs.task_ids.append(allocator, task_id);
    mcs.pending += 1;
}

fn schedule_remaining_connects_callback(data: *const CallbackManager.CallbackData) !void {
    const mcs: *MultiConnectState = @alignCast(@ptrCast(data.user_data.?));
    if (data.cancelled() or mcs.succeeded) return;

    mcs.timer_fired = true;

    const connection_data = mcs.connection_data;
    const creation_data = connection_data.creation_data;
    const loop = creation_data.loop.?;
    const loop_data = utils.get_data_ptr(Loop, loop);
    const allocator = loop_data.allocator;

    const address_list = connection_data.address_list.?;
    for (address_list[1..]) |*addr| {
        submit_connect_for_address(mcs, addr, allocator, loop_data) catch |err| {
            return set_future_exception(err, creation_data.future.?);
        };
    }
}

fn z_create_socket_connection(data: *SocketConnectionData, connection_submitted: *usize) !void {
    const creation_data = data.creation_data;
    const address_list = data.address_list orelse {
        python_c.raise_python_runtime_error("No addresses to connect to");
        return error.PythonError;
    };

    const interleave: usize = blk: {
        const py_interleave = creation_data.py_interleave orelse break :blk 0;
        const value = python_c.PyLong_AsUnsignedLongLong(py_interleave);
        if (@as(c_longlong, @bitCast(value)) == -1) {
            if (python_c.PyErr_Occurred()) |_| {
                return error.PythonError;
            }
        }
        break :blk @intCast(value);
    };

    const loop = creation_data.loop.?;
    const loop_data = utils.get_data_ptr(Loop, loop);
    const allocator = loop_data.allocator;

    if (interleave > 0) {
        try interleave_address_list(allocator, address_list, interleave);
    }

    const all_errors: bool = blk: {
        const py_all_errors = creation_data.py_all_errors orelse break :blk false;
        break :blk python_c.PyObject_IsTrue(py_all_errors) != 0;
    };

    const mcs = try MultiConnectState.init(allocator, data, all_errors);
    errdefer mcs.deinit();

    var delay: f64 = 0.25;
    if (creation_data.py_happy_eyeballs_delay) |py_delay| {
        if (interleave == 0) {
            try interleave_address_list(allocator, address_list, 1);
        }
        delay = python_c.PyFloat_AsDouble(py_delay);
        const eps = comptime std.math.floatEps(f64);
        // BUG-51: Use `@abs(delay + 1.0) < eps` (symmetric)
        // instead of `(delay + 1.0) < eps` (asymmetric). The
        // previous check only caught values where delay+1.0 was
        // very slightly above 0; values like -0.9999 (delay+1.0
        // = 0.0001, > eps) would not be caught.
        if (@abs(delay + 1.0) < eps) {
            if (python_c.PyErr_Occurred() != null) {
                return error.PythonError;
            }
            delay = 0;
        }
    }

    if (address_list.len == 0) {
        python_c.raise_python_runtime_error("No addresses resolved");
        return set_future_exception(error.PythonError, creation_data.future.?);
    }

    const port: u16 = blk: {
        const py_port = creation_data.py_port orelse break :blk 0;
        const value = python_c.PyLong_AsInt(py_port);
        if (value == -1) {
            if (python_c.PyErr_Occurred()) |_| return error.PythonError;
        }
        break :blk @intCast(value);
    };
    for (address_list) |*addr| {
        addr.setPort(port);
    }

    // Submit first address immediately
    try submit_connect_for_address(mcs, &address_list[0], allocator, loop_data);
    connection_submitted.* += 1;

    // Schedule remaining addresses after happy eyeballs delay
    if (address_list.len > 1 and delay > 0) {
        const callback = CallbackManager.Callback{
            .func = &schedule_remaining_connects_callback,
            .cleanup = null,
            .data = CallbackManager.CallbackData.init_python(mcs, &mcs.python_payload),
        };
        const seconds: u64 = @intFromFloat(@floor(delay));
        const nanoseconds: u64 = @intFromFloat((delay - @floor(delay)) * 1e9);
        const duration: std.os.linux.timespec = .{
            .sec = @intCast(seconds),
            .nsec = @intCast(nanoseconds),
        };
        const timer_task_id = try Loop.Scheduling.IO.queue(&loop_data.io, .{
            .WaitTimer = .{
                .duration = duration,
                .delay_type = .Relative,
                .callback = callback,
            },
        });
        try mcs.task_ids.append(allocator, timer_task_id);
        mcs.timer_scheduled = true;
    } else {
        // Submit all remaining immediately (no delay)
        for (address_list[1..]) |*addr| {
            try submit_connect_for_address(mcs, addr, allocator, loop_data);
            connection_submitted.* += 1;
        }
    }
}

fn create_socket_connection(data: *const CallbackManager.CallbackData) !void {
    const socket_creation_data: *SocketConnectionData = @alignCast(@ptrCast(data.user_data.?));

    var connections_submitted: usize = 0;
    errdefer {
        if (connections_submitted == 0) {
            socket_creation_data.deinit();
        }
    }

    if (data.cancelled()) {
        python_c.raise_python_runtime_error("Event for socket creation cancelled");
        return set_future_exception(error.PythonError, socket_creation_data.creation_data.future.?);
    }

    z_create_socket_connection(socket_creation_data, &connections_submitted) catch |err| {
        return set_future_exception(err, socket_creation_data.creation_data.future.?);
    };
}

// -----------------------------------------------------------------
// STEP#4: Socket connected (or failed to connect)

const SocketData = struct {
    multi_state: *MultiConnectState,
    socket_fd: std.posix.fd_t,
    python_payload: CallbackManager.PythonPayload = .{},

    comptime {
        python_c.verify_gc_coverage(@This(), &.{ "multi_state" });
    }

    pub fn traverse(ptr: ?*anyopaque, visit_ptr: ?*anyopaque, arg: ?*anyopaque) c_int {
        const self: ?*SocketData = @alignCast(@ptrCast(ptr));
        if (self) |s| {
            return MultiConnectState.traverse_raw(s.multi_state, visit_ptr, arg);
        }
        return 0;
    }
};

fn socket_connected_callback(data: *const CallbackManager.CallbackData) !void {
    const socket_data: *SocketData = @alignCast(@ptrCast(data.user_data.?));
    const mcs = socket_data.multi_state;
    const fd = socket_data.socket_fd;

    const creation_data = mcs.connection_data.creation_data;
    const loop = creation_data.loop.?;
    const loop_data = utils.get_data_ptr(Loop, loop);
    const allocator = loop_data.allocator;
    allocator.destroy(socket_data);

    mcs.pending -= 1;

    if (mcs.succeeded or data.cancelled()) {
        if (fd >= 0) _ = std.os.linux.close(fd);
        if (mcs.pending == 0) mcs.deinit();
        return;
    }

    const io_uring_res = data.io_uring_res();
    const io_uring_err = data.io_uring_err();

    if (io_uring_err != .SUCCESS or io_uring_res < 0) {
        if (mcs.all_errors) {
            const errno_val = if (io_uring_res < 0) -io_uring_res else @intFromEnum(io_uring_err);
            const exc = python_c.PyObject_CallFunction(
                python_c.PyExc_OSError, "is\x00",
                @as(c_int, @intCast(errno_val)),
                "Connect call failed\x00"
            ) orelse return error.PythonError;
            defer python_c.py_decref(exc);
            if (python_c.PyList_Append(mcs.exceptions.?, exc) != 0) return error.PythonError;
        }

        mcs.failed_count += 1;
        if (fd >= 0) _ = std.os.linux.close(fd);

        if (mcs.pending == 0) {
            if (mcs.timer_scheduled and !mcs.timer_fired) {
                return;
            }

            const future = creation_data.future.?;
            const future_data = utils.get_data_ptr(Future, future);

            if (mcs.all_errors) {
                const builtins = python_c.PyImport_ImportModule("builtins\x00") orelse return error.PythonError;
                defer python_c.py_decref(builtins);
                const exc_group_cls = python_c.PyObject_GetAttrString(builtins, "ExceptionGroup\x00") orelse return error.PythonError;
                defer python_c.py_decref(exc_group_cls);

                const msg = python_c.PyUnicode_FromString("Multiple connection failures\x00") orelse return error.PythonError;
                defer python_c.py_decref(msg);

                const exc_group = python_c.PyObject_CallFunctionObjArgs(exc_group_cls, msg, mcs.exceptions.?, @as(?*python_c.PyObject, null))
                    orelse return error.PythonError;
                defer python_c.py_decref(exc_group);

                try Future.Python.Result.future_fast_set_exception(@ptrCast(future), future_data, exc_group);
            } else {
                const errno_val = if (io_uring_res < 0) -io_uring_res else @intFromEnum(io_uring_err);
                const exc = python_c.PyObject_CallFunction(
                    python_c.PyExc_OSError, "is\x00",
                    @as(c_int, @intCast(errno_val)),
                    "Connect call failed\x00"
                ) orelse {
                    const exc = python_c.PyErr_GetRaisedException() orelse return error.PythonError;
                    defer python_c.py_decref(exc);
                    try Future.Python.Result.future_fast_set_exception(
                        @ptrCast(future), future_data,
                        exc
                    );
                    mcs.deinit();
                    return error.PythonError;
                };
                try Future.Python.Result.future_fast_set_exception(@ptrCast(future), future_data, exc);
            }

            mcs.deinit();
        }
        return;
    }

    // Success — mark and create transport (synchronous)
    mcs.succeeded = true;

    for (mcs.task_ids.items) |task_id| {
        _ = loop_data.io.queue(.{ .Cancel = task_id }) catch {};
    }

    var transport_creation_data = TransportCreationData{
        .protocol_factory = creation_data.protocol_factory.?,
        .future = creation_data.future.?,
        .loop = creation_data.loop.?,
        .socket_fd = fd,
        .zero_copying = false,
        .fd_created = true,
    };
    defer {
        if (transport_creation_data.fd_created) {
            _ = std.os.linux.close(@intCast(transport_creation_data.socket_fd));
        }
    }

    z_create_transport_and_set_future_result(&transport_creation_data) catch |err| {
        return set_future_exception(err, creation_data.future.?);
    };
    transport_creation_data.fd_created = false;
    return;
}

// -----------------------------------------------------------------
// STEP#5: Create transport and set future result

fn z_create_transport_and_set_future_result(data: *const TransportCreationData) !void {
    const protocol = python_c.PyObject_CallNoArgs(data.protocol_factory) orelse return error.PythonError;
    errdefer python_c.py_decref(protocol);

    const transport = try Stream.Constructors.new_stream_transport_with_owns_fd(
        protocol, data.loop, data.socket_fd, data.zero_copying, data.owns_fd
    );
    errdefer python_c.py_decref(@ptrCast(transport));

    const connection_made_func = python_c.PyObject_GetAttrString(protocol, "connection_made\x00")
        orelse return error.PythonError;
    defer python_c.py_decref(connection_made_func);

    const ret = python_c.PyObject_CallOneArg(connection_made_func, @ptrCast(transport))
        orelse return error.PythonError;
    defer python_c.py_decref(ret);

    const result_tuple = python_c.PyTuple_Pack(2, @as(PyObject, @ptrCast(transport)), protocol)
        orelse return error.PythonError;
    defer python_c.py_decref(result_tuple);

    // Decref local references as PyTuple_Pack increments them
    python_c.py_decref(@ptrCast(transport));
    python_c.py_decref(protocol);

    const future_data = utils.get_data_ptr(Future, data.future);
    try Future.Python.Result.future_fast_set_result(future_data, result_tuple);
}

fn create_transport_and_set_future_result(
    data: *const CallbackManager.CallbackData
) !void {
    const transport_creation_data_ptr: *TransportCreationData = @alignCast(@ptrCast(data.user_data.?));

    const loop = transport_creation_data_ptr.loop;
    const loop_data = utils.get_data_ptr(Loop, loop);
    const allocator = loop_data.allocator;

    defer allocator.destroy(transport_creation_data_ptr);

    const transport_creation_data = transport_creation_data_ptr.*;
    defer {
        python_c.py_decref(transport_creation_data.protocol_factory);
        python_c.py_decref(@ptrCast(transport_creation_data.loop));
        python_c.py_decref(@ptrCast(transport_creation_data.future));

        if (transport_creation_data.fd_created) {
            _ = std.os.linux.close(@intCast(transport_creation_data.socket_fd));
        }
    }
    if (data.cancelled()) return;

    z_create_transport_and_set_future_result(&transport_creation_data) catch |err| {
        return set_future_exception(err, transport_creation_data.future);
    };
}

// -----------------------------------------------------------------

test "interleave_address_list with mixed IPv4 and IPv6" {
    const allocator = std.testing.allocator;
    const addresses = try allocator.alloc(utils.Address, 5);
    defer allocator.free(addresses);

    addresses[0] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[1] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[2] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[3] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[4] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };

    try interleave_address_list(allocator, addresses, 1);

    try std.testing.expectEqual(std.posix.AF.INET6, addresses[0].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[1].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[2].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[3].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[4].any.family);
}

test "interleave_address_list with only IPv4" {
    const allocator = std.testing.allocator;
    const addresses = try allocator.alloc(utils.Address, 3);
    defer allocator.free(addresses);

    addresses[0] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[1] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[2] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };

    try interleave_address_list(allocator, addresses, 1);

    // Should remain unchanged
    try std.testing.expectEqual(std.posix.AF.INET, addresses[0].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[1].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[2].any.family);
}

test "interleave_address_list with only IPv6" {
    const allocator = std.testing.allocator;
    const addresses = try allocator.alloc(utils.Address, 3);
    defer allocator.free(addresses);

    addresses[0] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[1] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[2] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };

    try interleave_address_list(allocator, addresses, 1);

    // Should remain unchanged
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[0].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[1].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[2].any.family);
}

test "interleave_address_list with different interleave values" {
    const allocator = std.testing.allocator;
    const addresses = try allocator.alloc(utils.Address, 5);
    defer allocator.free(addresses);

    addresses[0] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[1] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[2] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[3] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[4] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };

    try interleave_address_list(allocator, addresses, 2);

    try std.testing.expectEqual(std.posix.AF.INET6, addresses[0].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[1].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[2].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[3].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[4].any.family);
}

test "interleave_address_list with multiple IPv6 addresses and interleave value 2" {
    const allocator = std.testing.allocator;
    const addresses = try allocator.alloc(utils.Address, 7);
    defer allocator.free(addresses);

    addresses[0] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[1] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[2] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[3] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[4] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[5] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[6] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };

    try interleave_address_list(allocator, addresses, 2);

    try std.testing.expectEqual(std.posix.AF.INET6, addresses[0].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[1].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[2].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[3].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[4].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[5].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[6].any.family);
}
