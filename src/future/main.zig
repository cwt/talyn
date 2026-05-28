const std = @import("std");
const Loop = @import("../loop/main.zig");

const python_c = @import("python_c");
const CallbackManager = @import("callback_manager");

pub const FutureStatus = enum {
    pending, finished, canceled
};

result: ?*anyopaque = null,
status: FutureStatus = .pending,

callbacks_queue: Callback.CallbacksSetData = undefined,
exceptions_queue: std.ArrayList(?*python_c.PyObject) = undefined,
loop: *Loop,

released: bool = false,
python_payload: CallbackManager.PythonPayload = .{},


pub fn init(self: *Future, loop: *Loop) !void {
    try loop.reserve_slots(1);

    self.* = .{
        .loop = loop,
    };

    self.callbacks_queue = .{ .items = &.{}, .capacity = 0 };
    self.exceptions_queue = .{ .items = &.{}, .capacity = 0 };
}

pub fn release(self: *Future) void {
    Callback.release_callbacks_queue(&self.callbacks_queue);
    self.callbacks_queue.deinit(self.loop.allocator);
    self.exceptions_queue.deinit(self.loop.allocator);
    if (self.status == .pending) {
        self.loop.reserved_slots -= 1;
    }
    self.released = true;
}

pub const Callback = @import("callback.zig");
pub const Python = @import("python/main.zig");


const Future = @This();
