const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const utils = @import("utils");
const CallbackManager = @import("callback_manager");
const Loop = @import("../../loop/main.zig");
const LoopObject = Loop.Python.LoopObject;

pub const SubprocessTransportObject = extern struct {
    ob_base: python_c.PyObject,

    loop: ?PyObject,
    protocol: ?PyObject,
    popen: ?PyObject,
    pid: std.posix.pid_t,
    returncode: ?PyObject,

    pidfd_task_id: usize,
    pidfd: std.posix.fd_t,
    closed: bool,
};

fn subprocess_dealloc(self: ?*SubprocessTransportObject) callconv(.c) void {
    const instance = self.?;
    python_c.PyObject_GC_UnTrack(@ptrCast(instance));
    if (!instance.closed) {
        if (instance.loop) |loop| {
            const loop_obj: *LoopObject = @alignCast(@ptrCast(loop));
            if (loop_obj.debug) {
                const msg = python_c.PyUnicode_FromFormat("unclosed transport <SubprocessTransport pid=%d>\x00", instance.pid);
                if (msg) |m| {
                    defer python_c.py_decref(m);
                    python_c.py_warn(python_c.PyExc_ResourceWarning.?, m, 1);
                }
            }
        }
    }
    python_c.py_xdecref(instance.loop);
    python_c.py_xdecref(instance.protocol);
    python_c.py_xdecref(instance.popen);
    python_c.py_xdecref(instance.returncode);
    const @"type" = python_c.get_type(@ptrCast(instance)) orelse return;
    @"type".tp_free.?(@ptrCast(instance));
}

fn subprocess_traverse(self: ?*SubprocessTransportObject, visit: python_c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
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

    var vret: c_int = 0;
    if (instance.loop) |obj| {
        vret = visit.?(@ptrCast(obj), arg);
        if (vret != 0) return vret;
    }
    if (instance.protocol) |obj| {
        vret = visit.?(@ptrCast(obj), arg);
        if (vret != 0) return vret;
    }
    if (instance.popen) |obj| {
        vret = visit.?(@ptrCast(obj), arg);
        if (vret != 0) return vret;
    }
    if (instance.returncode) |obj| {
        vret = visit.?(@ptrCast(obj), arg);
        if (vret != 0) return vret;
    }
    return 0;
}

fn subprocess_clear(self: ?*SubprocessTransportObject) callconv(.c) c_int {
    const instance = self.?;
    python_c.py_xdecref(instance.loop);
    instance.loop = null;
    python_c.py_xdecref(instance.protocol);
    instance.protocol = null;
    python_c.py_xdecref(instance.popen);
    instance.popen = null;
    python_c.py_xdecref(instance.returncode);
    instance.returncode = null;

    if (python_c.has_managed_dict(@ptrCast(instance))) {
        python_c.PyObject_ClearManagedDict(@ptrCast(instance));
    }
    return 0;
}

fn subprocess_get_pid(self: ?*SubprocessTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    return python_c.PyLong_FromLong(@intCast(self.?.pid));
}

fn subprocess_get_returncode(self: ?*SubprocessTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    if (self.?.returncode) |rc| return python_c.py_newref(rc);
    return python_c.get_py_none();
}

fn subprocess_kill(self: ?*SubprocessTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    std.posix.kill(instance.pid, std.posix.SIG.KILL) catch |err| {
        return utils.handle_zig_function_error(err, null);
    };
    return python_c.get_py_none();
}

fn subprocess_terminate(self: ?*SubprocessTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    std.posix.kill(instance.pid, std.posix.SIG.TERM) catch |err| {
        return utils.handle_zig_function_error(err, null);
    };
    return python_c.get_py_none();
}

fn subprocess_send_signal(self: ?*SubprocessTransportObject, arg: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    const sig = python_c.PyLong_AsInt(arg.?) ;
    std.posix.kill(instance.pid, @as(std.os.linux.SIG, @enumFromInt(sig))) catch |err| {
        return utils.handle_zig_function_error(err, null);
    };
    return python_c.get_py_none();
}

fn subprocess_get_pipe_transport(self: ?*SubprocessTransportObject, arg: ?PyObject) callconv(.c) ?PyObject {
    _ = self;
    _ = arg;
    return python_c.get_py_none();
}

fn subprocess_close(self: ?*SubprocessTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    if (!instance.closed) {
        instance.closed = true;
        if (instance.pidfd_task_id > 0) {
            if (instance.loop) |py_loop| {
                const loop_obj: *LoopObject = @ptrCast(py_loop);
                const loop_data = utils.get_data_ptr(Loop, loop_obj);
                _ = loop_data.io.queue(.{ .Cancel = instance.pidfd_task_id }) catch {};
            }
            instance.pidfd_task_id = 0;
        }
        if (instance.pidfd >= 0) {
            _ = std.os.linux.close(instance.pidfd);
            instance.pidfd = -1;
        }
    }
    return python_c.get_py_none();
}

fn subprocess_get_popen(self: ?*SubprocessTransportObject, _: ?*anyopaque) callconv(.c) ?PyObject {
    if (self.?.popen) |p| return python_c.py_newref(p);
    return python_c.get_py_none();
}

fn subprocess_set_popen(self: ?*SubprocessTransportObject, value: ?PyObject, _: ?*anyopaque) callconv(.c) c_int {
    const instance = self.?;
    python_c.py_xdecref(instance.popen);
    instance.popen = if (value) |v| python_c.py_newref(v) else null;
    return 0;
}

const SubprocessGetSet: []const python_c.PyGetSetDef = &[_]python_c.PyGetSetDef{
    .{ .name = "_popen", .get = @ptrCast(&subprocess_get_popen), .set = @ptrCast(&subprocess_set_popen), .doc = "Popen object", .closure = null },
    .{ .name = null, .get = null, .set = null, .doc = null, .closure = null },
};

const SubprocessMethods: []const python_c.PyMethodDef = &[_]python_c.PyMethodDef{
    .{ .ml_name = "get_pid", .ml_meth = @ptrCast(&subprocess_get_pid), .ml_doc = "Get PID.", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = "get_returncode", .ml_meth = @ptrCast(&subprocess_get_returncode), .ml_doc = "Get returncode.", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = "kill", .ml_meth = @ptrCast(&subprocess_kill), .ml_doc = "SIGKILL.", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = "terminate", .ml_meth = @ptrCast(&subprocess_terminate), .ml_doc = "SIGTERM.", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = "send_signal", .ml_meth = @ptrCast(&subprocess_send_signal), .ml_doc = "Send signal.", .ml_flags = python_c.METH_O },
    .{ .ml_name = "get_pipe_transport", .ml_meth = @ptrCast(&subprocess_get_pipe_transport), .ml_doc = "Get pipe transport for fd.", .ml_flags = python_c.METH_O },
    .{ .ml_name = "close", .ml_meth = @ptrCast(&subprocess_close), .ml_doc = "Close.", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = null, .ml_meth = null, .ml_doc = null, .ml_flags = 0 },
};

const Py_tp_getset: c_int = 73;

const SubprocessSlots: []const python_c.PyType_Slot = &[_]python_c.PyType_Slot{
    .{ .slot = python_c.Py_tp_new, .pfunc = @ptrCast(@constCast(&python_c.PyType_GenericNew)) },
    .{ .slot = python_c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&subprocess_dealloc)) },
    .{ .slot = python_c.Py_tp_traverse, .pfunc = @ptrCast(@constCast(&subprocess_traverse)) },
    .{ .slot = python_c.Py_tp_clear, .pfunc = @ptrCast(@constCast(&subprocess_clear)) },
    .{ .slot = python_c.Py_tp_methods, .pfunc = @ptrCast(@constCast(SubprocessMethods.ptr)) },
    .{ .slot = Py_tp_getset, .pfunc = @ptrCast(@constCast(SubprocessGetSet.ptr)) },
    .{ .slot = python_c.Py_tp_doc, .pfunc = @constCast("Talyn SubprocessTransport.") },
    .{ .slot = 0, .pfunc = null },
};

var subprocess_spec = python_c.PyType_Spec{
    .name = "talyn.SubprocessTransport",
    .basicsize = @sizeOf(SubprocessTransportObject),
    .itemsize = 0,
    .flags = python_c.Py_TPFLAGS_DEFAULT | python_c.Py_TPFLAGS_BASETYPE | python_c.Py_TPFLAGS_HAVE_GC,
    .slots = @constCast(SubprocessSlots.ptr),
};

pub var SubprocessType: ?*python_c.PyTypeObject = null;

pub fn create_type() !void {
    if (SubprocessType != null) return;
    SubprocessType = @ptrCast(python_c.PyType_FromSpecWithBases(
        @constCast(&subprocess_spec), null
    ) orelse return error.PythonError);
}

fn cleanup_pidfd(ptr: ?*anyopaque) void {
    const transport: *SubprocessTransportObject = @alignCast(@ptrCast(ptr.?));
    python_c.py_decref(@ptrCast(transport));
}

fn pidfd_exit_callback(data: *const CallbackManager.CallbackData) !void {
    const transport: *SubprocessTransportObject = @alignCast(@ptrCast(data.user_data.?));
    defer python_c.py_decref(@ptrCast(transport));

    if (data.cancelled() or transport.closed) return;

    var siginfo: std.os.linux.siginfo_t = undefined;
    const res = res: {
        while (true) {
            const r = std.os.linux.waitid(.PIDFD, transport.pidfd, &siginfo, std.os.linux.W.EXITED | std.os.linux.W.NOHANG, null);
            if (r != 0) {
                const errno: u32 = @truncate(~r + 1);
                if (errno == @intFromEnum(std.os.linux.E.INTR)) continue;
            }
            break :res r;
        }
    };

    if (res != 0) {
        const errno: u32 = @truncate(~res + 1);
        const err: std.os.linux.E = @enumFromInt(errno);
        if (err == .CHILD) {
            transport.returncode = python_c.PyLong_FromLong(-1);
            if (transport.protocol) |proto| {
                const pe = python_c.PyObject_GetAttrString(proto, "process_exited\x00");
                if (pe) |v| {
                    const r1 = python_c.PyObject_CallNoArgs(v);
                    if (r1) |rv| {
                        python_c.py_decref(rv);
                    } else {
                        if (python_c.PyErr_GetRaisedException()) |e| {
                            defer python_c.py_decref(e);
                            const ctx = python_c.PyDict_New();
                            if (ctx) |c| {
                                defer python_c.py_decref(c);
                                const msg = python_c.PyUnicode_FromString("Exception in subprocess process_exited callback\x00");
                                if (msg) |m| {
                                    _ = python_c.PyDict_SetItemString(c, "message\x00", m);
                                    python_c.py_decref(m);
                                }
                                _ = python_c.PyDict_SetItemString(c, "exception\x00", e);
                                if (transport.loop) |loop_obj| {
                                    const ret = python_c.PyObject_CallMethod(loop_obj, "call_exception_handler\x00", "O\x00", c);
                                    if (ret) |r| python_c.py_decref(r) else python_c.PyErr_Clear();
                                }
                            }
                        }
                    }
                    python_c.py_decref(v);
                }
                const cl = python_c.PyObject_GetAttrString(proto, "connection_lost\x00");
                if (cl) |v| {
                    const r2 = python_c.PyObject_CallOneArg(v, python_c.get_py_none_without_incref());
                    if (r2) |rv| {
                        python_c.py_decref(rv);
                    } else {
                        if (python_c.PyErr_GetRaisedException()) |e| {
                            defer python_c.py_decref(e);
                            const ctx = python_c.PyDict_New();
                            if (ctx) |c| {
                                defer python_c.py_decref(c);
                                const msg = python_c.PyUnicode_FromString("Exception in subprocess connection_lost callback\x00");
                                if (msg) |m| {
                                    _ = python_c.PyDict_SetItemString(c, "message\x00", m);
                                    python_c.py_decref(m);
                                }
                                _ = python_c.PyDict_SetItemString(c, "exception\x00", e);
                                if (transport.loop) |loop_obj| {
                                    const ret = python_c.PyObject_CallMethod(loop_obj, "call_exception_handler\x00", "O\x00", c);
                                    if (ret) |r| python_c.py_decref(r) else python_c.PyErr_Clear();
                                }
                            }
                        }
                    }
                    python_c.py_decref(v);
                }
            }
            _ = std.os.linux.close(transport.pidfd);
            transport.pidfd = -1;
            transport.pidfd_task_id = 0;
            python_c.py_xdecref(transport.popen);
            transport.popen = null;
            return;
        }
        const loop = utils.get_data_ptr(Loop, @as(*LoopObject, @ptrCast(transport.loop.?)));
        python_c.py_incref(@ptrCast(transport));
        transport.pidfd_task_id = try loop.io.queue(.{
            .WaitReadable = .{
                .fd = transport.pidfd,
                .callback = .{
                    .func = &pidfd_exit_callback,
                    .cleanup = &cleanup_pidfd,
                    .data = .{
                        .user_data = transport,
                    },
                },
            },
        });
        return;
    }

    const CLD_EXITED = 1;
    const CLD_KILLED = 2;
    const CLD_DUMPED = 3;

    const rc: i32 = switch (siginfo.code) {
        CLD_EXITED => siginfo.fields.common.second.sigchld.status,
        CLD_KILLED, CLD_DUMPED => -siginfo.fields.common.second.sigchld.status,
        else => 0,
    };

    transport.returncode = python_c.PyLong_FromLong(rc);

    if (transport.protocol) |proto| {
        const pe = python_c.PyObject_GetAttrString(proto, "process_exited\x00") orelse return error.PythonError;
        defer python_c.py_decref(pe);
        const r1 = python_c.PyObject_CallNoArgs(pe);
        if (r1) |v| python_c.py_decref(v) else python_c.PyErr_Clear();

        const cl = python_c.PyObject_GetAttrString(proto, "connection_lost\x00") orelse return error.PythonError;
        defer python_c.py_decref(cl);
        const r2 = python_c.PyObject_CallOneArg(cl, python_c.get_py_none_without_incref()) orelse return error.PythonError;
        python_c.py_decref(r2);
    }

    _ = std.os.linux.close(transport.pidfd);
    transport.pidfd = -1;
    transport.pidfd_task_id = 0;
    python_c.py_xdecref(transport.popen);
    transport.popen = null;
}

pub fn start_exit_watcher(transport: *SubprocessTransportObject, loop: *LoopObject) !void {
    const loop_data = utils.get_data_ptr(Loop, loop);

    const pidfd: std.posix.fd_t = @intCast(std.os.linux.syscall2(.pidfd_open, @as(usize, @intCast(transport.pid)), 0));
    if (pidfd < 0) return error.SystemResources;
    transport.pidfd = pidfd;
    errdefer _ = std.os.linux.close(pidfd);

    python_c.py_incref(@ptrCast(transport));
    transport.pidfd_task_id = try loop_data.io.queue(.{
        .WaitReadable = .{
            .fd = pidfd,
            .callback = .{
                .func = &pidfd_exit_callback,
                .cleanup = &cleanup_pidfd,
                .data = .{
                    .user_data = transport,
                },
            },
        },
    });
}

pub fn new_with_pid(
    protocol: PyObject, loop: *LoopObject, pid: std.posix.pid_t
) !*SubprocessTransportObject {
    const self: *SubprocessTransportObject = @ptrCast(
        SubprocessType.?.tp_alloc.?(SubprocessType.?, 0) orelse return error.PythonError
    );
    self.loop = python_c.py_newref(@as(*python_c.PyObject, @ptrCast(loop)));
    self.protocol = python_c.py_newref(protocol);
    self.pid = pid;
    self.returncode = null;
    self.pidfd_task_id = 0;
    self.pidfd = -1;
    self.closed = false;

    return self;
}
