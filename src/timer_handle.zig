const std = @import("std");
const builtin = @import("builtin");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const Loop = @import("loop/main.zig");
const Handle = @import("handle.zig");
const utils = @import("utils");

pub const PythonTimerHandleObject = extern struct { handle: Handle.PythonHandleObject, when: std.posix.timespec };

pub inline fn fast_new_timer_handle(
    time: std.posix.timespec,
    contextvars: PyObject,
    loop_data: *Loop,
    py_callback: PyObject,
    args: ?[]PyObject,
) !*PythonTimerHandleObject {
    const instance: *PythonTimerHandleObject = @ptrCast(PythonTimerHandleType.tp_alloc.?(&PythonTimerHandleType, 0) orelse return error.PythonError);
    instance.handle.contextvars = contextvars;
    instance.handle.loop_data = loop_data;
    instance.handle.py_callback = py_callback;

    if (args) |v| {
        instance.handle.py_callback_args = v.ptr;
        instance.handle.py_callback_len = v.len;
    } else {
        instance.handle.py_callback_args = null;
        instance.handle.py_callback_len = 0;
    }

    instance.handle.blocking_task_id = 0;
    instance.handle.cancelled = false;
    instance.handle.finished = false;
    instance.handle.thread_safe = false;
    instance.handle.python_payload = .{
        .module_ptr = @ptrCast(utils.get_parent_ptr(Loop.Python.LoopObject, loop_data)),
        .callback_ptr = py_callback,
        .traverse = &Handle.traverse_python_generic_callback,
    };
    instance.when = time;

    return instance;
}

inline fn z_timer_handle_init(self: *PythonTimerHandleObject, args: ?PyObject, kwargs: ?PyObject) !c_int {
    var kwlist: [3][*c]u8 = undefined;
    kwlist[0] = @constCast("ts\x00");
    kwlist[1] = @constCast("context\x00");
    kwlist[2] = null;

    var ts: f64 = 0.0;
    var py_context: ?PyObject = null;

    if (python_c.PyArg_ParseTupleAndKeywords(args, kwargs, "dO\x00", @ptrCast(&kwlist), &ts, &py_context) < 0) {
        return error.PythonError;
    }

    if (!std.math.isFinite(ts) or ts < 0.0) {
        python_c.raise_python_value_error("Invalid when timestamp\x00");
        return error.PythonError;
    }

    if (py_context) |ctx| {
        if (python_c.is_none(ctx)) {
            python_c.raise_python_type_error("context cannot be None\x00");
            return error.PythonError;
        }
    } else {
        python_c.raise_python_type_error("context is required\x00");
        return error.PythonError;
    }

    self.handle.contextvars = python_c.py_newref(py_context.?);

    const max_time_secs: f64 = @floatFromInt(std.math.maxInt(std.posix.time_t) - 1_000_000_000);
    const safe_ts = @min(ts, max_time_secs);
    const ts_sec = @trunc(safe_ts);
    const frac = @max(0.0, safe_ts - ts_sec);
    self.when = .{
        .sec = @intFromFloat(ts_sec),
        .nsec = @as(@FieldType(std.posix.timespec, "nsec"), @intFromFloat(@min(999_999_999.0, frac * 1_000_000_000))),
    };

    return 0;
}

fn handle_init(self: ?*PythonTimerHandleObject, args: ?PyObject, kwargs: ?PyObject) callconv(.c) c_int {
    return utils.execute_zig_function(z_timer_handle_init, .{ self.?, args, kwargs });
}

pub fn timer_handle_when(self: ?*PythonTimerHandleObject, _: ?PyObject) callconv(.c) ?PyObject {
    const time = self.?.when;
    const when = @as(f64, @floatFromInt(time.sec)) + @as(f64, @floatFromInt(time.nsec)) / 1_000_000_000;
    return python_c.PyFloat_FromDouble(when);
}

pub fn timer_handle_traverse(self: ?*PythonTimerHandleObject, visit: python_c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    return Handle.handle_traverse(@ptrCast(self), visit, arg);
}

pub fn timer_handle_clear(self: ?*PythonTimerHandleObject) callconv(.c) c_int {
    return Handle.handle_clear(@ptrCast(self));
}

pub fn timer_handle_dealloc(self: ?*PythonTimerHandleObject) callconv(.c) void {
    Handle.handle_dealloc(@ptrCast(self));
}

const PythonTimerHandleMethods: []const python_c.PyMethodDef = &[_]python_c.PyMethodDef{ python_c.PyMethodDef{ .ml_name = "when\x00", .ml_meth = @ptrCast(&timer_handle_when), .ml_doc = "Return a scheduled callback time as float seconds.\x00", .ml_flags = python_c.METH_NOARGS }, python_c.PyMethodDef{ .ml_name = null, .ml_meth = null, .ml_doc = null, .ml_flags = 0 } };

pub var PythonTimerHandleType = python_c.PyTypeObject{
    .tp_name = "talyn.TimerHandle\x00",
    .tp_doc = "Talyn's handle class\x00",
    .tp_base = &Handle.PythonHandleType,
    .tp_basicsize = @sizeOf(PythonTimerHandleObject),
    .tp_itemsize = 0,
    .tp_flags = python_c.Py_TPFLAGS_DEFAULT | python_c.Py_TPFLAGS_BASETYPE | python_c.Py_TPFLAGS_HAVE_GC,
    .tp_new = &python_c.PyType_GenericNew,
    .tp_init = @ptrCast(&handle_init),
    .tp_traverse = @ptrCast(&timer_handle_traverse),
    .tp_clear = @ptrCast(&timer_handle_clear),
    .tp_dealloc = @ptrCast(&timer_handle_dealloc),
    .tp_methods = @constCast(PythonTimerHandleMethods.ptr),
    .tp_members = null,
};
