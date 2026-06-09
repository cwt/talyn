const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const Loop = @import("../main.zig");
const Task = @import("../../task/main.zig");

const LoopObject = Loop.Python.LoopObject;

pub fn asyncgen_firstiter_hook(
    self: ?*LoopObject, agen: ?PyObject
) callconv(.c) ?PyObject {
    const instance = self orelse {
        std.log.err("asyncgen_firstiter_hook called with null self", .{});
        return null;
    };
    const _agen = agen orelse {
        std.log.err("asyncgen_firstiter_hook called with null agen", .{});
        return null;
    };

    const asyncgens_set_add = instance.asyncgens_set_add orelse {
        std.log.err("asyncgens_set_add is unexpectedly null in asyncgen_firstiter_hook", .{});
        return null;
    };

    const ret: ?PyObject = python_c.PyObject_CallOneArg(asyncgens_set_add, _agen);
    return ret;
}

inline fn append_new_task(
    self: *LoopObject, agen: PyObject
) !PyObject {
    const loop_data = utils.get_data_ptr(Loop, self);
    if (!loop_data.initialized) {
        python_c.raise_python_runtime_error("Loop is closed\x00");
        return error.PythonError;
    }

    const aclose: PyObject = python_c.PyObject_GetAttrString(agen, "aclose\x00")
        orelse return error.PythonError;
    errdefer python_c.py_decref(aclose);

    const context: PyObject = python_c.PyContext_CopyCurrent()
        orelse return error.PythonError;
    errdefer python_c.py_decref(context);

    const task = try Task.Constructors.fast_new_task(self, aclose, context, null);
    python_c.py_decref(@ptrCast(task));

    return python_c.get_py_none();
}

pub fn asyncgen_finalizer_hook(
    self: ?*LoopObject, agen: ?PyObject
) callconv(.c) ?PyObject {
    const instance = self orelse {
        std.log.err("asyncgen_finalizer_hook called with null self", .{});
        return null;
    };
    const _agen = agen orelse {
        std.log.err("asyncgen_finalizer_hook called with null agen", .{});
        return null;
    };

    const asyncgens_set_discard = instance.asyncgens_set_discard orelse {
        std.log.err("asyncgens_set_discard is unexpectedly null in asyncgen_finalizer_hook", .{});
        return null;
    };

    const discard_ret: PyObject = python_c.PyObject_CallOneArg(asyncgens_set_discard, _agen)
        orelse return null;
    python_c.py_decref(discard_ret);

    return utils.execute_zig_function(append_new_task, .{instance, _agen});
}

const LoopAsyncGenFirstIterHookMethod = python_c.PyMethodDef{
    .ml_name = "_asyncgen_firstiter_hook\x00",
    .ml_meth = @ptrCast(&asyncgen_firstiter_hook),
    .ml_doc = "Hook called when the first iterator is created\x00",
    .ml_flags = python_c.METH_O
};

const LoopAsyncGenFinalizerHookMethod = python_c.PyMethodDef{
    .ml_name = "_asyncgen_finalizer_hook\x00",
    .ml_meth = @ptrCast(&asyncgen_finalizer_hook),
    .ml_doc = "Hook called when the iterator is finalized\x00",
    .ml_flags = python_c.METH_O
};

pub fn setup_asyncgen_hooks(self: *LoopObject) !void {
    if (self.old_asyncgen_hooks != null) {
        python_c.raise_python_runtime_error("Asyncgen hooks already set\x00");
        return error.PythonError;
    }

    self.old_asyncgen_hooks = python_c.PyObject_CallNoArgs(utils.PythonImports.get("get_asyncgen_hooks"))
        orelse return error.PythonError;

    var args: [2]PyObject = undefined;
    args[0] = python_c.PyCFunction_New(
        @constCast(&LoopAsyncGenFirstIterHookMethod), @ptrCast(self)
    ) orelse return error.PythonError;
    defer python_c.py_decref(args[0]);

    args[1] =  python_c.PyCFunction_New(
        @constCast(&LoopAsyncGenFinalizerHookMethod), @ptrCast(self)
    ) orelse return error.PythonError;
    defer python_c.py_decref(args[1]);

    const ret: PyObject = python_c.PyObject_Vectorcall(
        utils.PythonImports.get("set_asyncgen_hooks"), &args, args.len, null
    ) orelse return error.PythonError;
    python_c.py_decref(ret);
}

pub fn cleanup_asyncgen_hooks(self: *LoopObject) void {
    const hooks = self.old_asyncgen_hooks orelse return;
    const ret: PyObject = python_c.PyObject_CallObject(utils.PythonImports.get("set_asyncgen_hooks"), hooks)
        orelse return;
    python_c.py_decref(ret);
    python_c.py_decref_and_set_null(&self.old_asyncgen_hooks);
}
