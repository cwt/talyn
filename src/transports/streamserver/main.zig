const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const CallbackManager = @import("callback_manager");

const Loop = @import("../../loop/main.zig");
const LoopObject = Loop.Python.LoopObject;

const Stream = @import("../stream/main.zig");

pub const StreamServerObject = extern struct {
    ob_base: python_c.PyObject,

    loop: ?PyObject,
    protocol_factory: ?PyObject,
    server_fd: std.posix.fd_t,
    family: c_int,
    backlog: c_int,
    blocking_task_id: usize,
    closed: bool,
    server_ref: ?PyObject,

    pub fn deinit(self: *StreamServerObject) void {
        python_c.py_xdecref(self.loop);
        self.loop = null;
        python_c.py_xdecref(self.protocol_factory);
        self.protocol_factory = null;
        python_c.py_xdecref(self.server_ref);
        self.server_ref = null;
        if (self.server_fd >= 0) {
            _ = std.os.linux.close(self.server_fd);
            self.server_fd = -1;
        }
    }
};

fn streamserver_dealloc(self: ?*StreamServerObject) callconv(.c) void {
    const instance = self.?;
    python_c.PyObject_GC_UnTrack(instance);
    if (!instance.closed and instance.server_fd >= 0) {
        if (instance.loop) |loop| {
            const loop_obj: *Loop.Python.LoopObject = @alignCast(@ptrCast(loop));
            if (loop_obj.debug) {
                const msg = python_c.PyUnicode_FromFormat("unclosed server <StreamServerObject fd=%d>\x00", instance.server_fd);
                if (msg) |m| {
                    defer python_c.py_decref(m);
                    python_c.py_warn(python_c.PyExc_ResourceWarning.?, m, 1);
                }
            }
        }
    }
    instance.deinit();
    const @"type" = python_c.get_type(@ptrCast(instance)) orelse return;
    @"type".tp_free.?(@ptrCast(instance));
}

fn streamserver_traverse(self: ?*StreamServerObject, visit: python_c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    const instance = self.?;

    // Visit type object (required for heap types)
    if (python_c.Py_TYPE(@ptrCast(instance))) |t| {
        const vret_t = visit.?(@ptrCast(t), arg);
        if (vret_t != 0) return vret_t;
    }

    // Visit managed dictionary (for dynamically added attributes)
    if (python_c.has_managed_dict(@ptrCast(instance))) {
        const vret_dict = python_c.PyObject_VisitManagedDict(@ptrCast(instance), visit, arg);
        if (vret_dict != 0) return vret_dict;
    }

    return python_c.py_visit(instance, visit, arg);
}

fn streamserver_clear(self: ?*StreamServerObject) callconv(.c) c_int {
    const instance = self.?;
    instance.deinit();

    python_c.deinitialize_object_fields(instance, &.{});
    if (python_c.has_managed_dict(@ptrCast(instance))) {
        python_c.PyObject_ClearManagedDict(@ptrCast(instance));
    }
    return 0;
}

fn z_streamserver_init(
    self: *StreamServerObject, py_loop: ?PyObject, py_protocol_factory: ?PyObject,
    py_server_fd: ?PyObject, py_family: ?PyObject, py_backlog: ?PyObject
) !c_int {
    if (python_c.PyCallable_Check(py_protocol_factory.?) <= 0) {
        python_c.raise_python_type_error("protocol_factory must be callable\x00");
        return error.PythonError;
    }

    const fd = python_c.PyLong_AsLongLong(py_server_fd.?);
    if (fd < 0) {
        python_c.raise_python_value_error("Invalid fd\x00");
        return error.PythonError;
    }

    const family = if (py_family) |f| @as(c_int, @intCast(python_c.PyLong_AsLong(f))) else std.posix.AF.INET;

    const backlog: c_int = if (py_backlog) |b| blk: {
        break :blk @intCast(python_c.PyLong_AsInt(b));
    } else 100;

    self.loop = python_c.py_newref(py_loop.?);
    self.protocol_factory = python_c.py_newref(py_protocol_factory.?);
    self.server_fd = @intCast(fd);
    self.family = family;
    self.backlog = backlog;
    self.blocking_task_id = 0;
    self.closed = false;
    self.server_ref = null;

    return 0;
}

fn streamserver_init(
    self: ?*StreamServerObject, args: ?PyObject, kwargs: ?PyObject
) callconv(.c) c_int {
    var py_loop: ?PyObject = null;
    var py_protocol_factory: ?PyObject = null;
    var py_server_fd: ?PyObject = null;
    var py_family: ?PyObject = null;
    var py_backlog: ?PyObject = null;

    var kwlist: [6][*c]u8 = undefined;
    kwlist[0] = @constCast("loop\x00");
    kwlist[1] = @constCast("protocol_factory\x00");
    kwlist[2] = @constCast("server_fd\x00");
    kwlist[3] = @constCast("family\x00");
    kwlist[4] = @constCast("backlog\x00");
    kwlist[5] = null;

    if (python_c.PyArg_ParseTupleAndKeywords(
        args, kwargs, "OOOO|O\x00", @ptrCast(&kwlist),
        &py_loop, &py_protocol_factory, &py_server_fd, &py_family, &py_backlog
    ) < 0) {
        return -1;
    }

    return utils.execute_zig_function(z_streamserver_init, .{
        self.?, py_loop, py_protocol_factory, py_server_fd, py_family, py_backlog,
    });
}

fn accept_callback(data: *const CallbackManager.CallbackData) !void {
    const server: *StreamServerObject = @alignCast(@ptrCast(data.user_data.?));
    if (data.cancelled or server.closed) return;

    if (data.io_uring_err != .SUCCESS) {
        const exception = python_c.PyObject_CallFunction(
            python_c.PyExc_OSError, "Ls\x00",
            @as(c_long, @intFromEnum(data.io_uring_err)),
            "Accept error\x00"
        ) orelse return error.PythonError;
        python_c.PyErr_SetRaisedException(exception);
        return error.PythonError;
    }

    const client_fd_ret = std.os.linux.accept4(server.server_fd, null, null, @as(u32, @intCast(std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC)));
    if (client_fd_ret == std.math.maxInt(usize)) {
        // accept4 failed, check errno
        const errno_val = @intFromEnum(std.os.linux.errno(0));
        const eagain = @intFromEnum(std.os.linux.E.AGAIN);
        if (errno_val == eagain) {
            // Re-arm poll
            try enqueue_accept(server);
            return;
        }
        return error.SystemResources;
    }
    const client_fd: std.posix.fd_t = @intCast(client_fd_ret);
    errdefer _ = std.os.linux.close(client_fd);

    const loop = server.loop.?;
    _ = utils.get_data_ptr(Loop, @as(*Loop.Python.LoopObject, @ptrCast(loop)));

    const protocol = python_c.PyObject_CallNoArgs(server.protocol_factory.?) orelse return error.PythonError;
    defer python_c.py_decref(protocol);

    const transport = try Stream.Constructors.new_stream_transport(
        protocol, @ptrCast(loop), client_fd, false
    );
    defer python_c.py_decref(@ptrCast(transport));

    const connection_made = python_c.PyObject_GetAttrString(protocol, "connection_made\x00")
        orelse return error.PythonError;
    defer python_c.py_decref(connection_made);

    const ret = python_c.PyObject_CallOneArg(connection_made, @ptrCast(transport))
        orelse return error.PythonError;
    python_c.py_decref(ret);

    // Re-arm poll for next connection
    try enqueue_accept(server);

    // Notify server of new connection
    if (server.server_ref) |srv| {
        const attach = python_c.PyObject_GetAttrString(srv, "_attach\x00") orelse return error.PythonError;
        defer python_c.py_decref(attach);
        const r = python_c.PyObject_CallNoArgs(attach) orelse return error.PythonError;
        python_c.py_decref(r);
    }
}

fn enqueue_accept(server: *StreamServerObject) !void {
    const loop_data = utils.get_data_ptr(Loop, @as(*Loop.Python.LoopObject, @ptrCast(server.loop.?)));
    const fd = server.server_fd;

    const blocking_task_id = server.blocking_task_id;
    if (blocking_task_id > 0) {
        _ = try loop_data.io.queue(.{ .Cancel = blocking_task_id });
    }

    server.blocking_task_id = try loop_data.io.queue(.{
        .WaitReadable = .{
            .fd = fd,
            .callback = .{
                .func = &accept_callback,
                .cleanup = null,
                .data = .{
                    .user_data = server,
                },
            },
        },
    });
}

fn z_close_server(self: *StreamServerObject) !void {
    if (self.closed) return;
    self.closed = true;

    const loop_data = utils.get_data_ptr(Loop, @as(*Loop.Python.LoopObject, @ptrCast(self.loop.?)));
    const blocking_task_id = self.blocking_task_id;
    if (blocking_task_id > 0) {
        _ = try loop_data.io.queue(.{ .Cancel = blocking_task_id });
        self.blocking_task_id = 0;
    }
    if (self.server_fd >= 0) {
        _ = std.os.linux.close(self.server_fd);
        self.server_fd = -1;
    }
}

fn streamserver_close(self: ?*StreamServerObject, _: ?PyObject) callconv(.c) ?PyObject {
    z_close_server(self.?) catch |err| {
        return utils.handle_zig_function_error(err, null);
    };
    return python_c.get_py_none();
}

fn streamserver_is_serving(self: ?*StreamServerObject, _: ?PyObject) callconv(.c) ?PyObject {
    return python_c.PyBool_FromLong(@intFromBool(!self.?.closed and self.?.server_fd >= 0));
}

fn streamserver_get_loop(self: ?*StreamServerObject, _: ?PyObject) callconv(.c) ?PyObject {
    if (self.?.loop) |loop| {
        return python_c.py_newref(loop);
    }
    return python_c.get_py_none();
}

fn streamserver_get_socket(self: ?*StreamServerObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    if (instance.server_fd < 0) {
        python_c.raise_python_runtime_error("Server socket is closed\x00");
        return null;
    }

    const socket_module = utils.PythonImports.socket_module;
    const fromfd = python_c.PyObject_GetAttrString(socket_module, "fromfd\x00") orelse return null;
    defer python_c.py_decref(fromfd);

    const py_fd = python_c.PyLong_FromLong(@intCast(instance.server_fd)) orelse return null;
    defer python_c.py_decref(py_fd);
    const family_obj = python_c.PyLong_FromLong(instance.family) orelse return null;
    defer python_c.py_decref(family_obj);
    const type_obj = python_c.PyLong_FromLong(std.posix.SOCK.STREAM) orelse return null;
    defer python_c.py_decref(type_obj);

    const args = python_c.PyTuple_Pack(3, py_fd, family_obj, type_obj) orelse return null;
    defer python_c.py_decref(args);

    return python_c.PyObject_CallObject(fromfd, args);
}

const PythonStreamServerMethods: []const python_c.PyMethodDef = &[_]python_c.PyMethodDef{
    python_c.PyMethodDef{
        .ml_name = "close\x00",
        .ml_meth = @ptrCast(&streamserver_close),
        .ml_doc = "Close the server.\x00",
        .ml_flags = python_c.METH_NOARGS,
    },
    python_c.PyMethodDef{
        .ml_name = "is_serving\x00",
        .ml_meth = @ptrCast(&streamserver_is_serving),
        .ml_doc = "Return True if the server is accepting connections.\x00",
        .ml_flags = python_c.METH_NOARGS,
    },
    python_c.PyMethodDef{
        .ml_name = "get_loop\x00",
        .ml_meth = @ptrCast(&streamserver_get_loop),
        .ml_doc = "Return the event loop.\x00",
        .ml_flags = python_c.METH_NOARGS,
    },
    python_c.PyMethodDef{
        .ml_name = "_get_socket\x00",
        .ml_meth = @ptrCast(&streamserver_get_socket),
        .ml_doc = "Return the server socket.\x00",
        .ml_flags = python_c.METH_NOARGS,
    },
    python_c.PyMethodDef{ .ml_name = null, .ml_meth = null, .ml_doc = null, .ml_flags = 0 },
};

const PythonStreamServerSlots: []const python_c.PyType_Slot = &[_]python_c.PyType_Slot{
    python_c.PyType_Slot{ .slot = python_c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&streamserver_dealloc)) },
    python_c.PyType_Slot{ .slot = python_c.Py_tp_traverse, .pfunc = @ptrCast(@constCast(&streamserver_traverse)) },
    python_c.PyType_Slot{ .slot = python_c.Py_tp_clear, .pfunc = @ptrCast(@constCast(&streamserver_clear)) },
    python_c.PyType_Slot{ .slot = python_c.Py_tp_init, .pfunc = @ptrCast(@constCast(&streamserver_init)) },
    python_c.PyType_Slot{ .slot = python_c.Py_tp_new, .pfunc = @ptrCast(@constCast(&python_c.PyType_GenericNew)) },
    python_c.PyType_Slot{ .slot = python_c.Py_tp_methods, .pfunc = @constCast(PythonStreamServerMethods.ptr) },
    python_c.PyType_Slot{ .slot = python_c.Py_tp_doc, .pfunc = @constCast("Leviathan stream server.\x00") },
    python_c.PyType_Slot{ .slot = 0, .pfunc = null },
};

var server_spec = python_c.PyType_Spec{
    .name = "leviathan.StreamServer\x00",
    .basicsize = @sizeOf(StreamServerObject),
    .itemsize = 0,
    .flags = python_c.Py_TPFLAGS_DEFAULT | python_c.Py_TPFLAGS_BASETYPE | python_c.Py_TPFLAGS_HAVE_GC,
    .slots = @constCast(PythonStreamServerSlots.ptr),
};

pub var StreamServerType: ?*python_c.PyTypeObject = null;

pub fn create_type() !void {
    if (StreamServerType != null) {
        return;
    }
    StreamServerType = @ptrCast(python_c.PyType_FromSpecWithBases(
        &server_spec, null
    ) orelse return error.PythonError);
}

pub fn start_serving(server: *StreamServerObject) !void {
    try enqueue_accept(server);
}
