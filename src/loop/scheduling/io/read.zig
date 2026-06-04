const std = @import("std");

const CallbackManager = @import("callback_manager");
const IO = @import("main.zig");

pub const PerformData = struct {
    fd: std.posix.fd_t,
    fixed_file_index: ?u16 = null,
    fixed_buffer_index: ?u16 = null,
    callback: CallbackManager.Callback,
    data: std.os.linux.IoUring.ReadBuffer,
    offset: usize = 0,
    timeout: ?std.os.linux.kernel_timespec = null,
    zero_copy: bool = false
};

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
        sqe.flags |= std.os.linux.IOSQE_IO_LINK;
        const timeout_sqe = ring.link_timeout(0, timeout, 0) catch |err| {
            ring.sq.sqe_tail -%= 1;
            return err;
        };
        timeout_sqe.flags |= std.os.linux.IOSQE_ASYNC;
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
            switch (data.data) {
                .buffer_selection => return error.NotImplemented,
                .iovecs => |iovecs| {
                    data_ptr.msg_storage.name = null;
                    data_ptr.msg_storage.namelen = 0;
                    data_ptr.msg_storage.iov = @constCast(iovecs.ptr);
                    data_ptr.msg_storage.iovlen = @intCast(iovecs.len);
                    data_ptr.msg_storage.control = null;
                    data_ptr.msg_storage.controllen = 0;
                    data_ptr.msg_storage.flags = 0;
                },
                .buffer => {
                    const sqe = try ring.read(@intCast(@intFromPtr(data_ptr)), fd_arg, data.data, data.offset);
                    sqe.flags |= ff_flag;
                    break :blk sqe;
                }
            }

            const sqe = try ring.recvmsg(@intCast(@intFromPtr(data_ptr)), fd_arg, &data_ptr.msg_storage, std.posix.MSG.ZEROCOPY);
            sqe.flags |= ff_flag;

            // Deferred: msg_storage lives in task_data_pool (heap).
            // iovecs point to transport's heap-allocated recv buffer.
            break :blk sqe;
        }
        const sqe = try ring.read(@intCast(@intFromPtr(data_ptr)), fd_arg, data.data, data.offset);
        sqe.flags |= ff_flag;
        break :blk sqe;
    };

    if (data.timeout) |*timeout| {
        sqe.flags |= std.os.linux.IOSQE_IO_LINK;
        const timeout_sqe = ring.link_timeout(0, timeout, 0) catch |err| {
            ring.sq.sqe_tail -%= 1;
            return err;
        };
        timeout_sqe.flags |= std.os.linux.IOSQE_ASYNC;
    }

    // Deferred: ring.read stores buffer pointer. Buffer is in transport
    // struct (heap) — safe until completion. Flushed by poll_blocking_events().
    return @intFromPtr(data_ptr);
}
