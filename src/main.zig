pub const Future = @import("future/main.zig");
pub const Task = @import("task/main.zig");
pub const Loop = @import("loop/main.zig");
pub const Handle = @import("handle.zig");
pub const TimerHandle = @import("timer_handle.zig");
pub const Transports = @import("transports/main.zig");

test {
    _ = Loop;
    _ = Transports;
    // P23/Future container regression tests live in future/callback.zig
    // (InlineQueue span discipline); pull them into the talyn test root.
    _ = @import("future/callback.zig");
}
