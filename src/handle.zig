const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const CallbackManager = @import("callback_manager");
const Loop = @import("loop/main.zig");
const utils = @import("utils");

pub const PythonHandleObject = extern struct {
    ob_base: python_c.PyObject,

    contextvars: ?PyObject,
    loop_data: ?*Loop,

    py_callback: ?PyObject,
    py_callback_args: ?[*]PyObject,
    py_callback_len: usize,

    blocking_task_id: usize,
    cancelled: bool,
    finished: bool,
    thread_safe: bool,
    python_payload: CallbackManager.PythonPayload = .{},
};

pub const ExceptionMessage: [:0]const u8 = "An error ocurred while executing python callback";
pub const ModuleName: [:0]const u8 = "handle";

pub fn release_python_generic_callback(ptr: ?*anyopaque) void {
    const handle: *PythonHandleObject = @alignCast(@ptrCast(ptr.?));

    python_c.py_decref(@ptrCast(handle));
}

pub fn callback_for_python_generic_callbacks(data: *const CallbackManager.CallbackData) !void {
    const handle: *PythonHandleObject = @alignCast(@ptrCast(data.user_data.?));
    const thread_safe = handle.thread_safe;
    if (thread_safe) {
        @atomicStore(bool, &handle.finished, true, .release);
    }else{
        handle.finished = true;
    }

    var cancelled: bool = data.cancelled();
    if (!cancelled) {
        // BUG-31: Use a CAS to atomically claim the right to proceed
        // (or skip). Pairs with the CAS in `fast_handle_cancel`. The
        // first to win the CAS gets to act; the second sees
        // `cancelled=true` and skips. This closes the TOCTOU race
        // between the cancel setting `cancelled=true` and the callback
        // reading it.
        if (thread_safe) {
            const cmpxchg = @cmpxchgStrong(bool, &handle.cancelled, false, true, .acq_rel, .acquire);
            cancelled = cmpxchg != null;
        }else{
            if (handle.cancelled) {
                cancelled = true;
            } else {
                handle.cancelled = true;
            }
        }
    }

    if (cancelled) {
        python_c.py_decref(@ptrCast(handle));
        return;
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
    }else{
        result = python_c.PyObject_CallNoArgs(handle.py_callback.?);
    }

    if (result) |res| {
        python_c.py_decref(res);
        success = true;
    } else {
        return error.PythonError;
    }
}

pub inline fn fast_new_handle(
    contextvars: PyObject, loop_data: *Loop, py_callback: PyObject, args: ?[]PyObject,
    thread_safe: bool
) !*PythonHandleObject {
    const instance: *PythonHandleObject = @ptrCast(
        PythonHandleType.tp_alloc.?(&PythonHandleType, 0) orelse return error.PythonError
    );

    instance.contextvars = contextvars;
    instance.loop_data = loop_data;
    instance.py_callback = py_callback;

    if (args) |v| {
        instance.py_callback_args = v.ptr;
        instance.py_callback_len = v.len;
    }

    instance.blocking_task_id = 0;
    instance.cancelled = false;
    instance.finished = false;
    instance.thread_safe = thread_safe;
    instance.python_payload = .{
        .module_ptr = @ptrCast(utils.get_parent_ptr(Loop.Python.LoopObject, loop_data)),
        .callback_ptr = py_callback,
        .traverse = &traverse_python_generic_callback,
    };

    return instance;
}

pub fn traverse_python_generic_callback(ptr: ?*anyopaque, visit_ptr: ?*anyopaque, arg: ?*anyopaque) c_int {
    const handle: *PythonHandleObject = @alignCast(@ptrCast(ptr.?));
    const visit: python_c.visitproc = @ptrCast(visit_ptr.?);
    return visit.?(@ptrCast(handle), arg);
}

fn handle_traverse(self: ?*PythonHandleObject, visit: python_c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
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

fn handle_clear(self: ?*PythonHandleObject) callconv(.c) c_int {
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

fn handle_dealloc(self: ?*PythonHandleObject) callconv(.c) void {
    const instance = self.?;
    python_c.PyObject_GC_UnTrack(instance);

    _ = handle_clear(instance);

    const @"type" = python_c.get_type(@ptrCast(instance)) orelse return;
    @"type".tp_free.?(@ptrCast(instance));
}

inline fn z_handle_init(
    self: *PythonHandleObject, args: ?PyObject, kwargs: ?PyObject
) !c_int {
    var kwlist: [2][*c]u8 = undefined;
    kwlist[0] = @constCast("context\x00");
    kwlist[1] = null;

    var py_context: ?PyObject = null;

    if (python_c.PyArg_ParseTupleAndKeywords(
            args, kwargs, "O\x00", @ptrCast(&kwlist), &py_context
    ) < 0) {
        return error.PythonError;
    }
    
    if (py_context) |ctx| {
        if (python_c.is_none(ctx)) {
            python_c.raise_python_type_error("context cannot be None\x00");
            return error.PythonError;
        }
    }

    self.contextvars = python_c.py_newref(py_context.?);
    self.cancelled = false;
    self.thread_safe = false;

    return 0;
}

fn handle_init(self: ?*PythonHandleObject, args: ?PyObject, kwargs: ?PyObject) callconv(.c) c_int {
    return utils.execute_zig_function(z_handle_init, .{self.?, args, kwargs});
}

fn handle_get_context(self: ?*PythonHandleObject, _: ?PyObject) callconv(.c) ?PyObject {
    return python_c.py_newref(self.?.contextvars.?);
}

pub inline fn fast_handle_cancel(self: *PythonHandleObject) !void {
    const thread_safe = self.thread_safe;
    const finished = switch (thread_safe) {
        false => self.finished,
        true => @atomicLoad(bool, &self.finished, .acquire)
    };
    if (finished) {
        return;
    }

    // BUG-31: The previous check-then-act pattern had a TOCTOU race: we
    // read `cancelled` here, and if it was false, we'd queue the cancel
    // and set `cancelled=true` later. But between the read and the
    // store, the callback could start executing on the loop's main
    // thread, read `cancelled=false`, and proceed with the work — the
    // cancel then set `cancelled=true` too late.
    //
    // The fix: claim the cancellation atomically with a CAS. The
    // callback also uses a CAS to claim the right to proceed (see
    // `callback_for_python_generic_callbacks`). The first to win the
    // CAS gets to act; the second sees `cancelled=true` and skips.
    // This ensures mutual exclusion without holding the io_uring lock
    // for the duration of the callback, which would be expensive.
    if (thread_safe) {
        const cmpxchg = @cmpxchgStrong(bool, &self.cancelled, false, true, .acq_rel, .acquire);
        if (cmpxchg != null) {
            // Already cancelled or already finished — nothing to do.
            return;
        }
    } else {
        if (self.cancelled) return;
        self.cancelled = true;
    }

    const blocking_task_id = self.blocking_task_id;
    if (blocking_task_id > 0) {
        const loop_data = self.loop_data.?;

        const mutex = &loop_data.mutex;
        mutex.lock();
        defer mutex.unlock();

        _ = try loop_data.io.queue_unlocked(.{
            .Cancel = blocking_task_id
        });
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
    const cancelled = switch (instance.thread_safe) {
        false => instance.cancelled,
        true => @atomicLoad(bool, &instance.cancelled, .acquire)
    };

    return python_c.PyBool_FromLong(@intCast(@intFromBool(cancelled)));
}

const PythonhandleMethods: []const python_c.PyMethodDef = &[_]python_c.PyMethodDef{
    python_c.PyMethodDef{
        .ml_name = "cancel\x00",
        .ml_meth = @ptrCast(&handle_cancel),
        .ml_doc = "Cancel the callback. If the callback has already been canceled or executed, this method has no effect.\x00",
        .ml_flags = python_c.METH_NOARGS
    },
    python_c.PyMethodDef{
        .ml_name = "cancelled\x00",
        .ml_meth = @ptrCast(&handle_cancelled),
        .ml_doc = "Return True if the callback was cancelled.\x00",
        .ml_flags = python_c.METH_NOARGS
    },
    python_c.PyMethodDef{
        .ml_name = "get_context\x00",
        .ml_meth = @ptrCast(&handle_get_context),
        .ml_doc = "Return the contextvars.Context object associated with the handle.\x00",
        .ml_flags = python_c.METH_NOARGS
    },
    python_c.PyMethodDef{
        .ml_name = null, .ml_meth = null, .ml_doc = null, .ml_flags = 0
    }
};

pub var PythonHandleType = python_c.PyTypeObject{
    .tp_name = "talyn.Handle\x00",
    .tp_doc = "Talyn's handle class\x00",
    .tp_basicsize = @sizeOf(PythonHandleObject),
    .tp_itemsize = 0,
    .tp_flags = python_c.Py_TPFLAGS_DEFAULT | python_c.Py_TPFLAGS_BASETYPE | python_c.Py_TPFLAGS_HAVE_GC,
    .tp_new = &python_c.PyType_GenericNew,
    .tp_init = @ptrCast(&handle_init),
    .tp_dealloc = @ptrCast(&handle_dealloc),
    .tp_traverse = @ptrCast(&handle_traverse),
    .tp_clear = @ptrCast(&handle_clear),
    .tp_methods = @constCast(PythonhandleMethods.ptr),
    .tp_members = null
};

