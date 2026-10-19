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

const static_talyn_types = .{ &future.Python.FutureType, &task.PythonTaskType, &handle.PythonHandleType, &timer_handle.PythonTimerHandleType, &utils.PseudoSocket.PseudoSocketType };

const static_talyn_modules_name = .{ "Future\x00", "Task\x00", "Handle\x00", "TimerHandle\x00", "PseudoSocket\x00" };

const dynamic_talyn_modules_init_fns = .{ loop.Python.create_type, transports.Stream.create_type, transports.StreamServer.create_type, transports.Datagram.create_type, transports.Subprocess.create_type };

const dynamic_talyn_types_ptrs = .{ &loop.Python.LoopType, &transports.Stream.StreamType, &transports.StreamServer.StreamServerType, &transports.Datagram.DatagramTransportType, &transports.Subprocess.SubprocessType };

const dynamic_talyn_modules_names = .{ "Loop\x00", "StreamTransport\x00", "StreamServer\x00", "DatagramTransport\x00", "SubprocessTransport\x00" };

fn module_cleanup(_: *python_c.PyObject) callconv(.c) void {
    // BUG-305: release the cached Python module references on EVERY
    // teardown, including free-threaded builds. The historical skip of
    // Python object cleanup in free-threading mode guarded against
    // teardown segfaults that traced back to the BUG-41-era double-decref
    // of type objects — which BUG-41 already removed. Plain Py_DecRef of
    // imported modules carries no such hazard: CPython's free-threaded
    // runtime supports concurrent reference counting, and interpreter
    // finalization reaches module dealloc after world threads are joined.
    //
    // release_python_imports() is itself race-safe under free-threading:
    // it swap-extracts each cached reference (BUG-305), so even if this
    // callback were invoked concurrently or reentrantly, every reference
    // would be decremented exactly once.
    utils.PythonImports.release_python_imports();
    if (builtin.single_threaded) {
        deinitialize_talyn_types();
    }
    // if (builtin.mode == .Debug) {
    //     _ = utils.gpa.detectLeaks();
    // }
    _ = utils.gpa.deinit();
}


const std = @import("std");

fn ensure_fd_limit() void {
    // Raise RLIMIT_NOFILE before any types are initialized.
    // pytest collection and IO fixed-file registration both need
    // more than the SSH-default 1024 fds.
    const rlim = std.posix.getrlimit(.NOFILE) catch return;
    std.posix.setrlimit(.NOFILE, .{ .cur = 8256, .max = rlim.max }) catch |err| std.log.warn("setrlimit failed: {s}", .{@errorName(err)});
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

fn talyn_module_exec(module: *python_c.PyObject) callconv(.c) c_int {
    utils.init_gpa();
    loop.init_module(utils.gpa.allocator());

    utils.PythonImports.initialize_python_imports() catch {
        return -1;
    };
    errdefer utils.PythonImports.release_python_imports();

    initialize_talyn_types() catch {
        return -1;
    };
    errdefer deinitialize_talyn_types();

    // Populate the module with the Talyn types.
    inline for (dynamic_talyn_modules_names, dynamic_talyn_types_ptrs) |name, obj| {
        if (python_c.PyModule_AddObject(module, name, @as(*python_c.PyObject, @ptrCast(obj.*))) < 0) {
            return -1;
        }
    }

    inline for (static_talyn_modules_name, static_talyn_types) |name, obj| {
        if (python_c.PyModule_AddObject(module, name, @as(*python_c.PyObject, @ptrCast(obj))) < 0) {
            return -1;
        }
    }

    // Declare free-threaded safety when applicable.
    if (@hasDecl(python_c._c, "PyUnstable_Module_SetGIL")) {
        if (python_c.PyUnstable_Module_SetGIL(module, python_c.Py_MOD_GIL_NOT_USED) < 0) {
            return -1;
        }
    }

    return 0;
}

var talyn_module_slots = [_]python_c.PyModuleDef_Slot{
    .{ .slot = python_c.Py_mod_exec, .value = @ptrCast(@constCast(&talyn_module_exec)) },
    .{ .slot = python_c.Py_mod_gil, .value = if (@hasDecl(python_c._c, "PyUnstable_Module_SetGIL")) python_c.Py_MOD_GIL_NOT_USED else null },
    .{ .slot = 0, .value = null },
};

var talyn_module = python_c.PyModuleDef{
    .m_base = if (@hasField(python_c.PyObject, "ob_tid")) .{
        .ob_base = .{
            .ob_tid = 0,
            .ob_flags = python_c._c._Py_STATICALLY_ALLOCATED_FLAG,
            .ob_mutex = .{},
            .ob_gc_bits = 0,
            .ob_ref_local = python_c._c._Py_IMMORTAL_REFCNT_LOCAL,
            .ob_ref_shared = 0,
            .ob_type = null,
        },
        .m_init = null,
        .m_index = 0,
        .m_copy = null,
    } else .{
        .ob_base = @import("std").mem.zeroes(python_c.PyObject),
        .m_init = null,
        .m_index = 0,
        .m_copy = null,
    },
    .m_name = "talyn_zig\x00",
    .m_doc = "Talyn: A lightning-fast Zig-powered event loop for Python's asyncio.\x00",
    .m_size = 0,
    .m_methods = null,
    .m_slots = @ptrCast(&talyn_module_slots),
    .m_free = @ptrCast(&module_cleanup),
};

export fn PyInit_talyn_zig() ?*python_c.PyObject {
    return python_c.PyModuleDef_Init(&talyn_module);
}
