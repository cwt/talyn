const std = @import("std");
const Loop = @import("main.zig");
const CallbackManager = @import("callback_manager");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const utils = @import("utils");

const ChildWatcher = @This();

loop: *Loop = undefined,
handlers: std.AutoHashMap(i32, *ChildHandler) = undefined,

const ChildHandler = struct {
    pid: i32,
    pidfd: std.posix.fd_t,
    callback: PyObject,
    task_id: usize = 0,
    watcher: *ChildWatcher,
};

pub fn init(self: *ChildWatcher, loop: *Loop) !void {
    self.loop = loop;
    self.handlers = std.AutoHashMap(i32, *ChildHandler).init(loop.allocator);
}

pub fn deinit(self: *ChildWatcher) void {
    var it = self.handlers.iterator();
    while (it.next()) |entry| {
        const handler = entry.value_ptr.*;
        if (handler.task_id != 0) {
            _ = self.loop.io.queue(.{ .Cancel = handler.task_id }) catch {};
        }
        if (handler.pidfd >= 0) {
            _ = std.os.linux.close(handler.pidfd);
        }
        python_c.py_decref(handler.callback);
        self.loop.allocator.destroy(handler);
    }
    self.handlers.deinit();
}

pub fn add_child_handler(self: *ChildWatcher, pid: i32, callback: PyObject) !void {
    const pidfd: std.posix.fd_t = @intCast(std.os.linux.syscall2(.pidfd_open, @as(usize, @intCast(pid)), 0));
    if (pidfd < 0) {
        const err = std.posix.errno(pidfd);
        if (err == .SRCH) {
            python_c.raise_python_runtime_error("No such process\x00");
            return error.PythonError;
        }
        return error.SystemResources;
    }
    errdefer _ = std.os.linux.close(pidfd);

    const handler = try self.loop.allocator.create(ChildHandler);
    errdefer self.loop.allocator.destroy(handler);
    
    handler.* = .{
        .pid = pid,
        .pidfd = pidfd,
        .callback = python_c.py_newref(callback),
        .watcher = self,
    };

    handler.task_id = try self.loop.io.queue(.{
        .WaitReadable = .{
            .fd = pidfd,
            .callback = .{
                .func = &on_child_exit,
                .cleanup = null,
                .data = .{ .user_data = handler },
            },
        }
    });

    try self.handlers.put(pid, handler);
}

pub fn remove_child_handler(self: *ChildWatcher, pid: i32) bool {
    if (self.handlers.fetchRemove(pid)) |entry| {
        const handler = entry.value;
        if (handler.task_id != 0) {
            _ = self.loop.io.queue(.{ .Cancel = handler.task_id }) catch {};
        }
        if (handler.pidfd >= 0) {
            _ = std.os.linux.close(handler.pidfd);
        }
        python_c.py_decref(handler.callback);
        self.loop.allocator.destroy(handler);
        return true;
    }
    return false;
}

fn on_child_exit(data: *const CallbackManager.CallbackData) !void {
    const handler: *ChildHandler = @alignCast(@ptrCast(data.user_data.?));
    const self = handler.watcher;

    if (data.cancelled or !self.loop.initialized) {
        return;
    }

    // Get exit status
    var siginfo: std.os.linux.siginfo_t = undefined;
    const res = res: {
        while (true) {
            const r = std.os.linux.waitid(.PIDFD, handler.pidfd, &siginfo, std.os.linux.W.EXITED | std.os.linux.W.NOHANG, null);
            if (r != 0) {
                const errno: u32 = @truncate(~r + 1);
                if (errno == @intFromEnum(std.os.linux.E.INTR)) continue;
            }
            break :res r;
        }
    };
    
    if (res != 0) {
        // Process might still be alive (though POLLIN triggered)?
        // Re-arm
        handler.task_id = try self.loop.io.queue(.{
            .WaitReadable = .{
                .fd = handler.pidfd,
                .callback = .{
                    .func = &on_child_exit,
                    .cleanup = null,
                    .data = .{ .user_data = handler },
                },
            }
        });
        return;
    }

    const CLD_EXITED = 1;
    const CLD_KILLED = 2;
    const CLD_DUMPED = 3;

    const returncode: i32 = switch (siginfo.code) {
        CLD_EXITED => siginfo.fields.common.second.sigchld.status,
        CLD_KILLED, CLD_DUMPED => -siginfo.fields.common.second.sigchld.status,
        else => 0,
    };

    // Dispatch to Python
    const py_pid = python_c.PyLong_FromLong(handler.pid) orelse return error.PythonError;
    defer python_c.py_decref(py_pid);
    const py_rc = python_c.PyLong_FromLong(returncode) orelse return error.PythonError;
    defer python_c.py_decref(py_rc);
    
    const py_args = python_c.PyTuple_Pack(2, py_pid, py_rc) orelse return error.PythonError;
    defer python_c.py_decref(py_args);
    
    const py_res = python_c.PyObject_Call(handler.callback, py_args, null) orelse {
        const exc = python_c.PyErr_GetRaisedException() orelse return;
        defer python_c.py_decref(exc);
        const loop_obj = utils.get_parent_ptr(Loop.Python.LoopObject, self.loop);
        const ctx = python_c.PyDict_New() orelse return;
        defer python_c.py_decref(ctx);
        _ = python_c.PyDict_SetItemString(ctx, "message\x00", python_c.PyUnicode_FromString("Exception in child handler callback\x00") orelse return);
        _ = python_c.PyDict_SetItemString(ctx, "exception\x00", exc);
        const ret = python_c.PyObject_CallMethod(@ptrCast(loop_obj), "call_exception_handler\x00", "O\x00", ctx) orelse {
            python_c.PyErr_Clear();
            return;
        };
        python_c.py_decref(ret);
        return;
    };
    python_c.py_decref(py_res);

    // Cleanup handler
    _ = self.handlers.remove(handler.pid);
    _ = std.os.linux.close(handler.pidfd);
    python_c.py_decref(handler.callback);
    self.loop.allocator.destroy(handler);
}

pub fn traverse(self: *const ChildWatcher, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
    var it = self.handlers.valueIterator();
    while (it.next()) |handler| {
        const vret = visit.?(@ptrCast(handler.*.callback), arg);
        if (vret != 0) return vret;
    }
    return 0;
}
