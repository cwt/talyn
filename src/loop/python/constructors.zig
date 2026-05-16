const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const builtin = @import("builtin");

const utils = @import("utils");
const PythonImports = utils.PythonImports;

const Loop = @import("../main.zig");
const LoopObject = Loop.Python.LoopObject;

const std = @import("std");

inline fn z_loop_new(@"type": *python_c.PyTypeObject) !*LoopObject {
    const instance: *LoopObject = @ptrCast(@"type".tp_alloc.?(@"type", 0) orelse return error.PythonError);
    errdefer @"type".tp_free.?(instance);

    python_c.initialize_object_fields(
        instance, &.{
            "ob_base", "asyncgens_set",
            "asyncgens_set_add", "asyncgens_set_discard",
        }
    );

    const weakref_set_class = python_c.PyObject_GetAttrString(PythonImports.weakref_module, "WeakSet\x00")
        orelse return error.PythonError;
    defer python_c.py_decref(weakref_set_class);

    const weakref_set = python_c.PyObject_CallNoArgs(weakref_set_class)
        orelse return error.PythonError;
    errdefer python_c.py_decref(weakref_set);

    const weakref_add = python_c.PyObject_GetAttrString(weakref_set, "add\x00")
        orelse return error.PythonError;
    errdefer python_c.py_decref(weakref_add);

    const weakref_discard = python_c.PyObject_GetAttrString(weakref_set, "discard\x00")
        orelse return error.PythonError;
    errdefer python_c.py_decref(weakref_discard);

    instance.asyncgens_set = weakref_set;
    instance.asyncgens_set_add = weakref_add;
    instance.asyncgens_set_discard = weakref_discard;
    instance.owner_pid = std.os.linux.getpid();
    instance.owner_tid = python_c._c.PyThread_get_thread_ident();
    instance.debug = false;
    instance.slow_callback_duration = 0.1;
    instance.task_factory = null;

    return instance;
}

pub fn loop_new(
    @"type": ?*python_c.PyTypeObject, _: ?PyObject,
    _: ?PyObject
) callconv(.c) ?PyObject {
    const self = utils.execute_zig_function(
        z_loop_new, .{@"type".?}
    );
    return @ptrCast(self);
}

pub fn loop_clear(self: ?*LoopObject) callconv(.c) c_int {
    const py_loop = self.?;
    const loop_data = utils.get_data_ptr(Loop, py_loop);
    if (loop_data.initialized) {
        loop_data.release();
    }

    if (builtin.single_threaded) {
        python_c.deinitialize_object_fields(py_loop, &.{});
    }
    return 0;
}

pub fn loop_traverse(self: ?*LoopObject, visit: python_c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    const py_loop = self.?;
    const loop_data = utils.get_data_ptr(Loop, py_loop);

    // Visit standard fields
    const vret1 = python_c.py_visit(py_loop, visit, arg);
    if (vret1 != 0) return vret1;

    if (!loop_data.initialized) return 0;

    // Visit ready tasks queues
    for (loop_data.ready_tasks_queues) |*queue| {
        const vret_q = queue.traverse(visit, arg);
        if (vret_q != 0) return vret_q;
    }

    // Visit IO blocking tasks
    const vret_io = loop_data.io.traverse(visit, arg);
    if (vret_io != 0) return vret_io;

    // Visit watchers
    const vret_rw = traverse_btree(&loop_data.reader_watchers, visit, arg);
    if (vret_rw != 0) return vret_rw;

    const vret_ww = traverse_btree(&loop_data.writer_watchers, visit, arg);
    if (vret_ww != 0) return vret_ww;

    // Visit hooks
    const vret_ph = traverse_hooks(&loop_data.prepare_hooks, visit, arg);
    if (vret_ph != 0) return vret_ph;

    const vret_ch = traverse_hooks(&loop_data.check_hooks, visit, arg);
    if (vret_ch != 0) return vret_ch;

    const vret_ih = traverse_hooks(&loop_data.idle_hooks, visit, arg);
    if (vret_ih != 0) return vret_ih;

    // Visit DNS
    const vret_dns = loop_data.dns.traverse(visit, arg);
    if (vret_dns != 0) return vret_dns;
    
    // Visit FS Watcher
    const vret_fs = loop_data.fs_watcher.traverse(visit, arg);
    if (vret_fs != 0) return vret_fs;

    // Visit Child Watcher
    const vret_cw = loop_data.child_watcher.traverse(visit, arg);
    if (vret_cw != 0) return vret_cw;

    return 0;
}

fn traverse_btree(btree: anytype, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
    return traverse_btree_node(btree.parent, visit, arg);
}

fn traverse_btree_node(node: anytype, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
    const nkeys = node.nkeys;
    for (node.values[0..nkeys]) |watcher| {
        const vret = visit.?(@ptrCast(watcher.handle), arg);
        if (vret != 0) return vret;
    }
    for (node.childs[0 .. nkeys + 1]) |maybe_child| {
        if (maybe_child) |child| {
            const vret = traverse_btree_node(child, visit, arg);
            if (vret != 0) return vret;
        }
    }
    return 0;
}

fn traverse_hooks(hooks: *Loop.HooksList, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
    var node = hooks.first;
    while (node) |n| {
        const cb = n.data;
        if (cb.data.module_ptr) |mod| {
            const vret1 = visit.?(@ptrCast(mod), arg);
            if (vret1 != 0) return vret1;
            if (cb.data.callback_ptr) |cp| {
                const vret2 = visit.?(@ptrCast(cp), arg);
                if (vret2 != 0) return vret2;
            }
        }
        node = n.next;
    }
    return 0;
}

pub fn loop_dealloc(self: ?*LoopObject) callconv(.c) void {
    const instance = self.?;

    if (builtin.single_threaded) {
        python_c.PyObject_GC_UnTrack(instance);
    }
    _ = loop_clear(instance);

    const @"type": *python_c.PyTypeObject = python_c.get_type(@ptrCast(instance));
    @"type".tp_free.?(@ptrCast(instance));

    if (builtin.single_threaded) {
        python_c.py_decref(@ptrCast(@"type"));
    }
}

inline fn z_loop_init(
    self: *LoopObject, args: ?PyObject, kwargs: ?PyObject
) !c_int {
    var kwlist: [3][*c]u8 = undefined;
    kwlist[0] = @constCast("ready_tasks_queue_capacity\x00");
    kwlist[1] = @constCast("exception_handler\x00");
    kwlist[2] = null;

    var ready_tasks_queue_capacity: u64 = 0;
    var exception_handler: ?PyObject = null;

    if (python_c.PyArg_ParseTupleAndKeywords(
            args, kwargs, "KO\x00", @ptrCast(&kwlist), &ready_tasks_queue_capacity,
            &exception_handler
    ) < 0) {
        return error.PythonError;
    }

    if (python_c.PyCallable_Check(exception_handler.?) == 0) {
        python_c.raise_python_runtime_error("Invalid exception handler\x00");
        return error.PythonError;
    }

    self.exception_handler = python_c.py_newref(exception_handler.?);
    errdefer python_c.py_decref(exception_handler.?);

    const allocator = utils.gpa.allocator();
    const loop_data = utils.get_data_ptr(Loop, self);
    try loop_data.init(allocator, @intCast(ready_tasks_queue_capacity));

    self.asyncio_tasks_set = python_c.PyObject_GetAttrString(@ptrCast(self), "_asyncio_tasks\x00");
    python_c.PyErr_Clear();

    return 0;
}

pub fn loop_init(
    self: ?*LoopObject, args: ?PyObject, kwargs: ?PyObject
) callconv(.c) c_int {
    return utils.execute_zig_function(z_loop_init, .{self.?, args, kwargs});
}

