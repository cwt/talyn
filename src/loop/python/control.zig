const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");
const CallbackManager = @import("callback_manager");

const Loop = @import("../main.zig");
const LoopObject = Loop.Python.LoopObject;

const Hooks = @import("hooks.zig");

inline fn z_loop_run_forever(self: *LoopObject) !PyObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    const loop_data = utils.get_data_ptr(Loop, self);

    try Hooks.setup_asyncgen_hooks(self);

    const set_running_loop = utils.PythonImports.set_running_loop;
    if (python_c.PyObject_CallOneArg(set_running_loop, @ptrCast(self))) |v| {
        python_c.py_decref(v);
    }else{
        const exc = python_c.PyErr_GetRaisedException();
        Hooks.cleanup_asyncgen_hooks(self);
        python_c.PyErr_SetRaisedException(exc);
        return error.PythonError;
    }

    var py_exception: ?PyObject = null;
    Loop.Runner.start(loop_data, self) catch |err| {
        utils.handle_zig_function_error(err, {});
        py_exception = python_c.PyErr_GetRaisedException() orelse return error.PythonError;
    };

    if (python_c.PyObject_CallOneArg(set_running_loop, python_c.get_py_none_without_incref())) |v| {
        python_c.py_decref(v);
    }else{
        const py_exc = python_c.PyErr_GetRaisedException() orelse return error.PythonError;
        if (py_exception) |v| {
            python_c.PyException_SetCause(py_exc, v);
        }

        py_exception = py_exc;
    }

    Hooks.cleanup_asyncgen_hooks(self);
    if (py_exception) |v| {
        python_c.PyErr_SetRaisedException(v);
        return error.PythonError;
    }

    return python_c.get_py_none();
}

pub fn loop_run_forever(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    return utils.execute_zig_function(z_loop_run_forever, .{self.?});
}

pub fn loop_stop(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    if (Loop.Python.check_forked(self.?)) return null;
    const loop_data = utils.get_data_ptr(Loop, self.?);

    const mutex = &loop_data.mutex;
    mutex.lock();
    defer mutex.unlock();

    loop_data.stopping = true;
    return python_c.get_py_none();
}

pub fn loop_is_running(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    if (Loop.Python.check_forked(self.?)) return null;
    const loop_data = utils.get_data_ptr(Loop, self.?);
    const mutex = &loop_data.mutex;
    mutex.lock();
    defer mutex.unlock();

    return python_c.PyBool_FromLong(@intCast(@intFromBool(loop_data.running)));
}

pub fn loop_is_closed(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    if (Loop.Python.check_forked(self.?)) return null;
    const loop_data = utils.get_data_ptr(Loop, self.?);

    const mutex = &loop_data.mutex;
    mutex.lock();
    defer mutex.unlock();

    return python_c.PyBool_FromLong(@intCast(@intFromBool(!loop_data.initialized)));
}

pub fn loop_get_debug(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    return python_c.PyBool_FromLong(@intCast(@intFromBool(self.?.debug)));
}

pub fn loop_set_debug(self: ?*LoopObject, enabled: ?PyObject) callconv(.c) ?PyObject {
    self.?.debug = (python_c.PyObject_IsTrue(enabled.?) != 0);
    return python_c.get_py_none();
}

pub fn loop_get_task_factory(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    if (self.?.task_factory) |tf| return python_c.py_newref(tf);
    return python_c.get_py_none();
}

pub fn loop_set_task_factory(self: ?*LoopObject, factory: ?PyObject) callconv(.c) ?PyObject {
    if (factory) |f| {
        if (!python_c.is_none(f) and python_c.PyCallable_Check(f) == 0) {
            python_c.raise_python_type_error("task factory must be a callable or None\x00");
            return null;
        }
    }
    python_c.py_xdecref(self.?.task_factory);
    if (factory) |f| {
        if (python_c.is_none(f)) {
            self.?.task_factory = null;
        } else {
            self.?.task_factory = python_c.py_newref(f);
        }
    } else {
        self.?.task_factory = null;
    }
    return python_c.get_py_none();
}

const HookHandle = extern struct {
    ob_base: python_c.PyObject,
    loop_data: *Loop,
    hook_type: c_int,
    node: Loop.HooksList.Node,
    callback: PyObject,
};

fn hook_handle_dealloc(self: ?*HookHandle) callconv(.c) void {
    const instance = self.?;
    python_c.py_decref(instance.callback);
    const @"type": *python_c.PyTypeObject = python_c.get_type(@ptrCast(instance));
    @"type".tp_free.?(@ptrCast(instance));
}

fn hook_handle_cancel(self: ?*HookHandle, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    const hook_type: Loop.HookType = @enumFromInt(instance.hook_type);
    instance.loop_data.remove_hook(hook_type, instance.node);
    return python_c.get_py_none();
}

const HookHandleMethods = [_]python_c.PyMethodDef{
    .{ .ml_name = "cancel\x00", .ml_meth = @ptrCast(&hook_handle_cancel), .ml_flags = python_c.METH_NOARGS, .ml_doc = "Cancel the hook\x00" },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null }
};

var HookHandleType = python_c.PyTypeObject{
    .tp_name = "leviathan._HookHandle\x00",
    .tp_basicsize = @sizeOf(HookHandle),
    .tp_flags = python_c.Py_TPFLAGS_DEFAULT,
    .tp_dealloc = @ptrCast(&hook_handle_dealloc),
    .tp_methods = @constCast(&HookHandleMethods),
};

fn hook_callback(data: *const CallbackManager.CallbackData) !void {
    const handle: *HookHandle = @alignCast(@ptrCast(data.user_data.?));
    const ret = python_c.PyObject_CallNoArgs(handle.callback) orelse return error.PythonError;
    python_c.py_decref(ret);
}

pub fn loop_add_hook(self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t) callconv(.c) ?PyObject {
    return utils.execute_zig_function(z_loop_add_hook, .{ self.?, args.?[0..@as(usize, @intCast(nargs))] });
}

fn z_loop_add_hook(self: *LoopObject, args: []const ?PyObject) !PyObject {
    if (args.len < 2) return error.PythonError;
    const hook_type_int: c_int = @intCast(python_c.PyLong_AsLong(args[0].?));
    const py_callback = args[1].?;

    const hook_type: Loop.HookType = switch (hook_type_int) {
        0 => .prepare,
        1 => .check,
        2 => .idle,
        else => return error.PythonError,
    };

    if (python_c.PyType_Ready(&HookHandleType) < 0) return error.PythonError;
    const handle: *HookHandle = @ptrCast(HookHandleType.tp_alloc.?(&HookHandleType, 0) orelse return error.PythonError);
    handle.loop_data = utils.get_data_ptr(Loop, self);
    handle.hook_type = hook_type_int;
    handle.callback = python_c.py_newref(py_callback);

    handle.node = try handle.loop_data.add_hook(hook_type, .{
        .func = &hook_callback,
        .cleanup = null,
        .data = .{ .user_data = handle },
    });

    return @ptrCast(handle);
}

const PathWatcherHandle = extern struct {
    ob_base: python_c.PyObject,
    loop_data: *Loop,
    wd: i32,
    callback: PyObject,
};

fn path_watcher_handle_dealloc(self: ?*PathWatcherHandle) callconv(.c) void {
    const instance = self.?;
    python_c.py_decref(instance.callback);
    const @"type": *python_c.PyTypeObject = python_c.get_type(@ptrCast(instance));
    @"type".tp_free.?(@ptrCast(instance));
}

fn path_watcher_handle_cancel(self: ?*PathWatcherHandle, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    if (instance.loop_data.initialized) {
        instance.loop_data.fs_watcher.remove_watch(instance.wd, instance.callback);
    }
    return python_c.get_py_none();
}

const PathWatcherHandleMethods = [_]python_c.PyMethodDef{
    .{ .ml_name = "cancel\x00", .ml_meth = @ptrCast(&path_watcher_handle_cancel), .ml_flags = python_c.METH_NOARGS, .ml_doc = "Cancel the path watcher\x00" },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null }
};

var PathWatcherHandleType = python_c.PyTypeObject{
    .tp_name = "leviathan._PathWatcherHandle\x00",
    .tp_basicsize = @sizeOf(PathWatcherHandle),
    .tp_flags = python_c.Py_TPFLAGS_DEFAULT,
    .tp_dealloc = @ptrCast(&path_watcher_handle_dealloc),
    .tp_methods = @constCast(&PathWatcherHandleMethods),
};

pub fn loop_add_path_watcher(self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t) callconv(.c) ?PyObject {
    return utils.execute_zig_function(z_loop_add_path_watcher, .{ self.?, args.?[0..@as(usize, @intCast(nargs))] });
}

fn z_loop_add_path_watcher(self: *LoopObject, args: []const ?PyObject) !PyObject {
    if (args.len < 3) return error.PythonError;
    const py_path = args[0].?;
    const py_mask = args[1].?;
    const py_callback = args[2].?;

    const mask: u32 = @intCast(python_c.PyLong_AsUnsignedLong(py_mask));
    
    var path_buf: [4096]u8 = undefined;
    const path_len = python_c.PyUnicode_AsUTF8AndSize(py_path, null);
    if (path_len < 0) return error.PythonError;
    const path_str = python_c.PyUnicode_AsUTF8(py_path) orelse return error.PythonError;
    
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{std.mem.span(path_str)});

    const loop_data = utils.get_data_ptr(Loop, self);
    const wd = try loop_data.fs_watcher.add_watch(path_z, mask, py_callback);

    if (python_c.PyType_Ready(&PathWatcherHandleType) < 0) return error.PythonError;
    const handle: *PathWatcherHandle = @ptrCast(PathWatcherHandleType.tp_alloc.?(&PathWatcherHandleType, 0) orelse return error.PythonError);
    handle.loop_data = loop_data;
    handle.wd = wd;
    handle.callback = python_c.py_newref(py_callback);

    return @ptrCast(handle);
}

pub fn loop_add_child_handler(self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t) callconv(.c) ?PyObject {
    return utils.execute_zig_function(z_loop_add_child_handler, .{ self.?, args.?[0..@as(usize, @intCast(nargs))] });
}

fn z_loop_add_child_handler(self: *LoopObject, args: []const ?PyObject) !PyObject {
    if (args.len < 2) return error.PythonError;
    const pid: i32 = @intCast(python_c.PyLong_AsLong(args[0].?));
    const py_callback = args[1].?;

    const loop_data = utils.get_data_ptr(Loop, self);
    try loop_data.child_watcher.add_child_handler(pid, py_callback);

    return python_c.get_py_none();
}

pub fn loop_remove_child_handler(self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t) callconv(.c) ?PyObject {
    return utils.execute_zig_function(z_loop_remove_child_handler, .{ self.?, args.?[0..@as(usize, @intCast(nargs))] });
}

fn z_loop_remove_child_handler(self: *LoopObject, args: []const ?PyObject) !PyObject {
    if (args.len < 1) return error.PythonError;
    const pid: i32 = @intCast(python_c.PyLong_AsLong(args[0].?));

    const loop_data = utils.get_data_ptr(Loop, self);
    const removed = loop_data.child_watcher.remove_child_handler(pid);

    return python_c.PyBool_FromLong(@intCast(@intFromBool(removed)));
}

pub fn loop_test_lru(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    const loop_obj = self.?;
    const loop_data = utils.get_data_ptr(Loop, loop_obj);
    
    var cache = utils.LRUCache(u32, u32).init(loop_data.allocator, 2);
    defer cache.deinit();
    
    cache.put(1, 100) catch return null;
    cache.put(2, 200) catch return null;
    if (cache.get(1) != 100) return null;
    cache.put(3, 300) catch return null;
    if (cache.get(2) != null) return null;
    if (cache.get(3) != 300) return null;
    
    return python_c.get_py_none();
}

pub fn loop_close(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    if (Loop.Python.check_forked(self.?)) return null;
    const instance = self.?;

    const loop_data = utils.get_data_ptr(Loop, instance);

    {
        const mutex = &loop_data.mutex;
        mutex.lock();
        defer mutex.unlock();

        if (loop_data.running) {
            python_c.raise_python_runtime_error("Loop is running\x00");
            return null;
        }
    }

    loop_data.release();
    return python_c.get_py_none();
}
