const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const CallbackManager = @import("callback_manager");
const Handle = @import("../../../handle.zig");
const Loop = @import("../../main.zig");

const LoopObject = Loop.Python.LoopObject;

const Scheduling = @import("../scheduling.zig");

fn loop_watchers_cleanup_callback(ptr: ?*anyopaque) void {
    const watcher: *Loop.FDWatcher = @alignCast(@ptrCast(ptr.?));

    const loop_data = watcher.loop_data;
    const allocator = loop_data.allocator;

    const fd = watcher.fd;
    if (fd >= 0) {
        _ = switch (watcher.event_type) {
            std.c.POLL.IN => loop_data.reader_watchers.delete(fd),
            std.c.POLL.OUT => loop_data.writer_watchers.delete(fd),
            else => null
        };
    }

    python_c.py_decref(@ptrCast(watcher.handle));
    allocator.destroy(watcher);
}

fn loop_watcher_python_wrapper_traverse(ptr: ?*anyopaque, visit_ptr: ?*anyopaque, arg: ?*anyopaque) c_int {
    const watcher: *Loop.FDWatcher = @alignCast(@ptrCast(ptr.?));
    const visit: python_c.visitproc = @ptrCast(@alignCast(visit_ptr.?));
    return visit.?(@ptrCast(watcher.handle), arg);
}

fn loop_watcher_python_wrapper_cleanup(ptr: ?*anyopaque) void {
    loop_watchers_cleanup_callback(ptr);
}

fn loop_watcher_python_wrapper_callback(data: *const CallbackManager.CallbackData) !void {
    const watcher: *Loop.FDWatcher = @alignCast(@ptrCast(data.user_data.?));
    const loop_data = watcher.loop_data;
    const fd = watcher.fd;

    if (data.cancelled() or fd < 0) {
        loop_watchers_cleanup_callback(watcher);
        return;
    }

    var temp_data = data.*;
    temp_data.user_data = watcher.handle;
    temp_data.set_python(&watcher.handle.python_payload);

    watcher.handle.cancelled = false;
    watcher.handle.finished = false;

    try Handle.callback_for_python_generic_callbacks(&temp_data);

    const mutex = &loop_data.mutex;
    mutex.lock();
    defer mutex.unlock();

    if (!loop_data.initialized or watcher.fd < 0) {
        loop_watchers_cleanup_callback(watcher);
        return;
    }

    const rearmed = blk: {
        const watcher_callback: CallbackManager.Callback = .{
            .func = &loop_watchers_callback,
            .cleanup = null,
            .data = .{
                .user_data = watcher
            }
        };

        const blocking_task_id = loop_data.io.queue_unlocked(
            switch (watcher.event_type) {
                std.c.POLL.IN => Loop.Scheduling.IO.BlockingOperationData{
                    .WaitReadable = .{
                        .fd = watcher.fd,
                        .callback = watcher_callback,
                    },
                },
                std.c.POLL.OUT => Loop.Scheduling.IO.BlockingOperationData{
                    .WaitWritable = .{
                        .fd = watcher.fd,
                        .callback = watcher_callback,
                    },
                },
                else => break :blk false,
            }
        ) catch {
            break :blk false;
        };
        watcher.blocking_task_id = blocking_task_id;
        break :blk true;
    };

    if (!rearmed) {
        loop_watchers_cleanup_callback(watcher);
    }
}

fn loop_watchers_callback(data: *const CallbackManager.CallbackData) !void {
    const watcher: *Loop.FDWatcher = @alignCast(@ptrCast(data.user_data.?));

    const fd = watcher.fd;
    if (data.cancelled() or fd < 0) {
        @call(.always_inline, loop_watchers_cleanup_callback, .{watcher});
        return;
    }

    const io_uring_err = data.io_uring_err();
    if (io_uring_err == .SUCCESS) {
        const loop_data = watcher.loop_data;
        const handle = watcher.handle;
        const callback = CallbackManager.Callback{
            .func = &loop_watcher_python_wrapper_callback,
            .cleanup = &loop_watcher_python_wrapper_cleanup,
            .data = CallbackManager.CallbackData.init_python(watcher, &watcher.python_payload),
        };

        watcher.blocking_task_id = 0; // Clear blocking task ID since it is no longer in-flight in io_uring
        try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
        python_c.py_incref(@ptrCast(handle));
    } else {
        @call(.always_inline, loop_watchers_cleanup_callback, .{watcher});
        return;
    }
}

inline fn z_loop_add_watcher(
    self: *LoopObject, args: []?PyObject,
    operation: Loop.Scheduling.IO.BlockingOperation
) !PyObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len < 2) {
        python_c.raise_python_value_error("Invalid number of arguments\x00");
        return error.PythonError;
    }

    const loop_data = utils.get_data_ptr(Loop, self);

    const py_fd: PyObject = args[0].?;
    if (!python_c.long_check(py_fd)) {
        python_c.raise_python_runtime_error("Invalid file descriptor\x00");
        return error.PythonError;
    }

    const fd_val = python_c.PyLong_AsLong(py_fd);
    if (python_c.PyErr_Occurred() != null) return error.PythonError;
    const fd: std.posix.fd_t = @intCast(fd_val);
    if (fd < 0) {
        python_c.raise_python_value_error("Invalid file descriptor\x00");
        return error.PythonError;
    }

    const allocator = loop_data.allocator;

    var py_handle: *Handle.PythonHandleObject = undefined;
    {
        const context = python_c.PyContext_CopyCurrent()
            orelse return error.PythonError;
        errdefer python_c.py_decref(context);

        const callback_info = try Scheduling.get_callback_info(allocator, args[2..]);
        errdefer {
            if (callback_info) |_args| {
                for (_args) |arg| {
                    python_c.py_decref(@ptrCast(arg));
                }
                allocator.free(_args);
            }
        }

        const py_callback = python_c.py_newref(args[1].?);
        errdefer python_c.py_decref(py_callback);

        if (python_c.PyCallable_Check(py_callback) <= 0) {
            python_c.raise_python_runtime_error("Invalid callback\x00");
            return error.PythonError;
        }

        py_handle = try Handle.fast_new_handle(
            context, loop_data, py_callback, callback_info, false
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

    const watcher_data: Loop.FDWatcher = .{
        .handle = py_handle,
        .loop_data = loop_data,
        .event_type = switch (operation) {
            .WaitReadable => std.c.POLL.IN,
            .WaitWritable => std.c.POLL.OUT,
            else => {
                python_c.raise_python_runtime_error("Invalid operation type for watcher\x00");
                return error.PythonError;
            }
        },
        .fd = fd,
        .python_payload = .{
            .module_ptr = @ptrCast(utils.get_parent_ptr(Loop.Python.LoopObject, loop_data)),
            .callback_ptr = py_handle.py_callback,
            .traverse = &loop_watcher_python_wrapper_traverse,
        }
    };

        const watchers = switch (operation) {
        .WaitWritable => &loop_data.writer_watchers,
        .WaitReadable => &loop_data.reader_watchers,
        else => {
            python_c.raise_python_runtime_error("Invalid operation type for watcher\x00");
            return error.PythonError;
        }
        };


    const existing_watcher_ptr: ?*Loop.FDWatcher = watchers.get_value(fd, null);
    if (existing_watcher_ptr) |existing_watcher_data| {
        // Remove old watcher from hash map
        _ = watchers.delete(fd);

        // Cancel in-flight IO; cleanup callback will free the struct & decref handle
        if (existing_watcher_data.blocking_task_id != 0) {
            existing_watcher_data.fd = -1;
            _ = try loop_data.io.queue_unlocked(.{ .Cancel = existing_watcher_data.blocking_task_id });
        } else {
            // Wrapper callback is pending in Soon queue.
            // We set fd = -1 so the wrapper cleans it up when it runs.
            existing_watcher_data.fd = -1;
        }
        // Fall through to create a new watcher with the new handle
    }

    const watcher_data_ptr = try allocator.create(Loop.FDWatcher);
    errdefer allocator.destroy(watcher_data_ptr);

    watcher_data_ptr.* = watcher_data;

    if (!watchers.insert(fd, watcher_data_ptr)) {
        python_c.raise_python_runtime_error("Unexpected error adding watcher\x00");
        return error.PythonError;
    }
    errdefer {
        if (watchers.delete(fd) == null) {
            unreachable;
        }
    }

    const watcher_callback: CallbackManager.Callback = .{
        .func = &loop_watchers_callback,
        .cleanup = null,
        .data = .{
            .user_data = watcher_data_ptr
        }
        // .ZigGenericIO = .{
        //     .callback = &loop_watchers_callback,
        //     .data = watcher_data_ptr
        // }
    };

    const blocking_task_id = try loop_data.io.queue_unlocked(
        switch (operation) {
            .WaitReadable => Loop.Scheduling.IO.BlockingOperationData{
                .WaitReadable = .{
                    .fd = fd,
                    .callback = watcher_callback
                },
            },
            .WaitWritable => Loop.Scheduling.IO.BlockingOperationData{
                .WaitWritable = .{
                    .fd = fd,
                    .callback = watcher_callback
                },
            },
            else => {
                python_c.raise_python_runtime_error("Invalid operation type for watcher\x00");
                return error.PythonError;
            }
        }
    );

    watcher_data_ptr.blocking_task_id = blocking_task_id;
    return python_c.get_py_none();
}

pub fn loop_add_reader(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize
) callconv(.c) ?PyObject {
    return utils.execute_zig_function(z_loop_add_watcher, .{
        self.?, args.?[0..@as(usize, @intCast(nargs))],
        Loop.Scheduling.IO.BlockingOperation.WaitReadable
    });
}

pub fn loop_add_writer(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize
) callconv(.c) ?PyObject {
    return utils.execute_zig_function(z_loop_add_watcher, .{
        self.?, args.?[0..@as(usize, @intCast(nargs))],
        Loop.Scheduling.IO.BlockingOperation.WaitWritable
    });
}

inline fn z_loop_remove_watcher(
    self: *LoopObject, py_fd: PyObject,
    operation: Loop.Scheduling.IO.BlockingOperation
) !PyObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (!python_c.long_check(py_fd)) {
        python_c.raise_python_runtime_error("Invalid file descriptor\x00");
        return error.PythonError;
    }

    const fd_val = python_c.PyLong_AsLong(py_fd);
    if (python_c.PyErr_Occurred() != null) return error.PythonError;
    const fd: std.posix.fd_t = @intCast(fd_val);
    if (fd < 0) {
        python_c.raise_python_value_error("Invalid file descriptor\x00");
        return error.PythonError;
    }

    const loop_data = utils.get_data_ptr(Loop, self);
    const mutex = &loop_data.mutex;
    mutex.lock();
    defer mutex.unlock();

    if (!loop_data.initialized) {
        python_c.raise_python_runtime_error("Loop is closed\x00");
        return error.PythonError;
    }

    const watchers = switch (operation) {
        .WaitWritable => &loop_data.writer_watchers,
        .WaitReadable => &loop_data.reader_watchers,
        else => {
            python_c.raise_python_runtime_error("Invalid operation type for watcher\x00");
            return error.PythonError;
        }
    };

    const existing_watcher_ptr: ?*Loop.FDWatcher = watchers.delete(fd);
    if (existing_watcher_ptr) |existing_watcher_data| {
        const blocking_task_id = existing_watcher_data.blocking_task_id;
        existing_watcher_data.fd = -1;

        if (blocking_task_id == 0) {
            // Watcher is currently waiting in the Python Soon queue.
            // We just set fd = -1, and the wrapper callback when executed will clean it up.
            return python_c.get_py_true();
        }

        _ = try loop_data.io.queue_unlocked(
            .{
                .Cancel = blocking_task_id
            }
        );

        return python_c.get_py_true();
    }

    return python_c.get_py_false();
}

pub fn loop_remove_reader(
    self: ?*LoopObject, py_fd: ?PyObject
) callconv(.c) ?PyObject {
    return utils.execute_zig_function(z_loop_remove_watcher, .{
        self.?, py_fd.?, Loop.Scheduling.IO.BlockingOperation.WaitReadable
    });
}

pub fn loop_remove_writer(
    self: ?*LoopObject, py_fd: ?PyObject
) callconv(.c) ?PyObject {
    return utils.execute_zig_function(z_loop_remove_watcher, .{
        self.?, py_fd.?, Loop.Scheduling.IO.BlockingOperation.WaitWritable
    });
}
