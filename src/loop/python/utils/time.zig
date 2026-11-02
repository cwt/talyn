const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const Loop = @import("../../main.zig");

const std = @import("std");

pub fn loop_time(self: ?*Loop.Python.LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    _ = self.?;

    var time: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &time);

    const f_time: f64 = @as(f64, @floatFromInt(time.sec)) + @as(f64, @floatFromInt(time.nsec)) / 1_000_000_000;
    return python_c.PyFloat_FromDouble(f_time);
}
