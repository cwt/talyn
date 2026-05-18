const builtin = @import("builtin");

const python_c = @import("python_c");
const leviathan = @import("leviathan");

const utils = @import("utils");
const future = leviathan.Future;
const task = leviathan.Task;
const loop = leviathan.Loop;
const handle = leviathan.Handle;
const timer_handle = leviathan.TimerHandle;
const transports = leviathan.Transports;


const static_leviathan_types = .{
    &future.Python.FutureType,
    &task.PythonTaskType,
    &handle.PythonHandleType,
    &timer_handle.PythonTimerHandleType,
    &utils.PseudoSocket.PseudoSocketType
};

const static_leviathan_modules_name = .{
    "Future\x00",
    "Task\x00",
    "Handle\x00",
    "TimerHandle\x00",
    "PseudoSocket\x00"
};

const dynamic_leviathan_modules_init_fns = .{
    loop.Python.create_type,
    transports.Stream.create_type,
    transports.StreamServer.create_type,
    transports.Datagram.create_type,
    transports.Subprocess.create_type
};

const dynamic_leviathan_types_ptrs = .{
    &loop.Python.LoopType,
    &transports.Stream.StreamType,
    &transports.StreamServer.StreamServerType,
    &transports.Datagram.DatagramTransportType,
    &transports.Subprocess.SubprocessType
};

const dynamic_leviathan_modules_names = .{
    "Loop\x00",
    "StreamTransport\x00",
    "StreamServer\x00",
    "DatagramTransport\x00",
    "SubprocessTransport\x00"
};

fn module_cleanup(_: *python_c.PyObject) callconv(.c) void {
    // Skip Python object cleanup in free-threading mode to avoid
    // teardown segfaults from GC/refcounting race conditions.
    // All memory is reclaimed by the OS on process exit anyway.
    if (builtin.single_threaded) {
        deinitialize_leviathan_types();
        utils.PythonImports.release_python_imports();
    }
    // if (builtin.mode == .Debug) {
    //     _ = utils.gpa.detectLeaks();
    // }
    _ = utils.gpa.deinit();
}

var leviathan_module = python_c.PyModuleDef{
    .m_name = "leviathan_zig\x00",
    .m_doc = "Leviathan: A lightning-fast Zig-powered event loop for Python's asyncio.\x00",
    .m_size = -1,
    .m_free = @ptrCast(&module_cleanup)
};

const std = @import("std");

fn ensure_fd_limit() void {
    // Raise RLIMIT_NOFILE before any types are initialized.
    // pytest collection and IO fixed-file registration both need
    // more than the SSH-default 1024 fds.
    var rlim: std.os.linux.rlimit = undefined;
    _ = std.os.linux.getrlimit(.NOFILE, &rlim);
    _ = std.os.linux.setrlimit(.NOFILE, &.{ .cur = 8256, .max = rlim.max });
}

fn initialize_leviathan_types() !void {
    ensure_fd_limit();
    inline for (static_leviathan_types) |v| {
        if (python_c.PyType_Ready(v) < 0) {
            return error.PythonError;
        }
    }

    inline for (dynamic_leviathan_modules_init_fns) |func| {
        try func();
    }
}

fn deinitialize_leviathan_types() void {
    inline for (static_leviathan_types) |v| {
        python_c.py_decref(@ptrCast(v));
    }

    inline for (dynamic_leviathan_types_ptrs) |ptr| {
        python_c.py_decref(@ptrCast(ptr.*));
        ptr.* = undefined;
    }
}

fn initialize_python_module() !*python_c.PyObject {
    const module: *python_c.PyObject = python_c.PyModule_Create(&leviathan_module) orelse return error.PythonError;
    errdefer python_c.py_decref(module);

    if (!builtin.single_threaded) {
        if (python_c.PyUnstable_Module_SetGIL(module, python_c.Py_MOD_GIL_NOT_USED) < 0) {
            return error.PythonError;
        }
    }

    if (
        python_c.PyModule_AddObject(
            module, "Loop\x00", @as(*python_c.PyObject, @ptrCast(loop.Python.LoopType))
        ) < 0
    ) {
        return error.PythonError;
    }

    inline for (dynamic_leviathan_modules_names, dynamic_leviathan_types_ptrs) |name, obj| {
        if (
            python_c.PyModule_AddObject(
                module, name, @as(*python_c.PyObject, @ptrCast(obj.*))
            ) < 0
        ) {
            return error.PythonError;
        }
    }

    inline for (static_leviathan_modules_name, static_leviathan_types) |name, obj| {
        if (
            python_c.PyModule_AddObject(
                module, name, @as(*python_c.PyObject, @ptrCast(obj))
            ) < 0
        ) {
            return error.PythonError;
        }
    }

    return module;
}

export fn PyInit_leviathan_zig() ?*python_c.PyObject {
    utils.init_gpa();
    loop.init_module(utils.gpa.allocator());
    utils.PythonImports.initialize_python_imports() catch return null;
    initialize_leviathan_types() catch return null;
    return initialize_python_module() catch return null;
}
 
