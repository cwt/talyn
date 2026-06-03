const builtin = @import("builtin");

const python_c = @import("python_c");
const talyn = @import("talyn");

const utils = @import("utils");
const future = talyn.Future;
const task = talyn.Task;
const loop = talyn.Loop;
const handle = talyn.Handle;
const timer_handle = talyn.TimerHandle;
const transports = talyn.Transports;


const static_talyn_types = .{
    &future.Python.FutureType,
    &task.PythonTaskType,
    &handle.PythonHandleType,
    &timer_handle.PythonTimerHandleType,
    &utils.PseudoSocket.PseudoSocketType
};

const static_talyn_modules_name = .{
    "Future\x00",
    "Task\x00",
    "Handle\x00",
    "TimerHandle\x00",
    "PseudoSocket\x00"
};

const dynamic_talyn_modules_init_fns = .{
    loop.Python.create_type,
    transports.Stream.create_type,
    transports.StreamServer.create_type,
    transports.Datagram.create_type,
    transports.Subprocess.create_type
};

const dynamic_talyn_types_ptrs = .{
    &loop.Python.LoopType,
    &transports.Stream.StreamType,
    &transports.StreamServer.StreamServerType,
    &transports.Datagram.DatagramTransportType,
    &transports.Subprocess.SubprocessType
};

const dynamic_talyn_modules_names = .{
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
        deinitialize_talyn_types();
        utils.PythonImports.release_python_imports();
    }
    // if (builtin.mode == .Debug) {
    //     _ = utils.gpa.detectLeaks();
    // }
    _ = utils.gpa.deinit();
}

var talyn_module = python_c.PyModuleDef{
    .m_name = "talyn_zig\x00",
    .m_doc = "Talyn: A lightning-fast Zig-powered event loop for Python's asyncio.\x00",
    .m_size = -1,
    .m_free = @ptrCast(&module_cleanup)
};

const std = @import("std");

fn ensure_fd_limit() void {
    // Raise RLIMIT_NOFILE before any types are initialized.
    // pytest collection and IO fixed-file registration both need
    // more than the SSH-default 1024 fds.
    const rlim = std.posix.getrlimit(.NOFILE) catch return;
    std.posix.setrlimit(.NOFILE, .{ .cur = 8256, .max = rlim.max }) catch {};
}

fn initialize_talyn_types() !void {
    ensure_fd_limit();
    inline for (static_talyn_types) |v| {
        if (python_c.PyType_Ready(v) < 0) {
            return error.PythonError;
        }
    }

    inline for (dynamic_talyn_modules_init_fns) |func| {
        try func();
    }
}

fn deinitialize_talyn_types() void {
    // BUG-41: Do NOT decref the type objects here. They were added to the
    // module via `PyModule_AddObject`, which **steals** the reference. When
    // Python's module cleanup runs, it decrefs them back to 0 (or frees
    // static types whose refcount was 1 from PyType_Ready). If we also
    // decref here, the second decref underflows the refcount and causes
    // use-after-free on interpreter shutdown. The types are now owned by
    // Python's module machinery; we must not touch their refcounts.
    //
    // We still null out the dynamic-type pointer slots so any future
    // accidental access hits a clear null rather than a dangling pointer.
    inline for (dynamic_talyn_types_ptrs) |ptr| {
        ptr.* = undefined;
    }
}

fn initialize_python_module() !*python_c.PyObject {
    const module: *python_c.PyObject = python_c.PyModule_Create(&talyn_module) orelse return error.PythonError;
    errdefer python_c.py_decref(module);

    if (@hasDecl(python_c._c, "PyUnstable_Module_SetGIL")) {
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

    inline for (dynamic_talyn_modules_names, dynamic_talyn_types_ptrs) |name, obj| {
        if (
            python_c.PyModule_AddObject(
                module, name, @as(*python_c.PyObject, @ptrCast(obj.*))
            ) < 0
        ) {
            return error.PythonError;
        }
    }

    inline for (static_talyn_modules_name, static_talyn_types) |name, obj| {
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

export fn PyInit_talyn_zig() ?*python_c.PyObject {
    utils.init_gpa();
    loop.init_module(utils.gpa.allocator());
    utils.PythonImports.initialize_python_imports() catch return null;
    initialize_talyn_types() catch return null;
    // BUG-66: If initialize_python_module fails after
    // initialize_talyn_types succeeded, clean up the initialized
    // types so we don't leak them. The dynamic_talyn_types_ptrs
    // will be cleared but the static types are still safe (they
    // aren't decref'd here — see BUG-41).
    if (initialize_python_module()) |module| {
        return module;
    } else |_| {
        deinitialize_talyn_types();
        return null;
    }
}
 
