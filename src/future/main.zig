const std = @import("std");
const Loop = @import("../loop/main.zig");

const python_c = @import("python_c");
const CallbackManager = @import("callback_manager");

pub const FutureStatus = enum { pending, finished, canceled };

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

    self.callbacks_queue = .empty;
    self.exceptions_queue = .empty;
}

pub fn release(self: *Future) void {
    if (self.released) return;
    // BUG-369: fence FIRST — the decrefs below (done callbacks,
    // exception objects) can synchronously run Python finalizers that
    // re-enter release() (or tp_clear) while previously `released` was
    // still false, double-freeing the callbacks queue and
    // double-decrementing reserved_slots.
    self.released = true;

    if (self.status == .pending) {
        self.loop.reserved_slots -= 1;
    }
    Callback.release_callbacks_queue(&self.callbacks_queue);
    self.callbacks_queue.deinit(self.loop.allocator);
    for (self.exceptions_queue.items) |*exc| {
        python_c.py_xdecref(exc.*);
        exc.* = null;
    }
    self.exceptions_queue.deinit(self.loop.allocator);
}

pub const Callback = @import("callback.zig");
pub const Python = @import("python/main.zig");

const Future = @This();
