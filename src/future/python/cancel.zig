const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const Future = @import("../main.zig");
const PythonFutureObject = Future.Python.FutureObject;

const utils = @import("utils");

pub inline fn future_fast_cancel(instance: *PythonFutureObject, data: *Future, cancel_msg_py_object: ?PyObject) !bool {
    switch (data.status) {
        .finished, .canceled => return false,
        else => {}
    }

    if (cancel_msg_py_object) |pyobj| {
        python_c.py_xdecref(instance.cancel_msg_py_object);
        instance.cancel_msg_py_object = python_c.py_newref(pyobj);
    }

    try Future.Callback.call_done_callbacks(data, .canceled);
    return true;
}

pub fn future_cancel(
    self: ?*PythonFutureObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?PyObject {
    const instance = self.?;

    const future_data = utils.get_data_ptr(Future, instance);

    var cancel_msg_py_object: ?PyObject = null;
    if (nargs > 1) {
        python_c.raise_python_value_error("Invalid number of arguments\x00");
        return null;
    }
    if (nargs == 1) {
        cancel_msg_py_object = python_c.py_newref(args.?[0]);
    }

    const kwargs_start: usize = if (nargs > 0) @intCast(nargs) else 0;
    python_c.parse_vector_call_kwargs(
        knames, args.? + kwargs_start,
        &.{"msg\x00"},
        &.{&cancel_msg_py_object},
    ) catch |err| {
        python_c.py_xdecref(cancel_msg_py_object);
        return utils.handle_zig_function_error(err, null);
    };

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
        else => python_c.get_py_false()
    };
}

pub fn future_make_cancelled_error(self: ?*PythonFutureObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    if (instance.cancelled_exc) |exc| {
        return python_c.py_newref(exc);
    }
    const exc_class = utils.PythonImports.cancelled_error_exc;
    if (instance.cancel_msg_py_object) |m| {
        return python_c.PyObject_CallFunctionObjArgs(exc_class, m, @as(?*python_c.PyObject, null));
    }
    return python_c.PyObject_CallFunctionObjArgs(exc_class, @as(?*python_c.PyObject, null));
}
