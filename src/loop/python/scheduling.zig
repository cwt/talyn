const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const CallbackManager = @import("callback_manager");
const Loop = @import("../main.zig");
const Handle = @import("../../handle.zig");
const TimerHandle = @import("../../timer_handle.zig");

const LoopObject = Loop.Python.LoopObject;

const std = @import("std");

pub inline fn get_callback_info(allocator: std.mem.Allocator, args: []?PyObject) !?[]PyObject {
    if (args.len == 0) {
        return null;
    }

    const callback_info = try allocator.alloc(PyObject, args.len);
    errdefer allocator.free(callback_info);

    for (args, callback_info) |arg, *ci| {
        ci.* = python_c.py_newref(arg.?);
    }
    errdefer {
        for (callback_info) |arg| {
            python_c.py_decref(@ptrCast(arg));
        }
    }

    return callback_info;
}

inline fn z_loop_call_soon(
    self: *LoopObject, args: []?PyObject,
    knames: ?PyObject, comptime thread_safe: bool
) !*Handle.PythonHandleObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (!thread_safe and Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len == 0) {
        python_c.raise_python_value_error("Invalid number of arguments\x00");
        return error.PythonError;
    }

    var context: ?PyObject = null;
    try python_c.parse_vector_call_kwargs(
        knames, args.ptr + args.len,
        &.{"context\x00"},
        &.{&context},
    );

    const loop_data = utils.get_data_ptr(Loop, self);

    var py_handle: *Handle.PythonHandleObject = undefined;
    var py_callback: PyObject = undefined;
    {
        errdefer python_c.py_xdecref(context);

        if (context) |py_ctx| {
            if (python_c.is_none(py_ctx)) {
                context = python_c.PyContext_CopyCurrent()
                    orelse return error.PythonError;
                python_c.py_decref(py_ctx);
            }else if (!python_c.is_type(py_ctx, &python_c.PyContext_Type)) {
                python_c.raise_python_type_error("Invalid context\x00");
                return error.PythonError;
            }
        }else{
            context = python_c.PyContext_CopyCurrent() orelse return error.PythonError;
        }

        const allocator = loop_data.allocator;

        const callback_info = try get_callback_info(allocator, args[1..]);
        errdefer {
            if (callback_info) |_args| {
                for (_args) |arg| {
                    python_c.py_decref(@ptrCast(arg));
                }
                allocator.free(_args);
            }
        }

        py_callback = python_c.py_newref(args[0].?);
        errdefer python_c.py_decref(py_callback);

        if (python_c.PyCallable_Check(py_callback) <= 0) {
            python_c.raise_python_type_error("Invalid callback\x00");
            return error.PythonError;
        }

        py_handle = try Handle.fast_new_handle(
            context.?, loop_data, py_callback, callback_info, thread_safe
        );
    }
    errdefer python_c.py_decref(@ptrCast(py_handle));

    const mutex = &loop_data.mutex;
    mutex.lock();
    defer mutex.unlock();

    if (!loop_data.initialized) {
        python_c.raise_python_runtime_error("Loop is closed\x00");
        return error.PythonError;
    }

    const callback = CallbackManager.Callback{
        .func = &Handle.callback_for_python_generic_callbacks,
        .cleanup = &Handle.release_python_generic_callback,
        .data = CallbackManager.CallbackData.init_python(py_handle, &py_handle.python_payload),
    };
    try Loop.Scheduling.Soon.dispatch_nonthreadsafe(loop_data, &callback);
    return python_c.py_newref(py_handle);
}

pub fn loop_call_soon(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*Handle.PythonHandleObject {
    return utils.execute_zig_function(z_loop_call_soon, .{
        self.?, args.?[0..@as(usize, @intCast(nargs))], knames,
        false
    });
}

pub fn loop_call_soon_threadsafe(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*Handle.PythonHandleObject {
    return utils.execute_zig_function(z_loop_call_soon, .{
        self.?, args.?[0..@as(usize, @intCast(nargs))], knames,
        true
    });
}

inline fn z_loop_delayed_call(
    self: *LoopObject, args: []?PyObject,
    knames: ?PyObject, comptime is_absolute: bool
) !*TimerHandle.PythonTimerHandleObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len <= 1) {
        python_c.raise_python_value_error("Invalid number of arguments\x00");
        return error.PythonError;
    }

    var context: ?PyObject = null;
    try python_c.parse_vector_call_kwargs(
        knames, args.ptr + args.len,
        &.{"context\x00"},
        &.{&context},
    );

    const loop_data = utils.get_data_ptr(Loop, self);
    var py_timer_handle: *TimerHandle.PythonTimerHandleObject = undefined;
    var time: std.posix.timespec = undefined;
    {
        errdefer python_c.py_xdecref(context);

        if (context) |py_ctx| {
            if (python_c.is_none(py_ctx)) {
                context = python_c.PyContext_CopyCurrent()
                    orelse return error.PythonError;
                python_c.py_decref(py_ctx);
            }else if (!python_c.is_type(py_ctx, &python_c.PyContext_Type)) {
                python_c.raise_python_type_error("Invalid context\x00");
                return error.PythonError;
            }
        }else{
            context = python_c.PyContext_CopyCurrent() orelse return error.PythonError;
        }

        const allocator = loop_data.allocator;

        const callback_info = try get_callback_info(allocator, args[2..]);
        errdefer {
            if (callback_info) |_args| {
                for (_args) |arg| {
                    python_c.py_decref(@ptrCast(arg));
                }
                allocator.free(_args);
            }
        }

        const ts: f64 = python_c.PyFloat_AsDouble(args[0].?);
        if (ts < 0.0) {
            python_c.raise_python_value_error("Invalid value received in the first parameter\x00");
            return error.PythonError;
        }

        if (is_absolute) {
            const when_sec = @trunc(ts);
            time = .{
                .sec = @intFromFloat(when_sec),
                .nsec = @as(@FieldType(std.posix.timespec, "nsec"), @intFromFloat((ts - when_sec) * 1_000_000_000))
            };
        }else{
            var raw_ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.MONOTONIC, &raw_ts);
            time = @bitCast(raw_ts);
            const delay_sec = @trunc(ts);

            time.sec += @intFromFloat(delay_sec);
            time.nsec += @as(@FieldType(std.posix.timespec, "nsec"), @intFromFloat((ts - delay_sec) * 1_000_000_000));
        }

        const py_callback = python_c.py_newref(args[1].?);
        errdefer python_c.py_decref(py_callback);

        if (python_c.PyCallable_Check(py_callback) <= 0) {
            python_c.raise_python_type_error("Invalid callback\x00");
            return error.PythonError;
        }

        py_timer_handle = try TimerHandle.fast_new_timer_handle(
            time, context.?, loop_data, py_callback, callback_info, 
        );
    }
    errdefer python_c.py_decref(@ptrCast(py_timer_handle));


    const mutex = &loop_data.mutex;
    mutex.lock();
    defer mutex.unlock();

    if (!loop_data.initialized) {
        python_c.raise_python_runtime_error("Loop is closed\x00");
        return error.PythonError;
    }

    const callback = CallbackManager.Callback{
        .func = &Handle.callback_for_python_generic_callbacks,
        .cleanup = &Handle.release_python_generic_callback,
        .data = CallbackManager.CallbackData.init_python(py_timer_handle, &py_timer_handle.handle.python_payload),
    };
    py_timer_handle.handle.blocking_task_id = try loop_data.io.queue_unlocked(.{
        .WaitTimer = .{
            .callback = callback,
            .duration = time,
            .delay_type = .Absolute
        }
    });
    return python_c.py_newref(py_timer_handle);
}
pub fn loop_call_later(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*TimerHandle.PythonTimerHandleObject {
    return utils.execute_zig_function(z_loop_delayed_call, .{
        self.?, args.?[0..@as(usize, @intCast(nargs))], knames,
        false
    });
}

pub fn loop_call_at(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*TimerHandle.PythonTimerHandleObject {
    
    return utils.execute_zig_function(z_loop_delayed_call, .{
        self.?, args.?[0..@as(usize, @intCast(nargs))], knames,
        true
    });
}
