const std = @import("std");

const CallbackManager = @import("callback_manager");
const IO = @import("main.zig");

pub const PerformData = struct { fd: std.posix.fd_t, fixed_file_index: ?u16 = null, fixed_buffer_index: ?u16 = null, callback: CallbackManager.Callback, data: std.os.linux.IoUring.ReadBuffer, offset: usize = 0, timeout: ?std.os.linux.kernel_timespec = null, zero_copy: bool = false };

pub const RecvMsgData = struct {
    fd: std.posix.fd_t,
    fixed_file_index: ?u16 = null,
    callback: CallbackManager.Callback,
    msg: *std.posix.msghdr,
    flags: u32 = 0,
};

pub fn wait_ready(ring: *std.os.linux.IoUring, set: *IO.BlockingTasksSet, data: IO.WaitData) !usize {
    const data_ptr = try set.push(.WaitReadable, &data.callback);
    errdefer data_ptr.discard();

    const fd_arg: std.os.linux.fd_t = if (data.fixed_file_index) |ffi| ffi else data.fd;
    const sqe = try ring.poll_add(@intCast(@intFromPtr(data_ptr)), fd_arg, std.c.POLL.IN);
    sqe.flags |= if (data.fixed_file_index != null) std.os.linux.IOSQE_FIXED_FILE else 0;

    if (data.timeout) |*timeout| {
        // BUG-334: ring.link_timeout() stores the timespec pointer in
        // sqe.addr, which the kernel dereferences at *submit* time — not
        // here. Submission is deferred (see queue_unlocked), so `timeout`
        // (a pointer into this function's by-value `data` parameter) is
        // dead stack by then. Copy into the BlockingTask's persistent
        // timer_storage, exactly as Timer.wait does.
        data_ptr.timer_storage = timeout.*;
        sqe.flags |= std.os.linux.IOSQE_IO_LINK;
        _ = ring.link_timeout(0, &data_ptr.timer_storage, 0) catch |err| {
            ring.sq.sqe_tail -%= 1;
            return err;
        };
    }

    // POLL_ADD has no pointer args — safe to defer submission.
    // Will be flushed by poll_blocking_events().
    return @intFromPtr(data_ptr);
}

pub fn recvmsg(ring: *std.os.linux.IoUring, set: *IO.BlockingTasksSet, data: RecvMsgData) !usize {
    const data_ptr = try set.push(.PerformRecvMsg, &data.callback);
    errdefer data_ptr.discard();

    const fd_arg: std.os.linux.fd_t = if (data.fixed_file_index) |ffi| ffi else data.fd;
    const sqe = try ring.recvmsg(@intCast(@intFromPtr(data_ptr)), fd_arg, data.msg, data.flags);
    sqe.flags |= if (data.fixed_file_index != null) std.os.linux.IOSQE_FIXED_FILE else 0;

    // No IOSQE_ASYNC: recvmsg on non-blocking socket returns EAGAIN inline,
    // kernel auto-installs poll callback — no workqueue context switch needed.

    // Flush SQE to kernel ring for immediate visibility. The kernel monitors
    // the shared SQ tail and will pick up this SQE on the next io_uring_enter
    // that waits for completions (e.g., submit_and_wait in poll_blocking_events).
    // This is NOT an io_uring_enter syscall — just a user-space memcpy to the
    // kernel's shared ring buffer. The actual submit+wait happens later in batch.
    _ = ring.flush_sq();

    // Deferred: msghdr is heap-allocated in transport struct (SockRecvFromData).
    // Flushed by poll_blocking_events() or auto-flush in queue().
    return @intFromPtr(data_ptr);
}

pub fn perform(ring: *std.os.linux.IoUring, set: *IO.BlockingTasksSet, data: PerformData) !usize {
    const data_ptr = try set.push(.PerformRead, &data.callback);
    errdefer data_ptr.discard();

    const fd_arg: std.os.linux.fd_t = if (data.fixed_file_index) |ffi| ffi else data.fd;
    const ff_flag: u8 = if (data.fixed_file_index != null) @as(u8, std.os.linux.IOSQE_FIXED_FILE) else 0;

    const sqe = blk: {
        if (data.fixed_buffer_index) |buf_idx| {
            const iovec_ptr = &set.loop.io.buffer_pool.iovecs[buf_idx];
            const sqe = try ring.read_fixed(@intCast(@intFromPtr(data_ptr)), fd_arg, iovec_ptr, data.offset, buf_idx);
            sqe.flags |= ff_flag;
            break :blk sqe;
        }
        if (data.zero_copy) {
            // BUG-335: io_uring has no zero-copy receive (MSG.ZEROCOPY is
            // transmit-only), and this branch used to point msg_storage.iov
            // at the caller's — possibly stack-allocated — iovec array,
            // which the kernel dereferences at submit time (BUG-30/BUG-334
            // class). The branch was unreachable (every caller passes
            // .buffer) and unsound, so non-.buffer selectors reject instead.
            switch (data.data) {
                .buffer_selection, .iovecs => return error.NotImplemented,
                .buffer => {},
            }
        }
        const sqe = try ring.read(@intCast(@intFromPtr(data_ptr)), fd_arg, data.data, data.offset);
        sqe.flags |= ff_flag;
        break :blk sqe;
    };

    if (data.timeout) |*timeout| {
        // BUG-334: see Read.wait_ready. The timespec must live in
        // heap-resident storage because the kernel reads sqe.addr at
        // submit time, which is deferred past this frame.
        data_ptr.timer_storage = timeout.*;
        sqe.flags |= std.os.linux.IOSQE_IO_LINK;
        _ = ring.link_timeout(0, &data_ptr.timer_storage, 0) catch |err| {
            ring.sq.sqe_tail -%= 1;
            return err;
        };
    }

    // Deferred: ring.read stores buffer pointer. Buffer is in transport
    // struct (heap) — safe until completion. Flushed by poll_blocking_events().
    return @intFromPtr(data_ptr);
}

test "BUG-335: the read path must not stage kernel pointers from caller-owned arrays" {
    // Structural tripwire (BUG-306 style). Read.perform's zero-copy branch
    // used to point the task's message header at the caller's iovec array,
    // which the kernel dereferences at submit time while submission is
    // deferred (BUG-30/BUG-334 class). The read path must never stage
    // caller-provided arrays into BlockingTask-owned kernel pointers;
    // multi-iovec reads go through Read.recvmsg with a caller-owned,
    // heap-resident msghdr instead.
    const src = @embedFile("read.zig");
    const needle = "data_ptr." ++ "msg_storage";
    try std.testing.expect(std.mem.find(u8, src, needle) == null);
}
