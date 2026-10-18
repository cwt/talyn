const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const Future = @import("../main.zig");
const PythonFutureObject = Future.Python.FutureObject;

const utils = @import("utils");

inline fn raise_cancel_exception(self: *PythonFutureObject) void {
    if (self.cancelled_exc) |exc| {
        python_c.PyErr_SetRaisedException(python_c.py_newref(exc));
        return;
    }
    if (self.cancel_msg_py_object) |cancel_msg_py_object| {
        if (!python_c.is_none(cancel_msg_py_object)) {
            python_c.PyErr_SetObject(utils.PythonImports.get("cancelled_error_exc"), cancel_msg_py_object);
            return;
        }
    }
    python_c.PyErr_SetNone(utils.PythonImports.get("cancelled_error_exc"));
}

pub inline fn get_result(self: *PythonFutureObject) ?PyObject {
    const future_data = utils.get_data_ptr(Future, self);
    return switch (future_data.status) {
        .pending => blk: {
            python_c.PyErr_SetString(utils.PythonImports.get("invalid_state_exc"), "Result is not ready.\x00");
            break :blk null;
        },
        .finished => blk: {
            if (self.exception) |exc| {
                python_c.PyErr_SetRaisedException(python_c.py_newref(exc));
                break :blk null;
            }
            // BUG-369: tp_clear may have detached the result while the
            // status stayed .finished (a finalizer calling result()
            // during GC); report InvalidStateError instead of
            // unwrapping null (Mandate #4 — no panics).
            if (future_data.result == null) {
                python_c.PyErr_SetString(
                    utils.PythonImports.get("invalid_state_exc"),
                    "Result is not ready.\x00",
                );
                break :blk null;
            }
            break :blk @as(PyObject, @ptrCast(@alignCast(future_data.result.?)));
        },
        .canceled => blk: {
            raise_cancel_exception(self);
            break :blk null;
        },
    };
}

pub fn future_result(self: ?*PythonFutureObject, _: ?PyObject) callconv(.c) ?PyObject {
    const res = get_result(self.?);
    python_c.py_xincref(res);
    return res;
}

pub fn future_exception(self: ?*PythonFutureObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;

    const future_data = utils.get_data_ptr(Future, instance);

    return switch (future_data.status) {
        .pending => blk: {
            python_c.PyErr_SetString(utils.PythonImports.get("invalid_state_exc"), "Exception is not set.\x00");
            break :blk null;
        },
        .finished => blk: {
            if (instance.exception) |exc| {
                break :blk python_c.py_newref(exc);
            }
            break :blk python_c.get_py_none();
        },
        .canceled => blk: {
            raise_cancel_exception(instance);
            break :blk null;
        },
    };
}

pub inline fn future_fast_set_exception(self: *PythonFutureObject, obj: *Future, exception: PyObject) !void {
    // BUG-372: reject non-pending futures (CPython raises
    // InvalidStateError for the same condition) — a re-set overwrote
    // the previous payload reference and dispatched the done callbacks
    // machinery twice. The payload slot is also released when a
    // future is somehow re-targeted while still pending.
    if (obj.status != .pending) {
        python_c.PyErr_SetString(
            utils.PythonImports.get("invalid_state_exc"),
            "Exception already setted\x00",
        );
        return error.PythonError;
    }
    python_c.py_xdecref(self.exception);
    self.exception = python_c.py_newref(exception);
    try Future.Callback.call_done_callbacks(obj, .finished);
}

/// Central helper (BUG-265): turn a Zig error into the pending Python
/// exception and set it on `future`. Previously copy-pasted across five
/// loop/python/io call sites, causing fix drift.
pub fn set_future_exception(err: anyerror, future: *PythonFutureObject) !void {
    utils.handle_zig_function_error(err, {});
    const exc = python_c.PyErr_GetRaisedException() orelse return error.PythonError;
    defer python_c.py_decref(exc);

    const future_data = utils.get_data_ptr(Future, future);
    try future_fast_set_exception(future, future_data, exc);
}

inline fn z_future_set_exception(self: *PythonFutureObject, exception: PyObject) !PyObject {
    if (!python_c.exception_check(exception)) {
        python_c.raise_python_type_error("Invalid exception instance\x00");
        return error.PythonError;
    }

    const future_data = utils.get_data_ptr(Future, self);

    // BUG-369: a teardown-bound Future cannot be resolved (see
    // z_future_set_result).
    if (future_data.released) {
        python_c.PyErr_SetString(utils.PythonImports.get("invalid_state_exc"), "Exception already setted\x00");
        return error.PythonError;
    }

    switch (future_data.status) {
        .finished, .canceled => {
            python_c.PyErr_SetString(utils.PythonImports.get("invalid_state_exc"), "Exception already setted\x00");
            return error.PythonError;
        },
        .pending => {},
    }

    try future_fast_set_exception(self, future_data, exception);
    return python_c.get_py_none();
}

pub fn future_set_exception(self: ?*PythonFutureObject, exception: ?PyObject) callconv(.c) ?PyObject {
    return utils.execute_zig_function(z_future_set_exception, .{ self.?, exception.? });
}

pub inline fn future_fast_set_result(obj: *Future, result: PyObject) !void {
    obj.result = python_c.py_newref(result);
    try Future.Callback.call_done_callbacks(obj, .finished);
}

inline fn z_future_set_result(self: *PythonFutureObject, result: PyObject) !PyObject {
    const future_data = utils.get_data_ptr(Future, self);

    // BUG-369: a teardown-bound Future cannot be resolved — its
    // callbacks queue is already deinit'd and arming the done-callback
    // machinery on the dead object would be a use-after-free.
    if (future_data.released) {
        python_c.PyErr_SetString(utils.PythonImports.get("invalid_state_exc"), "Result already setted\x00");
        return error.PythonError;
    }

    switch (future_data.status) {
        .finished, .canceled => {
            python_c.PyErr_SetString(utils.PythonImports.get("invalid_state_exc"), "Result already setted\x00");
            return error.PythonError;
        },
        .pending => {},
    }

    try future_fast_set_result(future_data, result);
    return python_c.get_py_none();
}

pub fn future_set_result(self: ?*PythonFutureObject, result: ?PyObject) callconv(.c) ?PyObject {
    return utils.execute_zig_function(z_future_set_result, .{ self.?, result.? });
}

pub fn future_done(self: ?*PythonFutureObject, _: ?PyObject) callconv(.c) ?PyObject {
    const future_data = utils.get_data_ptr(Future, self.?);
    return switch (future_data.status) {
        .finished, .canceled => python_c.get_py_true(),
        else => python_c.get_py_false(),
    };
}
