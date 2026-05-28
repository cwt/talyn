const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const CallbackManager = @import("callback_manager");
const Future = @import("../future/main.zig");
const Loop = @import("../loop/main.zig");
const Task = @import("main.zig");

const callbacks = @import("callbacks.zig");

const LoopObject = Loop.Python.LoopObject;
const PythonTaskObject = Task.PythonTaskObject;

inline fn task_set_initial_values(self: *PythonTaskObject) void {
    Future.Python.Constructors.future_set_initial_values(&self.fut);
    python_c.initialize_object_fields(self, &.{"fut"});
}

inline fn task_init_configuration(
    self: *PythonTaskObject, loop: *LoopObject,
    coro: PyObject, context: PyObject, name: ?PyObject
) !void {
    try Future.Python.Constructors.future_init_configuration(&self.fut, loop);
    const coro_type = python_c.get_type(coro) orelse return error.PythonError;
    if (coro_type.tp_as_async == null or coro_type.tp_as_async.*.am_await == null) {
        python_c.raise_python_type_error("Coro argument must be a coroutine\x00");
        return error.PythonError;
    }

    self.name = name;
    self.coro = coro;

    self.py_context = context;
}

inline fn task_schedule_coro(self: *PythonTaskObject, loop: *LoopObject) !void {
    if (loop.asyncio_tasks_set) |tasks_set| {
        if (python_c.PySet_Add(tasks_set, @ptrCast(self)) < 0) {
            return error.PythonError;
        }
    }

    const loop_data = utils.get_data_ptr(Loop, loop);
    const future_data = utils.get_data_ptr(Future, &self.fut);
    future_data.python_payload = .{
        .module_ptr = null,
        .callback_ptr = self.coro.?,
        .traverse = &python_c.traverse_pyobject_callback,
    };

    const callback = CallbackManager.Callback{
        .func = &callbacks.execute_task_send,
        .cleanup = &callbacks.cleanup_task,
        .data = CallbackManager.CallbackData.init_python(self, &future_data.python_payload),
    };

    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
    python_c.py_incref(@ptrCast(self));
}

pub inline fn fast_new_task(
    loop: *LoopObject, coro: PyObject,
    context: PyObject, name: ?PyObject
) !*PythonTaskObject {
    const instance: *PythonTaskObject = @ptrCast(
        Task.PythonTaskType.tp_alloc.?(&Task.PythonTaskType, 0) orelse return error.PythonError
    );
    task_set_initial_values(instance);
    errdefer python_c.py_decref(@ptrCast(instance));

    try task_init_configuration(instance, loop, coro, context, name);
    errdefer { instance.py_context = null; }

    try task_schedule_coro(instance, loop);

    return instance;
}

inline fn z_task_new(
    @"type": *python_c.PyTypeObject, _: ?PyObject,
    _: ?PyObject
) !*PythonTaskObject {
    const instance: *PythonTaskObject = @ptrCast(@"type".tp_alloc.?(@"type", 0) orelse return error.PythonError);
    task_set_initial_values(instance);
    return instance;
}

pub fn task_new(
    @"type": ?*python_c.PyTypeObject, args: ?PyObject,
    kwargs: ?PyObject
) callconv(.c) ?PyObject {
    const self = utils.execute_zig_function(
        z_task_new, .{@"type".?, args, kwargs}
    );
    return @ptrCast(self);
}

pub fn task_clear(self: ?*PythonTaskObject) callconv(.c) c_int {
    const py_task = self.?;
    const fut = &py_task.fut;

    if (py_task.weakref_list != null) {
        python_c.PyObject_ClearWeakRefs(@ptrCast(py_task));
        py_task.weakref_list = null;
    }

    const future_data = utils.get_data_ptr(Future, fut);
    if (!future_data.released) {
        const _result = future_data.result;
        if (_result) |res| {
            python_c.py_decref(@alignCast(@ptrCast(res)));
            future_data.result = null;
        }
        future_data.release();
    }

    python_c.deinitialize_object_fields(py_task, &.{"weakref_list"});
    return 0;
}

pub fn task_traverse(self: ?*PythonTaskObject, visit: python_c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    const instance = self.?;

    const vret = Future.Python.Constructors.future_traverse(&instance.fut, visit, arg);
    if (vret != 0) return vret;

    if (instance.py_context) |o| {
        const vret_c = visit.?(o, arg);
        if (vret_c != 0) return vret_c;
    }
    if (instance.name) |o| {
        const vret_n = visit.?(o, arg);
        if (vret_n != 0) return vret_n;
    }
    if (instance.coro) |o| {
        const vret_coro = visit.?(o, arg);
        if (vret_coro != 0) return vret_coro;
    }
    if (instance.wake_up_task_callback) |o| {
        const vret_w = visit.?(o, arg);
        if (vret_w != 0) return vret_w;
    }
    if (instance.fut_waiter) |o| {
        const vret_f = visit.?(o, arg);
        if (vret_f != 0) return vret_f;
    }
    if (instance.exception) |o| {
        const vret_e = visit.?(o, arg);
        if (vret_e != 0) return vret_e;
    }
    if (instance.weakref_list) |o| {
        const vret_weak = visit.?(o, arg);
        if (vret_weak != 0) return vret_weak;
    }

    return 0;
}

pub fn task_dealloc(self: ?*PythonTaskObject) callconv(.c) void {
    const instance = self.?;

    python_c.PyObject_GC_UnTrack(instance);
    _ = task_clear(instance);

    const @"type": *python_c.PyTypeObject = @ptrCast(python_c.Py_TYPE(@ptrCast(instance)) orelse return);
    @"type".tp_free.?(@ptrCast(instance));
}

inline fn z_task_init(
    self: *PythonTaskObject, args: ?PyObject, kwargs: ?PyObject
) !c_int {
    var kwlist: [5][*c]u8 = undefined;
    kwlist[0] = @constCast("coro\x00");
    kwlist[1] = @constCast("loop\x00");
    kwlist[2] = @constCast("name\x00");
    kwlist[3] = @constCast("context\x00");
    kwlist[4] = null;

    var coro: ?PyObject = null;
    var py_loop: ?PyObject = null;
    var name: ?PyObject = null;
    var context: ?PyObject = null;

    if (python_c.PyArg_ParseTupleAndKeywords(
            args, kwargs, "OO|$OO\x00", @ptrCast(&kwlist), &coro, &py_loop,
            &name, &context
        ) < 0) {
        return error.PythonError;
    }

    const talyn_loop: *LoopObject = @ptrCast(py_loop.?);
    if (!python_c.type_check(@ptrCast(talyn_loop), Loop.Python.LoopType)) {
        python_c.raise_python_type_error("Invalid asyncio event loop. Only Talyn's event loops are allowed\x00");
        return error.PythonError;
    }

    if (context) |py_ctx| {
        if (python_c.is_none(py_ctx)) {
            context = python_c.PyContext_CopyCurrent()
                orelse return error.PythonError;
        }else if (python_c.is_type(py_ctx, &python_c.PyContext_Type)) {
            python_c.py_incref(py_ctx);
        }else{
            python_c.raise_python_type_error("Invalid context\x00");
            return error.PythonError;
        }
    }else{
        context = python_c.PyContext_CopyCurrent() orelse return error.PythonError;
    }
    errdefer python_c.py_decref(context.?);

    if (name) |v| {
        if (python_c.is_none(v)) {
            python_c.py_decref_and_set_null(&name);
        }else if (!python_c.unicode_check(v)) {
            name = python_c.PyObject_Str(v) orelse return error.PythonError;
        }else{
            name = python_c.py_newref(v);
        }
    }
    errdefer python_c.py_xdecref(name);
    
    python_c.py_incref(coro.?);
    errdefer python_c.py_decref(coro.?);

    try task_init_configuration(self, talyn_loop, coro.?, context.?, name);
    errdefer { self.py_context = null; }

    try task_schedule_coro(self, talyn_loop);

    return 0;
}

pub fn task_init(
    self: ?*PythonTaskObject, args: ?PyObject, kwargs: ?PyObject
) callconv(.c) c_int {
    return utils.execute_zig_function(z_task_init, .{self.?, args, kwargs});
}
