const std = @import("std");
const IO = @import("main.zig");

pub fn perform(ring: *std.os.linux.IoUring, task_id: usize) !usize {
    const task: *IO.BlockingTask= @ptrFromInt(task_id);

    if (task.operation == .WaitTimer) {
        _ = try ring.timeout_remove(0, task_id, 0);
    }else{
        _ = try ring.cancel(0, task_id, 0);
    }

    return 0;
}

pub fn perform_by_fd(ring: *std.os.linux.IoUring, fd: usize) !usize {
    _ = try ring.cancel(0, @intCast(fd), std.os.linux.IORING_ASYNC_CANCEL_FD);
    return 0;
}
