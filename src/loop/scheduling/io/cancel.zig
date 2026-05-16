const std = @import("std");
const IO = @import("main.zig");

pub fn perform(ring: *std.os.linux.IoUring, task_id: usize) !usize {
    const task: *IO.BlockingTask= @ptrFromInt(task_id);

    if (task.operation == .WaitTimer) {
        _ = try ring.timeout_remove(0, task_id, 0);
    }else{
        _ = try ring.cancel(0, task_id, 0);
    }

    const ret = try IO.submit_guaranteed(ring);
    // With SQPOLL, submit() may return 0 if the kernel thread consumed
    // the cancel SQE before enter() reports it — that's still success.
    if (ret == 0) {
        return error.SQENotSubmitted;
    }
    return 0;
}
