const std = @import("std");
const Loop = @import("main.zig");
const CallbackManager = @import("callback_manager");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const utils = @import("utils");

const ChildWatcher = @This();

loop: *Loop = undefined,
handlers: std.AutoHashMapUnmanaged(i32, *ChildHandler) = .empty,

const ChildHandler = struct {
    pid: i32,
    pidfd: std.posix.fd_t,
    callback: PyObject,
    task_id: usize = 0,
    watcher: *ChildWatcher,
    /// BUG-280: set by remove_child_handler. The exit callback may already
    /// sit in the ready queue (Cancel cannot reach a completed op), so the
    /// handler is torn down by THAT invocation instead of immediately,
    /// which used to execute the queued callback on freed memory.
    removed: bool = false,
};

pub fn init(self: *ChildWatcher, loop: *Loop) !void {
    self.loop = loop;
}

pub fn deinit(self: *ChildWatcher) void {
    // BUG-307: deferred teardown. Queueing a CancelIO does not synchronously
    // stop the op - its completion (or the release-time dispatch of an
    // already-queued callback) later invokes on_child_exit with this handler
    // as user_data. Destroying the handler here used to make that invocation
    // read freed memory. Marking `removed` hands teardown ownership to that
    // invocation; every dispatch path during Loop.release() (both
    // release_dynamic_ring_buffer and BlockingTasksSet.cancel_all) forces
    // cancelled=true, so the cancelled branch always owns the final destroy.
    var it = self.handlers.iterator();
    while (it.next()) |entry| {
        const handler = entry.value_ptr.*;
        handler.removed = true;
        if (handler.task_id != 0) {
            _ = self.loop.io.queue(.{ .CancelIO = handler.task_id }) catch |err| std.log.warn("queue cancel failed: {s}", .{@errorName(err)});
        } else {
            // Defensive: nothing in flight can reference it.
            teardown_child_handler(self, handler);
        }
    }
    self.handlers.deinit(self.loop.allocator);
}

pub fn add_child_handler(self: *ChildWatcher, pid: i32, callback: PyObject) !void {
    const rc = std.os.linux.syscall2(.pidfd_open, @as(usize, @intCast(pid)), 0);
    // BUG-326: std.posix.errno is the libc-style decoder (rc == -1 plus the
    // C errno TLS) and mis-decodes raw syscall returns - an ESRCH return
    // (e.g. pidfd_open on a reaped pid) read as SUCCESS and @intCast
    // truncated -errno into a bogus pidfd, whose waitid then failed with
    // EINVAL and stranded the handler. Use the raw-syscall decoder.
    const errno = utils.getSyscallErrno(rc);
    if (errno != .SUCCESS) {
        if (errno == .SRCH) {
            python_c.raise_python_runtime_error("No such process\x00");
            return error.PythonError;
        }
        return error.SystemResources;
    }
    const pidfd: std.posix.fd_t = @intCast(rc);
    _ = std.os.linux.fcntl(pidfd, std.posix.F.SETFD, @intCast(std.posix.FD_CLOEXEC));
    errdefer _ = std.os.linux.close(pidfd);
    try self.handlers.ensureUnusedCapacity(self.loop.allocator, 1);

    const handler = try self.loop.allocator.create(ChildHandler);
    errdefer self.loop.allocator.destroy(handler);

    handler.* = .{
        .pid = pid,
        .pidfd = pidfd,
        .callback = python_c.py_newref(callback),
        .watcher = self,
    };
    errdefer python_c.py_decref(handler.callback);

    handler.task_id = try self.loop.io.queue(.{ .WaitReadable = .{
        .fd = pidfd,
        .callback = .{
            .func = &on_child_exit,
            .cleanup = null,
            .data = .{ .user_data = handler },
        },
    } });

    // BUG-277: re-registering a pid REPLACES the previous handler; the old
    // one must be fully torn down (pidfd, callback ref, heap struct, armed
    // WaitReadable op) instead of silently orphaned by a map overwrite.
    // BUG-307: the teardown cannot happen here. The queued CancelIO only
    // asynchronously ends the old op - its CQE (or an already-queued exit
    // callback) later invokes on_child_exit with old_handler as user_data,
    // and freeing the struct now makes that invocation read freed memory
    // (and potentially double-free). Mark it removed and hand teardown
    // ownership to that invocation, mirroring remove_child_handler.
    if (self.handlers.fetchRemove(pid)) |old| {
        const old_handler = old.value;
        old_handler.removed = true;
        if (old_handler.task_id != 0) {
            _ = self.loop.io.queue(.{ .CancelIO = old_handler.task_id }) catch |err| std.log.warn("queue cancel failed: {s}", .{@errorName(err)});
        } else {
            // Defensive: nothing in flight can reference it.
            teardown_child_handler(self, old_handler);
        }
    }

    self.handlers.putAssumeCapacity(pid, handler);
}

/// BUG-280: single teardown for a handler whose lifecycle has ended.
fn teardown_child_handler(self: *ChildWatcher, handler: *ChildHandler) void {
    if (handler.pidfd >= 0) {
        _ = std.os.linux.close(handler.pidfd);
        handler.pidfd = -1;
    }
    python_c.py_decref(handler.callback);
    self.loop.allocator.destroy(handler);
}

pub fn remove_child_handler(self: *ChildWatcher, pid: i32) bool {
    if (self.handlers.fetchRemove(pid)) |entry| {
        const handler = entry.value;
        handler.removed = true;

        if (handler.task_id != 0) {
            // The WaitReadable may still be armed OR already completed
            // with its callback queued; either way that invocation now
            // owns the teardown.
            _ = self.loop.io.queue(.{ .CancelIO = handler.task_id }) catch |err| std.log.warn("queue cancel failed: {s}", .{@errorName(err)});
        } else {
            // Defensive: nothing in flight can reference it.
            teardown_child_handler(self, handler);
        }
        return true;
    }
    return false;
}

fn on_child_exit(data: *const CallbackManager.CallbackData) !void {
    if (data.cancelled()) {
        // BUG-280/BUG-307: cancellation now comes from remove_child_handler,
        // add_child_handler replacement, or watcher deinit - all of which
        // mark the handler removed and unmapped it, so this invocation owns
        // the teardown in every case. The `removed` check stays as a guard
        // against a future cancel source that doesn't mark (leak, not UAF).
        const handler: *ChildHandler = @ptrCast(@alignCast(data.user_data.?));
        if (handler.removed) {
            teardown_child_handler(handler.watcher, handler);
        }
        return;
    }
    const handler: *ChildHandler = @ptrCast(@alignCast(data.user_data.?));
    const self = handler.watcher;

    if (!self.loop.initialized) {
        return;
    }

    // BUG-307: if this handler was replaced while its op was in flight, the
    // cancellation may have lost the kernel race (ASYNC_CANCEL -> ENOENT) and
    // the completion arrives as a normal POLLIN. This handler no longer owns
    // the exit status: consuming it here would starve the replacement's own
    // waitid (ECHILD) and its callback would never fire. Skip both and
    // finalize; the replacement handler reports the exit.
    if (handler.removed) {
        teardown_child_handler(self, handler);
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
        const errno: u32 = @truncate(~res + 1);
        // BUG-38: Only re-arm on transient errors (EINTR, EAGAIN).
        // Previously we re-armed on ANY non-zero return, which
        // included unrecoverable errors like ECHILD (no such
        // child — pidfd was already closed) or EINVAL. Re-arming
        // on those would loop forever calling waitid on a dead
        // pidfd.
        const eintr: u32 = @intFromEnum(std.os.linux.E.INTR);
        const eagain: u32 = @intFromEnum(std.os.linux.E.AGAIN);
        if (errno != eintr and errno != eagain) {
            std.log.err("on_child_exit: waitid failed with errno {d}, not re-arming", .{errno});
            return;
        }
        // Process might still be alive (though POLLIN triggered)?
        // Re-arm
        handler.task_id = try self.loop.io.queue(.{ .WaitReadable = .{
            .fd = handler.pidfd,
            .callback = .{
                .func = &on_child_exit,
                .cleanup = null,
                .data = .{ .user_data = handler },
            },
        } });
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

    if (python_c.PyObject_Call(handler.callback, py_args, null)) |py_res| {
        python_c.py_decref(py_res);
    } else {
        if (python_c.PyErr_GetRaisedException()) |exc| {
            defer python_c.py_decref(exc);
            if (python_c.PyDict_New()) |ctx| {
                defer python_c.py_decref(ctx);
                if (python_c.PyUnicode_FromString("Exception in child handler callback\x00")) |msg| {
                    defer python_c.py_decref(msg);
                    _ = python_c.PyDict_SetItemString(ctx, "message\x00", msg);
                    _ = python_c.PyDict_SetItemString(ctx, "exception\x00", exc);
                    const loop_obj = utils.get_parent_ptr(Loop.Python.LoopObject, self.loop);
                    if (python_c.PyObject_CallMethod(@ptrCast(loop_obj), "call_exception_handler\x00", "O\x00", ctx)) |ret| {
                        python_c.py_decref(ret);
                    } else {
                        python_c.PyErr_Clear();
                    }
                }
            }
        }
    }

    // BUG-313 & BUG-77 & BUG-157 & BUG-280: Finalize exactly once. Only
    // unmap the entry if it still points at THIS handler - a re-registration
    // during the user callback replaces the map entry, and blindly
    // fetchRemoving the pid would orphan the NEW handler (its armed op could
    // then never be torn down) while skipping our own teardown. In all
    // cases this exiting handler owns its teardown.
    if (self.handlers.get(handler.pid)) |current| {
        if (current == handler) {
            _ = self.handlers.remove(handler.pid);
        }
    }
    teardown_child_handler(self, handler);
}

pub fn traverse(self: *const ChildWatcher, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
    var it = self.handlers.valueIterator();
    while (it.next()) |handler| {
        const vret = visit.?(@ptrCast(handler.*.callback), arg);
        if (vret != 0) return vret;
    }
    return 0;
}
