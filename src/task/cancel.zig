const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const Future = @import("../future/main.zig");
const Task = @import("main.zig");

const PythonTaskObject = Task.PythonTaskObject;

fn cancel_future_waiter(future: PyObject, cancel_msg_py_object: ?PyObject) anyerror!bool {
    if (python_c.type_check(future, &Task.PythonTaskType)) {
        const task: *PythonTaskObject = @ptrCast(future);
        const ret = try fast_task_cancel(task, utils.get_data_ptr(Future, &task.fut), cancel_msg_py_object);
        return ret;
    } else if (python_c.type_check(future, &Future.Python.FutureType)) {
        const fut: *Future.Python.FutureObject = @ptrCast(future);
        const ret = try Future.Python.Cancel.future_fast_cancel(fut, utils.get_data_ptr(Future, fut), cancel_msg_py_object);
        return ret;
    }

    const cancel_function: PyObject = python_c.PyObject_GetAttrString(future, "cancel\x00") orelse return error.PythonError;
    defer python_c.py_decref(cancel_function);

    const ret: PyObject = if (cancel_msg_py_object) |msg|
        python_c.PyObject_CallOneArg(cancel_function, msg) orelse return error.PythonError
    else
        python_c.PyObject_CallNoArgs(cancel_function) orelse return error.PythonError;
    defer python_c.py_decref(ret);

    return (python_c.PyObject_IsTrue(ret) != 0);
}

inline fn fast_task_cancel(task: *PythonTaskObject, data: *Future, cancel_msg_py_object: ?PyObject) !bool {
    switch (data.status) {
        .finished, .canceled => return false,
        .pending => {},
    }

    if (cancel_msg_py_object) |pyobj| {
        const new_msg = python_c.py_newref(pyobj);
        python_c.py_xdecref(task.fut.cancel_msg_py_object);
        task.fut.cancel_msg_py_object = new_msg;
    }

    task.cancel_requests +|= 1;

    if (task.fut_waiter) |fut_waiter| {
        // BUG-371: if the waiter resolved in the same tick, its cancel
        // returns false (already finished). The cancellation must NOT
        // be dropped: fall through so wakeup_task throws the
        // CancelledError into the coroutine instead of delivering the
        // result (CPython does the same and keeps a second
        // asyncio.timeout() working after cancellation races).
        const ret = try cancel_future_waiter(fut_waiter, cancel_msg_py_object);
        if (ret) return true;
    }

    task.must_cancel = true;
    return true;
}

pub fn task_cancel(self: ?*PythonTaskObject, args: ?PyObject, kwargs: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;

    const future_data = utils.get_data_ptr(Future, &instance.fut);

    switch (future_data.status) {
        .finished, .canceled => return python_c.get_py_false(),
        .pending => {},
    }

    var kwlist: [2][*c]u8 = undefined;
    kwlist[0] = @constCast("msg\x00");
    kwlist[1] = null;

    var cancel_msg_py_object: ?PyObject = null;

    if (python_c.PyArg_ParseTupleAndKeywords(args, kwargs, "|O:msg\x00", @ptrCast(&kwlist), &cancel_msg_py_object) < 0) {
        return null;
    }

    const cancelled = fast_task_cancel(instance, future_data, cancel_msg_py_object) catch |err| {
        return utils.handle_zig_function_error(err, null);
    };
    return python_c.PyBool_FromLong(@intCast(@intFromBool(cancelled)));
}

pub fn task_uncancel(self: ?*PythonTaskObject) callconv(.c) ?PyObject {
    const instance = self.?;
    const new_cancel_requests = instance.cancel_requests -| 1;
    instance.cancel_requests = new_cancel_requests;
    // BUG-371: uncancel may only CLEAR must_cancel when the request
    // count reaches zero (CPython: `task_must_cancel = 0`). Re-arming
    // it here injected an extra unrequested CancelledError into the
    // next await inside cleanup/finally code of nested
    // asyncio.timeout() blocks.
    if (new_cancel_requests == 0) {
        instance.must_cancel = false;
    }
    return python_c.PyLong_FromUnsignedLongLong(@intCast(new_cancel_requests));
}

pub fn task_cancelling(self: ?*PythonTaskObject) callconv(.c) ?PyObject {
    const instance = self.?;
    // BUG-371: cancelling() reports the request count unconditionally
    // (CPython behavior) — asyncio.TaskGroup inspects it from done
    // callbacks AFTER the task finished, to distinguish internal from
    // external cancellations.
    return python_c.PyLong_FromUnsignedLongLong(@intCast(instance.cancel_requests));
}
