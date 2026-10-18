const std = @import("std");

pub fn perform_timer(ring: *std.os.linux.IoUring, task_id: usize) !usize {
    _ = try ring.timeout_remove(0, task_id, 0);
    return 0;
}

pub fn perform_io(ring: *std.os.linux.IoUring, task_id: usize) !usize {
    _ = try ring.cancel(0, task_id, 0);
    return 0;
}

pub fn perform_by_fd(ring: *std.os.linux.IoUring, fd: usize) !usize {
    const sqe = try ring.get_sqe();
    sqe.prep_cancel_fd(@intCast(fd), std.os.linux.IORING_ASYNC_CANCEL_FD);
    sqe.user_data = 0;
    return 0;
}

