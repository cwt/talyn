const python_c = @import("python_c");
const std = @import("std");
const PyObject = *python_c.PyObject;
const utils = @import("utils");
const Loop = @import("../../../main.zig");
const LoopObject = Loop.Python.LoopObject;
const Future = @import("../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;
const SubprocessTransport = @import("../../../../transports/subprocess/transport.zig");

inline fn z_loop_subprocess_exec(
    self: *LoopObject, args: []?PyObject, knames: ?PyObject
) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len < 1) {
        python_c.raise_python_value_error("protocol_factory is required");
        return error.PythonError;
    }
    const protocol_factory: PyObject = args[0].?;

    var py_pid: ?PyObject = null;
    try python_c.parse_vector_call_kwargs(
        knames, args.ptr + args.len,
        &.{"pid"},
        &.{&py_pid},
    );

    if (python_c.PyCallable_Check(protocol_factory) <= 0) {
        python_c.raise_python_type_error("protocol_factory must be callable");
        return error.PythonError;
    }
    if (py_pid == null) {
        python_c.raise_python_value_error("pid keyword required (use talyn subprocess wrapper)");
        return error.PythonError;
    }

    const fut = try Future.Python.Constructors.fast_new_future(self);
    const pid: std.posix.pid_t = @intCast(python_c.PyLong_AsLongLong(py_pid.?));

    const protocol = python_c.PyObject_CallNoArgs(protocol_factory) orelse return error.PythonError;
    const transport = try SubprocessTransport.new_with_pid(protocol, self, pid);
    errdefer python_c.py_decref(@ptrCast(transport));

    const cm = python_c.PyObject_GetAttrString(protocol, "connection_made") orelse return error.PythonError;
    defer python_c.py_decref(cm);
    const r = python_c.PyObject_CallOneArg(cm, @ptrCast(transport)) orelse return error.PythonError;
    python_c.py_decref(r);

    try SubprocessTransport.start_exit_watcher(transport, self);

    // Return (transport, protocol) tuple — standard asyncio convention
    const result_tuple = python_c.PyTuple_Pack(2, @as(PyObject, @ptrCast(transport)), protocol)
        orelse return error.PythonError;
    defer python_c.py_decref(result_tuple);

    // Decref local references as PyTuple_Pack increments them
    python_c.py_decref(@ptrCast(transport));
    python_c.py_decref(protocol);

    const future_data = utils.get_data_ptr(Future, fut);
    try Future.Python.Result.future_fast_set_result(future_data, result_tuple);

    return fut;
    }

pub fn loop_subprocess_exec(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_subprocess_exec, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames },
    );
}
