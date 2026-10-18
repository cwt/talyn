const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const CallbackManager = @import("callback_manager");
const Loop = @import("loop/main.zig");
const utils = @import("utils");

pub const STATE_PENDING: u8 = 0;
pub const STATE_EXECUTED: u8 = 1;
pub const STATE_CANCELLED: u8 = 2;

pub const PythonHandleObject = extern struct {
    ob_base: python_c.PyObject,

    contextvars: ?PyObject,
    loop_data: ?*Loop,

    py_callback: ?PyObject,
    py_callback_args: ?[*]PyObject,
    py_callback_len: usize,

    blocking_task_id: usize,
    state: u8,
    thread_safe: bool,
    python_payload: CallbackManager.PythonPayload = .{},
};

pub const ExceptionMessage: [:0]const u8 = "An error ocurred while executing python callback";
pub const ModuleName: [:0]const u8 = "handle";

pub fn release_python_generic_callback(ptr: ?*anyopaque) void {
    const handle: *PythonHandleObject = @ptrCast(@alignCast(ptr.?));

    python_c.py_decref(@ptrCast(handle));
}

pub fn callback_for_python_generic_callbacks(data: *const CallbackManager.CallbackData) !void {
    const handle: *PythonHandleObject = @ptrCast(@alignCast(data.user_data.?));
    const thread_safe = handle.thread_safe;

    if (thread_safe) {
        if (data.cancelled()) {
            _ = @cmpxchgStrong(u8, &handle.state, STATE_PENDING, STATE_CANCELLED, .acq_rel, .acquire);
            python_c.py_decref(@ptrCast(handle));
            return;
        }

        // BUG-31 & BUG-345: Atomically claim the right to execute.
        // If state was STATE_PENDING, transition to STATE_EXECUTED.
        // If fast_handle_cancel won earlier, state is STATE_CANCELLED and CAS fails.
        const cmpxchg = @cmpxchgStrong(u8, &handle.state, STATE_PENDING, STATE_EXECUTED, .acq_rel, .acquire);
        if (cmpxchg != null) {
            python_c.py_decref(@ptrCast(handle));
            return;
        }

        // BUG-336: this timer fired — drop the stale ID before any Python runs so
        // a later cancel() cannot CancelTimer the new occupant.
        @atomicStore(usize, &handle.blocking_task_id, 0, .release);
    } else {
        if (data.cancelled() or handle.state == STATE_CANCELLED) {
            python_c.py_decref(@ptrCast(handle));
            return;
        }

        handle.state = STATE_EXECUTED;
        handle.blocking_task_id = 0;
    }

    const py_context = handle.contextvars.?;
    if (python_c.PyContext_Enter(py_context) < 0) {
        return error.PythonError;
    }
    var success = false;
    defer {
        if (success) {
            python_c.py_decref(@ptrCast(handle));
        }
    }
    defer _ = python_c.PyContext_Exit(py_context);

    var result: ?PyObject = null;
    if (handle.py_callback_args) |args_ptr| {
        const args_len = handle.py_callback_len;
        const args_tuple = python_c.PyTuple_New(@intCast(args_len)) orelse return error.PythonError;
        defer python_c.py_decref(args_tuple);

        for (0..args_len) |i| {
            const item = python_c.py_newref(args_ptr[i]);
            if (python_c.PyTuple_SetItem(args_tuple, @intCast(i), item) != 0) {
                python_c.py_decref(item);
                return error.PythonError;
            }
        }

        result = python_c.PyObject_Call(handle.py_callback.?, args_tuple, null);
    } else {
        result = python_c.PyObject_CallNoArgs(handle.py_callback.?);
    }

    if (result) |res| {
        python_c.py_decref(res);
        success = true;
    } else {
        return error.PythonError;
    }
}

pub inline fn fast_new_handle(contextvars: PyObject, loop_data: *Loop, py_callback: PyObject, args: ?[]PyObject, thread_safe: bool) !*PythonHandleObject {
    const instance: *PythonHandleObject = @ptrCast(PythonHandleType.tp_alloc.?(&PythonHandleType, 0) orelse return error.PythonError);

    instance.contextvars = contextvars;
    instance.loop_data = loop_data;
    instance.py_callback = py_callback;

    if (args) |v| {
        instance.py_callback_args = v.ptr;
        instance.py_callback_len = v.len;
    } else {
        instance.py_callback_args = null;
        instance.py_callback_len = 0;
    }

    instance.blocking_task_id = 0;
    instance.state = STATE_PENDING;
    instance.thread_safe = thread_safe;
    instance.python_payload = .{
        .module_ptr = @ptrCast(utils.get_parent_ptr(Loop.Python.LoopObject, loop_data)),
        .callback_ptr = py_callback,
        .traverse = &traverse_python_generic_callback,
    };

    return instance;
}

pub fn traverse_python_generic_callback(ptr: ?*anyopaque, visit_ptr: ?*anyopaque, arg: ?*anyopaque) c_int {
    const handle: *PythonHandleObject = @ptrCast(@alignCast(ptr.?));
    const visit: python_c.visitproc = @ptrCast(@alignCast(visit_ptr.?));
    return visit.?(@ptrCast(handle), arg);
}

pub fn handle_traverse(self: ?*PythonHandleObject, visit: python_c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    const instance = self.?;

    const vret = python_c.py_visit(instance, visit, arg);
    if (vret != 0) return vret;

    if (instance.py_callback_args) |args_ptr| {
        for (args_ptr[0..instance.py_callback_len]) |arg_item| {
            const vret2 = visit.?(arg_item, arg);
            if (vret2 != 0) return vret2;
        }
    }

    return 0;
}

pub fn handle_clear(self: ?*PythonHandleObject) callconv(.c) c_int {
    const instance = self.?;
    python_c.py_decref_and_set_null(&instance.contextvars);
    python_c.py_decref_and_set_null(&instance.py_callback);

    const args_len = instance.py_callback_len;
    if (instance.py_callback_args) |args_ptr| {
        // Nullify fields first to prevent any potential re-entry or double-free during decref/free
        instance.py_callback_args = null;
        instance.py_callback_len = 0;

        const allocator = utils.gpa.allocator();
        const args = args_ptr[0..args_len];
        for (args) |arg| python_c.py_decref(arg);
        allocator.free(args);
    }
    return 0;
}

pub fn handle_dealloc(self: ?*PythonHandleObject) callconv(.c) void {
    const instance = self.?;
    python_c.PyObject_GC_UnTrack(instance);

    _ = handle_clear(instance);

    const @"type" = python_c.get_type(@ptrCast(instance)) orelse return;
    @"type".tp_free.?(@ptrCast(instance));
}

inline fn z_handle_init(self: *PythonHandleObject, args: ?PyObject, kwargs: ?PyObject) !c_int {
    var kwlist: [2][*c]u8 = undefined;
    kwlist[0] = @constCast("context\x00");
    kwlist[1] = null;

    var py_context: ?PyObject = null;

    if (python_c.PyArg_ParseTupleAndKeywords(args, kwargs, "O\x00", @ptrCast(&kwlist), &py_context) < 0) {
        return error.PythonError;
    }

    if (py_context) |ctx| {
        if (python_c.is_none(ctx)) {
            python_c.raise_python_type_error("context cannot be None\x00");
            return error.PythonError;
        }
    }

    self.contextvars = python_c.py_newref(py_context.?);
    self.state = STATE_PENDING;
    self.thread_safe = false;

    return 0;
}

fn handle_init(self: ?*PythonHandleObject, args: ?PyObject, kwargs: ?PyObject) callconv(.c) c_int {
    return utils.execute_zig_function(z_handle_init, .{ self.?, args, kwargs });
}

fn handle_get_context(self: ?*PythonHandleObject, _: ?PyObject) callconv(.c) ?PyObject {
    return python_c.py_newref(self.?.contextvars.?);
}

pub inline fn fast_handle_cancel(self: *PythonHandleObject) !void {
    const thread_safe = self.thread_safe;
    if (thread_safe) {
        // BUG-31 & BUG-345: Atomically claim cancellation.
        // If state was STATE_PENDING, transition to STATE_CANCELLED.
        // If it was already STATE_EXECUTED or STATE_CANCELLED, cmpxchg fails and cancel has no effect.
        const cmpxchg = @cmpxchgStrong(u8, &self.state, STATE_PENDING, STATE_CANCELLED, .acq_rel, .acquire);
        if (cmpxchg != null) {
            return;
        }
    } else {
        if (self.state != STATE_PENDING) return;
        self.state = STATE_CANCELLED;
    }

    // BUG-336: acquire the ID with the same visibility
    const blocking_task_id = switch (thread_safe) {
        false => self.blocking_task_id,
        true => @atomicLoad(usize, &self.blocking_task_id, .acquire),
    };
    if (blocking_task_id > 0) {
        const loop_data = self.loop_data.?;

        const mutex = &loop_data.mutex;
        mutex.lock();
        defer mutex.unlock();

        _ = try loop_data.io.queue_unlocked(.{ .CancelTimer = blocking_task_id });
    }
}

fn handle_cancel(self: ?*PythonHandleObject, _: ?PyObject) callconv(.c) ?PyObject {
    fast_handle_cancel(self.?) catch |err| {
        return utils.handle_zig_function_error(err, null);
    };

    return python_c.get_py_none();
}

fn handle_cancelled(self: ?*PythonHandleObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    const state = switch (instance.thread_safe) {
        false => instance.state,
        true => @atomicLoad(u8, &instance.state, .acquire),
    };

    return python_c.PyBool_FromLong(@intCast(@intFromBool(state == STATE_CANCELLED)));
}

const PythonhandleMethods: []const python_c.PyMethodDef = &[_]python_c.PyMethodDef{ python_c.PyMethodDef{ .ml_name = "cancel\x00", .ml_meth = @ptrCast(&handle_cancel), .ml_doc = "Cancel the callback. If the callback has already been canceled or executed, this method has no effect.\x00", .ml_flags = python_c.METH_NOARGS }, python_c.PyMethodDef{ .ml_name = "cancelled\x00", .ml_meth = @ptrCast(&handle_cancelled), .ml_doc = "Return True if the callback was cancelled.\x00", .ml_flags = python_c.METH_NOARGS }, python_c.PyMethodDef{ .ml_name = "get_context\x00", .ml_meth = @ptrCast(&handle_get_context), .ml_doc = "Return the contextvars.Context object associated with the handle.\x00", .ml_flags = python_c.METH_NOARGS }, python_c.PyMethodDef{ .ml_name = null, .ml_meth = null, .ml_doc = null, .ml_flags = 0 } };

pub var PythonHandleType = python_c.PyTypeObject{ .tp_name = "talyn.Handle\x00", .tp_doc = "Talyn's handle class\x00", .tp_basicsize = @sizeOf(PythonHandleObject), .tp_itemsize = 0, .tp_flags = python_c.Py_TPFLAGS_DEFAULT | python_c.Py_TPFLAGS_BASETYPE | python_c.Py_TPFLAGS_HAVE_GC, .tp_new = &python_c.PyType_GenericNew, .tp_init = @ptrCast(&handle_init), .tp_dealloc = @ptrCast(&handle_dealloc), .tp_traverse = @ptrCast(&handle_traverse), .tp_clear = @ptrCast(&handle_clear), .tp_methods = @constCast(PythonhandleMethods.ptr), .tp_members = null };
