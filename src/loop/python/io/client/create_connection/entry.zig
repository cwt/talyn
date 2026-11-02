const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const CallbackManager = @import("callback_manager");

const Loop = @import("../../../../main.zig");
const LoopObject = Loop.Python.LoopObject;

const Future = @import("../../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;

const Resolv = @import("../../../../dns/resolv.zig");
const types = @import("types.zig");
const SocketCreationData = types.SocketCreationData;
const TransportCreationData = types.TransportCreationData;
const resolve_mod = @import("resolve.zig");
const transport_mod = @import("transport.zig");

inline fn z_loop_create_connection(self: *LoopObject, args: []?PyObject, knames: ?PyObject) !*FutureObject {
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
        knames,
        args.ptr + args.len,
        &.{ "host\x00", "port\x00", "ssl\x00", "family\x00", "proto\x00", "sock\x00", "local_addr\x00", "server_hostname\x00", "ssl_handshake_timeout\x00", "ssl_shutdown_timeout\x00", "happy_eyeballs_delay\x00", "interleave\x00", "all_errors\x00", "dns_timeout\x00" },
        &.{ &creation_data.py_host, &creation_data.py_port, &creation_data.py_ssl, &creation_data.py_family, &creation_data.py_proto, &py_sock, &creation_data.py_local_addr, &creation_data.py_server_hostname, &creation_data.py_ssl_handshake_timeout, &creation_data.py_ssl_shutdown_timeout, &creation_data.py_happy_eyeballs_delay, &creation_data.py_interleave, &creation_data.py_all_errors, &creation_data.py_dns_timeout },
    );
    defer {
        python_c.py_xdecref(py_sock);
    }
    errdefer python_c.deinitialize_object_fields(&creation_data, &.{});

    var dns_timeout: ?Resolv.DnsTimeout = null;
    if (creation_data.py_dns_timeout) |py_dns_timeout| {
        dns_timeout = try Resolv.parse_dns_timeout(py_dns_timeout);
    }
    creation_data.dns_timeout = dns_timeout;

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

        const fileno_func = python_c.PyObject_GetAttrString(v, "fileno\x00") orelse return error.PythonError;
        defer python_c.py_decref(fileno_func);

        const py_fd = python_c.PyObject_CallNoArgs(fileno_func) orelse return error.PythonError;
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
        // BUG-361: PyLong_AsLongLong yields an i64 — narrowing to fd_t
        // (i32) panicked on out-of-range values; reject instead.
        if (fd > std.math.maxInt(std.posix.fd_t)) {
            python_c.raise_python_value_error("Invalid fd\x00");
            return error.PythonError;
        }

        const transport_creation_data = try allocator.create(TransportCreationData);
        errdefer allocator.destroy(transport_creation_data);

        transport_creation_data.* = .{
            // BUG-309: the dispatched create_transport_and_set_future_result
            // unconditionally decrefs protocol_factory in its cleanup defer.
            // The sock path used to store a borrowed reference here (the
            // normal path takes py_newref), so that decref dropped the
            // caller's reference - refcount underflow and use-after-free on
            // loop.create_connection(..., sock=s). Take an owned reference
            // like the normal path does.
            .protocol_factory = python_c.py_newref(protocol_factory),
            .future = python_c.py_newref(fut),
            .loop = python_c.py_newref(self),
            .socket_fd = @intCast(fd),
            .zero_copying = false,
            // BUG-328: the raw fd is the caller's until the transport is
            // created (pre-adoption error paths must not close it). At
            // transport creation the fd is ADOPTED VIA DUP (see the
            // callback) and the caller's socket OBJECT is closed the way
            // CPython's _SelectorTransport._call_connection_lost closes
            // the wrapped socket - a caller object left holding the
            // connection keeps it open forever (peer never sees EOF),
            // which cascades into accept-queue exhaustion and SYN-SENT
            // hangs for subsequent connections.
            .fd_created = false,
            .owns_fd = false,
            .py_sock = python_c.py_newref(v),
            .dns_timeout = dns_timeout,
            .python_payload = .{
                .module_ptr = @ptrCast(self),
                .callback_ptr = @ptrCast(fut),
                .traverse = &TransportCreationData.traverse,
            },
        };
        // BUG-309/BUG-312: if the Soon.dispatch below fails, the errdefers
        // destroyed the struct without releasing its owned references,
        // permanently leaking the future, loop, and (after the BUG-309 fix)
        // protocol_factory references. Release all three on the error path;
        // on success the dispatched callback's cleanup defer owns them.
        errdefer {
            python_c.py_decref(transport_creation_data.protocol_factory);
            python_c.py_decref(@ptrCast(transport_creation_data.loop));
            python_c.py_decref(@ptrCast(transport_creation_data.future));
            python_c.py_xdecref(transport_creation_data.py_sock);
        }

        const callback = CallbackManager.Callback{
            .func = &transport_mod.create_transport_and_set_future_result,
            .cleanup = null,
            .data = CallbackManager.CallbackData.init_python(transport_creation_data, &transport_creation_data.python_payload),
        };
        try Loop.Scheduling.Soon.dispatch(loop_data, &callback);

        python_c.deinitialize_object_fields(&creation_data, &.{ "future", "protocol_factory" });
        return fut;
    }

    creation_data.loop = python_c.py_newref(self);
    creation_data.future = python_c.py_newref(fut);
    creation_data.protocol_factory = python_c.py_newref(protocol_factory);

    const creation_data_ptr = try allocator.create(SocketCreationData);
    creation_data_ptr.* = creation_data;
    errdefer allocator.destroy(creation_data_ptr);

    const callback = CallbackManager.Callback{
        .func = &resolve_mod.try_resolv_host,
        .cleanup = null,
        .data = .{
            .user_data = creation_data_ptr,
        },
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);

    return fut;
}

pub fn loop_create_connection(self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(z_loop_create_connection, .{
        self.?, args.?[0..@as(usize, @intCast(nargs))], knames,
    });
}
