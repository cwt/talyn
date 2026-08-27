// This module was made to work with python functions only
const std = @import("std");

const python_c = @import("python_c");
const utils = @import("utils");

const Loop = @import("main.zig");
const CallbackManager = @import("callback_manager");

// BUG-123: signal() and siginterrupt() are not wrapped by std.os.linux.
// Declare them as extern "c" directly instead of using @cImport (Rule 7).
pub const SIG_DFL: usize = 0;
pub const SIG_IGN: usize = 1;
pub const SigHandler = *const fn (i32) callconv(.c) void;
extern "c" fn signal(sig: i32, handler: SigHandler) callconv(.c) SigHandler;
extern "c" fn siginterrupt(sig: i32, flag: i32) i32;

fn default_signal_handler(_: i32) callconv(.c) void {}

const CallbacksBTree = utils.BTree(u6, CallbackManager.Callback, 3);

callbacks: CallbacksBTree = undefined,
fd: std.posix.fd_t = -1,
mask: std.posix.sigset_t = std.mem.zeroes(std.posix.sigset_t),
loop: *Loop = undefined,

blocking_task_id: usize = 0,

signalfd_info: std.os.linux.signalfd_siginfo = undefined,

fn dummy_signal_handler(_: i32) callconv(.c) void {
    // std.log.info("Dummy signal handler", .{});
}

fn signal_handler(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    if (data.cancelled() or io_uring_err == .CANCELED) return;

    const loop: *Loop = @ptrCast(@alignCast(data.user_data.?));
    if (io_uring_err != .SUCCESS) {
        const exception = python_c.PyObject_CallFunction(python_c.PyExc_OSError, "Ls\x00", @as(c_long, @intFromEnum(io_uring_err)), "IO error during signal handling\x00") orelse return error.PythonError;

        loop.mutex.lock();
        loop.stopping = true;
        loop.mutex.unlock();

        python_c.PyErr_SetRaisedException(exception);
        return error.PythonError;
    }

    const sig = loop.unix_signals.signalfd_info.signo;

    // BUG-37: If the callback for this signal was removed (via `unlink`)
    // between the signal being delivered and the io_uring read completing,
    // `get_value_ptr` returns null. Don't panic — just re-queue the read
    // (so we keep reading from signalfd) and skip the dispatch.
    const callback_ptr = loop.unix_signals.callbacks.get_value_ptr(@as(u6, @intCast(sig)), null) orelse {
        const buffer_to_read: std.os.linux.IoUring.ReadBuffer = .{
            .buffer = @as([*]u8, @ptrCast(&loop.unix_signals.signalfd_info))[0..@sizeOf(std.os.linux.signalfd_siginfo)],
        };

        loop.unix_signals.blocking_task_id = try loop.io.queue(.{
            .PerformRead = .{
                .fd = loop.unix_signals.fd,
                .data = buffer_to_read,
                .callback = CallbackManager.Callback{
                    .func = &signal_handler,
                    .cleanup = null,
                    .data = .{
                        .user_data = loop,
                    },
                },
                .offset = 0,
            },
        });
        return;
    };

    // BUG-153: Only incref user_data if it is a Python-managed handle
    // (indicated by a non-null cleanup function). For internal native callbacks
    // (such as the default SIGINT handler where user_data is *Loop), user_data
    // is a native Zig pointer and must NOT be increffed with Py_IncRef.
    if (callback_ptr.cleanup != null) {
        python_c.py_incref(@ptrCast(@alignCast(callback_ptr.data.user_data.?)));
    }

    try Loop.Scheduling.Soon.dispatch(loop, callback_ptr);

    const buffer_to_read: std.os.linux.IoUring.ReadBuffer = .{
        .buffer = @as([*]u8, @ptrCast(&loop.unix_signals.signalfd_info))[0..@sizeOf(std.os.linux.signalfd_siginfo)],
    };

    loop.unix_signals.blocking_task_id = try loop.io.queue(.{ .PerformRead = .{ .fd = loop.unix_signals.fd, .data = buffer_to_read, .callback = CallbackManager.Callback{
        .func = &signal_handler,
        .cleanup = null,
        .data = .{
            .user_data = loop,
        },
    }, .offset = 0 } });
}

fn default_sigint_signal_callback(data: *const CallbackManager.CallbackData) !void {
    if (data.cancelled()) return;

    python_c.PyErr_SetNone(python_c.PyExc_KeyboardInterrupt);
    return error.PythonError;
}

pub fn enqueue_signal_fd(self: *UnixSignals, comptime cancel_old: bool) !void {
    if (cancel_old) {
        const blocking_task_id = self.blocking_task_id;
        const loop = self.loop;
        if (blocking_task_id > 0) {
            _ = try loop.io.queue_unlocked(.{ .CancelIO = blocking_task_id });
        }
    }

    const buffer_to_read: std.os.linux.IoUring.ReadBuffer = .{
        .buffer = @as([*]u8, @ptrCast(&self.signalfd_info))[0..@sizeOf(std.os.linux.signalfd_siginfo)],
    };

    self.blocking_task_id = try self.loop.io.queue_unlocked(.{
        .PerformRead = .{
            .fd = self.fd,
            .data = buffer_to_read,
            .callback = CallbackManager.Callback{
                // .ZigGeneric = .{
                //     .data = loop,
                //     .callback = &signal_handler
                // }
                .func = &signal_handler,
                .cleanup = null,
                .data = .{
                    .user_data = self.loop,
                },
            },
        },
    });
}

pub fn link(self: *UnixSignals, sig: std.os.linux.SIG, callback: CallbackManager.Callback) !void {
    const mask = &self.mask;
    // BUG-306: Block the signal BEFORE installing the dummy handler. The
    // previous order installed the no-op handler first, leaving a window
    // in which an arriving signal was executed and discarded by the dummy
    // — neither raised as KeyboardInterrupt nor delivered via signalfd,
    // silently lost. Blocking first converts such an occurrence into a
    // PENDING signal that signalfd reports as soon as its mask covers it,
    // so nothing can slip through between setup steps.
    std.posix.sigaddset(mask, sig);
    std.posix.sigprocmask(std.os.linux.SIG.BLOCK, mask, null);

    // When the user create a new thread, we need to avoid that python catch the signal.
    // Installed second: glibc's siginterrupt patches the CURRENTLY installed
    // action, so it must run after signal().
    _ = signal(@as(i32, @intCast(@intFromEnum(sig))), @ptrCast(&dummy_signal_handler));
    _ = siginterrupt(@as(i32, @intCast(@intFromEnum(sig))), 0);

    self.fd = try std.posix.signalfd(self.fd, mask, 0);
    try self.enqueue_signal_fd(true);

    var prev_callback = self.callbacks.replace(@intCast(@intFromEnum(sig)), callback);
    if (prev_callback) |*v| {
        v.data.set_cancelled(true);
        try Loop.Scheduling.Soon.dispatch_nonthreadsafe(self.loop, v);
    } else {
        try self.loop.reserve_slots(1);
    }
}

pub fn unlink(self: *UnixSignals, sig: std.os.linux.SIG) !void {
    var callback_info = self.callbacks.delete(@intCast(@intFromEnum(sig)));
    if (callback_info) |*v| {
        v.data.set_cancelled(true);
        try Loop.Scheduling.Soon.dispatch_guaranteed_nonthreadsafe(self.loop, v);
    } else {
        return error.KeyNotFound;
    }

    // BUG-306: disarm completely BEFORE unblocking — drop the signal from
    // the signalfd mask, restore the default disposition, and unblock last.
    // Unblocking first let an arriving signal land on the still-installed
    // no-op dummy handler (no longer covered by signalfd), losing the event
    // silently during the teardown window.
    std.posix.sigdelset(&self.mask, sig);
    self.fd = try std.posix.signalfd(self.fd, &self.mask, 0);
    _ = signal(@as(i32, @intCast(@intFromEnum(sig))), &default_signal_handler);
    _ = siginterrupt(@as(i32, @intCast(@intFromEnum(sig))), 1);

    var mask: std.posix.sigset_t = std.posix.sigemptyset();
    std.posix.sigaddset(&mask, sig);
    std.posix.sigprocmask(std.os.linux.SIG.UNBLOCK, &mask, null);
}

pub fn init(loop: *Loop) !void {
    var mask: std.posix.sigset_t = std.posix.sigemptyset();
    const fd = try std.posix.signalfd(-1, &mask, std.os.linux.SFD.CLOEXEC);
    errdefer _ = std.os.linux.close(fd);

    loop.unix_signals = .{ .callbacks = try CallbacksBTree.init(loop.allocator), .fd = fd, .mask = mask, .loop = loop };
    const unix_signals = &loop.unix_signals;
    errdefer unix_signals.deinit();

    try unix_signals.link(std.os.linux.SIG.INT, CallbackManager.Callback{ .func = &default_sigint_signal_callback, .cleanup = null, .data = .{ .user_data = loop } });
}

pub fn deinit(self: *UnixSignals) void {
    _ = std.os.linux.close(self.fd);
    const loop = self.loop;

    var mask: std.posix.sigset_t = std.posix.sigemptyset();

    while (true) {
        var sig: u6 = undefined;
        var value = self.callbacks.pop(&sig) orelse break;
        std.posix.sigaddset(&mask, @as(std.os.linux.SIG, @enumFromInt(sig)));

        _ = signal(@as(i32, @intCast(sig)), &default_signal_handler);
        value.data.set_cancelled(true);
        Loop.Scheduling.Soon.dispatch_guaranteed_nonthreadsafe(loop, &value) catch |err| std.log.warn("dispatch failed: {s}", .{@errorName(err)});
    }

    std.posix.sigprocmask(std.os.linux.SIG.UNBLOCK, &mask, null);
    self.callbacks.deinit() catch |err| std.log.warn("deinit failed: {s}", .{@errorName(err)});
    self.fd = -1;
}

pub fn traverse(self: *const UnixSignals, visit: python_c.visitproc, arg: ?*anyopaque) i32 {
    if (self.fd < 0) return 0;
    return traverse_btree_node(self.callbacks.parent, visit, arg);
}

fn traverse_btree_node(node: anytype, visit: python_c.visitproc, arg: ?*anyopaque) i32 {
    const nkeys = node.nkeys;
    for (node.values[0..nkeys]) |*cb| {
        if (cb.data.traverse()) |t| {
            const vret = t(cb.data.user_data, @ptrCast(@constCast(visit)), arg);
            if (vret != 0) return vret;
        }

        if (cb.data.module_ptr()) |mp| {
            const vret = visit.?(@ptrCast(mp), arg);
            if (vret != 0) return vret;
        }

        if (cb.data.callback_ptr()) |cp| {
            const vret = visit.?(@ptrCast(cp), arg);
            if (vret != 0) return vret;
        }
    }
    for (node.childs[0 .. nkeys + 1]) |maybe_child| {
        if (maybe_child) |child| {
            const vret = traverse_btree_node(child, visit, arg);
            if (vret != 0) return vret;
        }
    }
    return 0;
}

// BUG-306: the race is between adjacent kernel calls inside link()/unlink()
// and cannot be triggered deterministically from user space, so the
// regression tripwire asserts the REQUIRED ORDERING structurally: block
// before dummy-handler install in link(), and full disarm (signalfd re-mask
// + default handler restore) before the final unblock in unlink(). Reading
// this module's own source at comptime keeps the guard zero-cost and fails
// the build if anyone ever swaps the steps back.
test "BUG-306: link blocks before dummy handler; unlink disarms before unblocking" {
    const src = @embedFile("unix_signals.zig");

    const link_start = std.mem.find(u8, src, "pub fn link(") orelse return error.TestUnexpectedResult;
    const unlink_start = std.mem.findPos(u8, src, link_start + 1, "pub fn unlink(") orelse return error.TestUnexpectedResult;
    const init_start = std.mem.findPos(u8, src, unlink_start + 1, "pub fn init(") orelse return error.TestUnexpectedResult;

    const link_body = src[link_start..unlink_start];
    const unlink_body = src[unlink_start..init_start];

    // link(): SIG.BLOCK must appear before the dummy handler install.
    const link_block = std.mem.find(u8, link_body, "SIG.BLOCK") orelse return error.TestUnexpectedResult;
    const link_dummy = std.mem.find(u8, link_body, "&dummy_signal_handler") orelse return error.TestUnexpectedResult;
    try std.testing.expect(link_block < link_dummy);

    // unlink(): both signalfd re-mask and default-handler restore must
    // precede the SIG.UNBLOCK.
    const unlink_signalfd = std.mem.find(u8, unlink_body, "self.fd = try std.posix.signalfd(self.fd, &self.mask") orelse return error.TestUnexpectedResult;
    const unlink_default = std.mem.find(u8, unlink_body, "&default_signal_handler") orelse return error.TestUnexpectedResult;
    const unblock_pos = std.mem.find(u8, unlink_body, "SIG.UNBLOCK") orelse return error.TestUnexpectedResult;
    try std.testing.expect(unlink_signalfd < unblock_pos);
    try std.testing.expect(unlink_default < unblock_pos);
}

const UnixSignals = @This();
