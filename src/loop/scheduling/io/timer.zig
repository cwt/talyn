const std = @import("std");

const CallbackManager = @import("callback_manager");
const IO = @import("main.zig");

pub const DelayType = enum(u32) {
    Relative = 0,
    Absolute = std.os.linux.IORING_TIMEOUT_ABS
};

pub const WaitData = struct {
    callback: CallbackManager.Callback,
    duration: std.os.linux.timespec,
    delay_type: DelayType
};

pub fn wait(ring: *std.os.linux.IoUring, set: *IO.BlockingTasksSet, data: WaitData) !usize {
    const data_ptr = try set.push(.WaitTimer, &data.callback);
    errdefer data_ptr.discard();

    // Copy timespec to persistent BlockingTask storage.
    // ring.timeout() stores a pointer in sqe.addr. With deferred submission,
    // the kernel reads this pointer at flush time (in poll_blocking_events),
    // not here. The data must be valid until then.
    const ts_sec_info = @typeInfo(@FieldType(std.os.linux.timespec, "sec")).int;
    const kts_sec_info = @typeInfo(@FieldType(std.os.linux.kernel_timespec, "sec")).int;
    if (ts_sec_info.bits == kts_sec_info.bits and ts_sec_info.signedness == kts_sec_info.signedness) {
        data_ptr.timer_storage = @bitCast(data.duration);
    } else {
        data_ptr.timer_storage = .{
            .sec = @intCast(data.duration.tv_sec),
            .nsec = @intCast(data.duration.tv_nsec),
        };
    }

    const sqe = try ring.timeout(
        @intCast(@intFromPtr(data_ptr)),
        &data_ptr.timer_storage, 0,
        @intFromEnum(data.delay_type)
    );
    _ = sqe;

    // Deferred submission — flushed by poll_blocking_events().
    return @intFromPtr(data_ptr);
}
