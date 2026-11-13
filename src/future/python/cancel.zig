const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const Future = @import("../main.zig");
const PythonFutureObject = Future.Python.FutureObject;

const utils = @import("utils");

pub inline fn future_fast_cancel(instance: *PythonFutureObject, data: *Future, cancel_msg_py_object: ?PyObject) !bool {
    // BUG-369: a never-armed or teardown-bound Future (created via tp_new
    // without init, or fences-released by Future.release) has no valid
    // callbacks queue scheduling state — re-entrant cancel() from a
    // finalizer during release() must be an inert no-op instead of
    // arming the guaranteed-dispatch machinery on the dying object.
    if (data.released) return false;

    switch (data.status) {
        .finished, .canceled => return false,
        .pending => {},
    }

    if (cancel_msg_py_object) |pyobj| {
        const new_msg = python_c.py_newref(pyobj);
        python_c.py_xdecref(instance.cancel_msg_py_object);
        instance.cancel_msg_py_object = new_msg;
    }

    try Future.Callback.call_done_callbacks(data, .canceled);
    return true;
}

pub fn future_cancel(self: ?*PythonFutureObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;

    const future_data = utils.get_data_ptr(Future, instance);

    var cancel_msg_py_object: ?PyObject = null;
    var cancel_msg_kwarg: ?PyObject = null;
    const pos_len: usize = if (nargs > 0) @intCast(nargs) else 0;
    const pos_args: []?PyObject = if (args) |a| a[0..pos_len] else &.{};
    if (nargs > 1 or pos_args.len > 1) {
        python_c.raise_python_value_error("Invalid number of arguments\x00");
        return null;
    }
    if (pos_args.len == 1) {
        cancel_msg_py_object = python_c.py_newref(pos_args[0].?);
    }

    if (knames != null and args != null) {
        python_c.parse_vector_call_kwargs(
            knames,
            pos_args.ptr + pos_args.len,
            &.{"msg\x00"},
            &.{&cancel_msg_kwarg},
        ) catch |err| {
            python_c.py_xdecref(cancel_msg_py_object);
            return utils.handle_zig_function_error(err, null);
        };
    }

    // BUG-441: parse_vector_call_kwargs unconditionally newrefs into its
    // slot, so feeding it the positional slot overwrote (leaked) the owned
    // positional message reference. Use a separate slot and reject the
    // positional+keyword collision exactly like CPython
    // (TypeError: got multiple values for argument 'msg').
    if (cancel_msg_kwarg != null and cancel_msg_py_object != null) {
        python_c.py_xdecref(cancel_msg_py_object);
        python_c.py_xdecref(cancel_msg_kwarg);
        python_c.raise_python_type_error("cancel() got multiple values for argument 'msg'\x00");
        return null;
    }
    if (cancel_msg_kwarg != null) {
        cancel_msg_py_object = cancel_msg_kwarg;
        cancel_msg_kwarg = null;
    }

    const ret = future_fast_cancel(instance, future_data, cancel_msg_py_object) catch |err| {
        python_c.py_xdecref(cancel_msg_py_object);
        return utils.handle_zig_function_error(err, null);
    };
    python_c.py_xdecref(cancel_msg_py_object);

    return python_c.PyBool_FromLong(@intCast(@intFromBool(ret)));
}

pub fn future_cancelled(self: ?*PythonFutureObject, _: ?PyObject) callconv(.c) ?PyObject {
    const future_data = utils.get_data_ptr(Future, self.?);
    return switch (future_data.status) {
        .canceled => python_c.get_py_true(),
        else => python_c.get_py_false(),
    };
}

pub fn future_make_cancelled_error(self: ?*PythonFutureObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    if (instance.cancelled_exc) |exc| {
        return python_c.py_newref(exc);
    }
    const exc_class = utils.PythonImports.get("cancelled_error_exc");
    if (instance.cancel_msg_py_object) |m| {
        if (!python_c.is_none(m)) {
            return python_c.PyObject_CallFunctionObjArgs(exc_class, m, @as(?*python_c.PyObject, null));
        }
    }
    return python_c.PyObject_CallFunctionObjArgs(exc_class, @as(?*python_c.PyObject, null));
}
