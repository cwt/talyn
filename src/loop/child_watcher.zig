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
    /// BUG-336: set when the wait op completes (on_child_exit entry). The
    /// BlockingTask slot is freed at that point and may be reused by
    /// Python-scheduled timers, so teardown paths must neither CancelIO
    /// the stale task_id nor destroy the handler out from under the
    /// executing callback — it owns the final teardown.
    completed: bool = false,
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
        if (handler.completed) {
            // BUG-336: the op already completed (its callback is executing
            // or queued with ownership); the slot may be reused already.
            // Neither cancel the stale task_id nor destroy the handler —
            // the callback invocation owns the final teardown.
        } else if (handler.task_id != 0) {
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
        if (old_handler.completed) {
            // BUG-336: completed op — stale task_id may alias a reused
            // slot, and the executing callback owns teardown. Neither
            // cancel nor destroy here.
        } else if (old_handler.task_id != 0) {
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

        if (handler.completed) {
            // BUG-336: the op already completed with its callback queued
            // or executing; that invocation owns the teardown. The stale
            // task_id may alias a reused slot — never cancel it — and the
            // handler must not be destroyed out from under the callback.
        } else if (handler.task_id != 0) {
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

/// BUG-362: single finalize for a handler whose exit path could not
/// dispatch its callback — unmaps (guarded by the BUG-313 identity check)
/// and releases pidfd, callback ref, and struct exactly once.
fn finalize_child_handler(self: *ChildWatcher, handler: *ChildHandler) void {
    if (self.handlers.get(handler.pid)) |current| {
        if (current == handler) {
            _ = self.handlers.remove(handler.pid);
        }
    }
    teardown_child_handler(self, handler);
}

/// BUG-362: interprets a waitid siginfo captured under WEXITED|WNOHANG.
/// Returns the child's return code, or `null` when the kernel reports no
/// state change (si_signo == 0 — a spurious success for a child that is
/// still running, whose siginfo_t the kernel leaves unwritten). Callers
/// must re-arm in that case instead of dispatching the fabricated status
/// the pre-fix switch produced from uninitialized/zeroed fields.
fn classify_child_siginfo(siginfo: *const std.os.linux.siginfo_t) ?i32 {
    if (@intFromEnum(siginfo.signo) == 0) {
        return null;
    }
    const CLD_EXITED = 1;
    const CLD_KILLED = 2;
    const CLD_DUMPED = 3;
    return switch (siginfo.code) {
        CLD_EXITED => siginfo.fields.common.second.sigchld.status,
        CLD_KILLED, CLD_DUMPED => -siginfo.fields.common.second.sigchld.status,
        else => 0,
    };
}

/// Arms a fresh WaitReadable op for a handler whose previous wait found
/// nothing to do (spurious WNOHANG return, EINTR, EAGAIN). The BUG-336
/// `completed` marker set on callback entry must be cleared again — the
/// new op is in flight and teardown paths must be able to cancel it.
fn rearm_child_handler(self: *ChildWatcher, handler: *ChildHandler) !void {
    handler.task_id = try self.loop.io.queue(.{ .WaitReadable = .{
        .fd = handler.pidfd,
        .callback = .{
            .func = &on_child_exit,
            .cleanup = null,
            .data = .{ .user_data = handler },
        },
    } });
    handler.completed = false;
}

fn on_child_exit(data: *const CallbackManager.CallbackData) !void {
    const handler: *ChildHandler = @ptrCast(@alignCast(data.user_data.?));
    // BUG-336: this wait is complete — its BlockingTask slot is freed and
    // may be synchronously reused by Python below (the child callback can
    // schedule call_later timers, then remove/replace this very handler).
    // Invalidate the ID and mark completion first so teardown paths
    // neither CancelIO the new occupant nor destroy this handler early;
    // this invocation owns the final teardown.
    handler.task_id = 0;
    handler.completed = true;
    if (data.cancelled()) {
        // BUG-280/BUG-307: cancellation now comes from remove_child_handler,
        // add_child_handler replacement, or watcher deinit - all of which
        // mark the handler removed and unmapped it, so this invocation owns
        // the teardown in every case. The `removed` check stays as a guard
        // against a future cancel source that doesn't mark (leak, not UAF).
        if (handler.removed) {
            teardown_child_handler(handler.watcher, handler);
        }
        return;
    }
    const self = handler.watcher;

    // BUG-362 (audit note): this branch is unreachable in the current
    // design - release_claimed sets `initialized = false` and only then
    // drains pending callbacks, but every drain dispatch forces
    // `cancelled = true`, and the cancelled branch above already owns the
    // teardown before this check. Touching `self.handlers` here would
    // risk use-after-free against ChildWatcher.deinit's map teardown, so
    // this stays a plain early-return.
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
    // BUG-362: with WNOHANG the kernel may successfully return without
    // any state change (the child is still running), leaving the siginfo
    // fields unwritten. `undefined` + the missing signo check read
    // uninitialized stack bytes as the child's exit status AND consumed
    // the handler without re-arming, so the real exit could never be
    // reported. Zero-fill instead, and re-arm when signo is 0 (true for
    // both kernel behaviours: si_signo cleared, or the struct left
    // untouched).
    var siginfo = std.mem.zeroes(std.os.linux.siginfo_t);
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
            // BUG-314: a non-transient waitid failure (e.g. ECHILD after the
            // child was reaped externally) used to just return, leaving the
            // handler mapped forever with an open pidfd and a leaked struct.
            // This op is finished (no re-arm, and no further completion can
            // arrive for it), so this invocation owns the final teardown:
            // unmap - only if the entry is still ours, per the BUG-313
            // identity guard - and release pidfd, callback ref, and struct.
            // BUG-362: reuse the single finalize helper (unmap with the
            // BUG-313 identity guard + full teardown).
            finalize_child_handler(self, handler);
            return;
        }
        // Process might still be alive (though POLLIN triggered)?
        // Re-arm: a new op is in flight, so clear the BUG-336 completed
        // marker set on entry — teardown paths must cancel this arm again.
        try rearm_child_handler(self, handler);
        return;
    }

    // BUG-362: WNOHANG with no state change (child still running). The
    // kernel wrote nothing useful into siginfo — re-arm instead of
    // dispatching a fabricated exit status and consuming the handler.
    const returncode = classify_child_siginfo(&siginfo) orelse {
        try rearm_child_handler(self, handler);
        return;
    };

    // Dispatch to Python. BUG-362: PyLong/PyTuple allocation failures
    // used to `return error.PythonError` with `completed` already true,
    // so ChildWatcher.deinit skipped the handler and leaked pidfd, the
    // callback reference and the struct — finalize on every error exit.
    const py_pid = python_c.PyLong_FromLong(handler.pid) orelse {
        finalize_child_handler(self, handler);
        return error.PythonError;
    };
    defer python_c.py_decref(py_pid);
    const py_rc = python_c.PyLong_FromLong(returncode) orelse {
        finalize_child_handler(self, handler);
        return error.PythonError;
    };
    defer python_c.py_decref(py_rc);

    const py_args = python_c.PyTuple_Pack(2, py_pid, py_rc) orelse {
        finalize_child_handler(self, handler);
        return error.PythonError;
    };
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
    finalize_child_handler(self, handler);
}

pub fn traverse(self: *const ChildWatcher, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
    var it = self.handlers.valueIterator();
    while (it.next()) |handler| {
        const vret = visit.?(@ptrCast(handler.*.callback), arg);
        if (vret != 0) return vret;
    }
    return 0;
}

test "BUG-362: waitid under WNOHANG on a still-running child succeeds with signo 0" {
    // waitid(P_PIDFD, <child>, WEXITED|WNOHANG) while the child is still
    // running yields exactly the kernel sentinel the on_child_exit guard
    // must re-arm on: a SUCCESS return whose siginfo_t the kernel does
    // NOT fill in (the fields stay as the caller zeroed them). The
    // pre-fix code read these unwritten bytes as the child's exit status
    // and consumed the handler, so the real exit could never be reported
    // afterwards. Self-PIDFD cannot serve as the live party (waiting on
    // oneself fails with ECHILD), so fork a real child.
    const fork_rc = std.os.linux.fork();
    if (utils.getSyscallErrno(fork_rc) != .SUCCESS) return error.SkipZigTest;
    if (fork_rc == 0) {
        // Child: stay alive until the parent SIGKILLs us.
        var ts = std.os.linux.timespec{ .sec = 30, .nsec = 0 };
        _ = std.os.linux.nanosleep(&ts, null);
        std.os.linux.exit(0);
    }
    const child_pid: i32 = @intCast(fork_rc);
    // Safety net: reap the child on any failure path (normally the
    // final waitid below consumes it, making both calls no-ops).
    defer {
        _ = std.os.linux.kill(child_pid, .KILL);
        var ws: u32 = 0;
        _ = std.os.linux.waitpid(child_pid, &ws, 0);
    }

    const rc = std.os.linux.syscall2(.pidfd_open, @as(usize, @intCast(child_pid)), 0);
    try std.testing.expectEqual(std.posix.E.SUCCESS, utils.getSyscallErrno(rc));
    const pidfd: std.posix.fd_t = @intCast(rc);
    defer _ = std.os.linux.close(pidfd);

    var siginfo = std.mem.zeroes(std.os.linux.siginfo_t);
    try std.testing.expectEqual(
        @as(usize, 0),
        std.os.linux.waitid(.PIDFD, pidfd, &siginfo, std.os.linux.W.EXITED | std.os.linux.W.NOHANG, null),
    );
    // The sentinel: SUCCESS with no state change; the kernel wrote
    // nothing into siginfo (signo stays zeroed).
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(siginfo.signo));
    try std.testing.expectEqual(@as(i32, 0), siginfo.code);
    // The guard classifies this as "no state change" instead of
    // fabricating a return code.
    try std.testing.expectEqual(@as(?i32, null), classify_child_siginfo(&siginfo));

    // The child's real exit must still be deliverable afterwards.
    _ = std.os.linux.kill(child_pid, .KILL);
    var pollfds = [_]std.os.linux.pollfd{.{ .fd = pidfd, .events = std.os.linux.POLL.IN, .revents = 0 }};
    const nready = try std.posix.poll(&pollfds, 5000);
    try std.testing.expectEqual(@as(usize, 1), nready);
    try std.testing.expect(pollfds[0].revents & std.os.linux.POLL.IN != 0);

    var exit_siginfo = std.mem.zeroes(std.os.linux.siginfo_t);
    try std.testing.expectEqual(
        @as(usize, 0),
        std.os.linux.waitid(.PIDFD, pidfd, &exit_siginfo, std.os.linux.W.EXITED | std.os.linux.W.NOHANG, null),
    );
    try std.testing.expectEqual(@as(u32, @intFromEnum(std.os.linux.SIG.CHLD)), @intFromEnum(exit_siginfo.signo));
    try std.testing.expectEqual(@as(i32, @intFromEnum(std.os.linux.CLD.KILLED)), exit_siginfo.code);
    try std.testing.expectEqual(@as(?i32, -9), classify_child_siginfo(&exit_siginfo));
}

test "BUG-362: an exited child's siginfo passes the guard and maps to its status" {
    var siginfo = std.mem.zeroes(std.os.linux.siginfo_t);
    siginfo.signo = .CHLD;
    siginfo.code = @intFromEnum(std.os.linux.CLD.EXITED);
    siginfo.fields.common.second.sigchld.status = 7;
    try std.testing.expectEqual(@as(?i32, 7), classify_child_siginfo(&siginfo));

    siginfo.code = @intFromEnum(std.os.linux.CLD.KILLED);
    siginfo.fields.common.second.sigchld.status = 9;
    try std.testing.expectEqual(@as(?i32, -9), classify_child_siginfo(&siginfo));
}
