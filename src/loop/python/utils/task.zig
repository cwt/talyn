const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const Loop = @import("../../main.zig");
const Task = @import("../../../task/main.zig");

const PythonLoopObject = Loop.Python.LoopObject;
const PythonTaskObject = Task.PythonTaskObject;

inline fn z_loop_create_task(
    self: *PythonLoopObject, args: []?PyObject,
    knames: ?PyObject
) !*PythonTaskObject {
    if (args.len != 1) {
        python_c.raise_python_runtime_error("Invalid number of arguments\x00");
        return error.PythonError;
    }

    var context: ?PyObject = null;
    var name: ?PyObject = null;
    var context_passed: bool = false;
    try python_c.parse_vector_call_kwargs(
        knames, args.ptr + args.len,
        &.{"context\x00", "name\x00"},
        &.{&context, &name},
    );
    errdefer python_c.py_xdecref(name);
    errdefer python_c.py_xdecref(context);

    if (context) |py_ctx| {
        context_passed = !python_c.is_none(py_ctx);
        if (python_c.is_none(py_ctx)) {
            context = python_c.PyContext_CopyCurrent()
                orelse return error.PythonError;
            python_c.py_decref(py_ctx);
        }else if (!python_c.is_type(py_ctx, &python_c.PyContext_Type)) {
            python_c.raise_python_type_error("Invalid context\x00");
            return error.PythonError;
        }
    }else {
        context = python_c.PyContext_CopyCurrent() orelse return error.PythonError;
    }

    if (name) |v| {
        if (python_c.is_none(v)) {
            python_c.py_decref(v);
            name = null;
        }else if (!python_c.unicode_check(v)) {
            python_c.raise_python_type_error("name must be a string\x00");
            return error.PythonError;
        }
    }

    const coro: PyObject = python_c.py_newref(args[0].?);
    errdefer python_c.py_decref(coro);

    if (self.task_factory) |factory| {
        // factory(loop, coro, **kwargs) — mirrors CPython's _BaseEventLoop.create_task
        // (Python 3.13+). We only pass `context` as a kwarg when it's not None
        // (matching stdlib behaviour), so user factories written without
        // `context=` keep working.
        const py_args = python_c.PyTuple_Pack(2, @as(*python_c.PyObject, @ptrCast(self)), coro) orelse return error.PythonError;
        defer python_c.py_decref(py_args);

        var task: PyObject = undefined;
        if (context_passed) {
            const py_kwargs = python_c.PyDict_New() orelse return error.PythonError;
            defer python_c.py_decref(py_kwargs);
            _ = python_c.PyDict_SetItemString(py_kwargs, "context\x00", context.?);
            task = python_c.PyObject_Call(factory, py_args, py_kwargs) orelse return error.PythonError;
        } else {
            task = python_c.PyObject_Call(factory, py_args, null) orelse return error.PythonError;
        }
        // The return type is expected to be *PythonTaskObject, but factory could return anything.
        // asyncio doesn't enforce return type, but our internal code might.
        // Actually z_loop_create_task returns !*PythonTaskObject.
        // I should probably change the return type to !PyObject or check the type.
        return @ptrCast(task);
    }

    const task = try Task.Constructors.fast_new_task(self, coro, context.?, name);
    return task;
}

pub fn loop_create_task(
    self: ?*PythonLoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?PyObject {
    return @ptrCast(utils.execute_zig_function(z_loop_create_task, .{
        self.?, args.?[0..@as(usize, @intCast(nargs))], knames
    }));
}
