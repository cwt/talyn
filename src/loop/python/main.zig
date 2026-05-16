const std = @import("std");
const Loop = @import("../main.zig");

const utils = @import("utils");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const Constructors = @import("constructors.zig");
const Scheduling = @import("scheduling.zig");
const Control = @import("control.zig");
const Utils = @import("utils/main.zig");
const UnixSignal = @import("unix_signals.zig");
const IO = @import("io/main.zig");
// const Hooks = @import("hooks.zig");

const PythonLoopMethods: []const python_c.PyMethodDef = &[_]python_c.PyMethodDef{
    // --------------------- Control ---------------------
    python_c.PyMethodDef{
        .ml_name = "run_forever\x00",
        .ml_meth = @ptrCast(&Control.loop_run_forever),
        .ml_doc = "Run the event loop forever.\x00",
        .ml_flags = python_c.METH_NOARGS
    },
    python_c.PyMethodDef{
        .ml_name = "stop\x00",
        .ml_meth = @ptrCast(&Control.loop_stop),
        .ml_doc = "Stop the event loop.\x00",
        .ml_flags = python_c.METH_NOARGS
    },
    python_c.PyMethodDef{
        .ml_name = "is_running\x00",
        .ml_meth = @ptrCast(&Control.loop_is_running),
        .ml_doc = "Return True if the event loop is currently running.\x00",
        .ml_flags = python_c.METH_NOARGS
    },
    python_c.PyMethodDef{
        .ml_name = "is_closed\x00",
        .ml_meth = @ptrCast(&Control.loop_is_closed),
        .ml_doc = "Return True if the event loop was closed.\x00",
        .ml_flags = python_c.METH_NOARGS
    },
    python_c.PyMethodDef{
        .ml_name = "close\x00",
        .ml_meth = @ptrCast(&Control.loop_close),
        .ml_doc = "Close the event loop\x00",
        .ml_flags = python_c.METH_NOARGS
    },

    python_c.PyMethodDef{
        .ml_name = "get_debug\x00",
        .ml_meth = @ptrCast(&Control.loop_get_debug),
        .ml_doc = "Get the debug mode of the event loop.\x00",
        .ml_flags = python_c.METH_NOARGS
    },
    python_c.PyMethodDef{
        .ml_name = "set_debug\x00",
        .ml_meth = @ptrCast(&Control.loop_set_debug),
        .ml_doc = "Set the debug mode of the event loop.\x00",
        .ml_flags = python_c.METH_O
    },

    python_c.PyMethodDef{
        .ml_name = "get_task_factory\x00",
        .ml_meth = @ptrCast(&Control.loop_get_task_factory),
        .ml_doc = "Return a task factory, or None if the default one is used.\x00",
        .ml_flags = python_c.METH_NOARGS
    },
    python_c.PyMethodDef{
        .ml_name = "set_task_factory\x00",
        .ml_meth = @ptrCast(&Control.loop_set_task_factory),
        .ml_doc = "Set a task factory.\x00",
        .ml_flags = python_c.METH_O
    },
    python_c.PyMethodDef{
        .ml_name = "_add_hook\x00",
        .ml_meth = @ptrCast(&Control.loop_add_hook),
        .ml_doc = "Add a loop hook (internal use only).\x00",
        .ml_flags = python_c.METH_FASTCALL
    },
    python_c.PyMethodDef{
        .ml_name = "_add_path_watcher\x00",
        .ml_meth = @ptrCast(&Control.loop_add_path_watcher),
        .ml_doc = "Add a path watcher (internal use only).\x00",
        .ml_flags = python_c.METH_FASTCALL
    },
    python_c.PyMethodDef{
        .ml_name = "add_child_handler\x00",
        .ml_meth = @ptrCast(&Control.loop_add_child_handler),
        .ml_doc = "Add a child handler.\x00",
        .ml_flags = python_c.METH_FASTCALL
    },
    python_c.PyMethodDef{
        .ml_name = "remove_child_handler\x00",
        .ml_meth = @ptrCast(&Control.loop_remove_child_handler),
        .ml_doc = "Remove a child handler.\x00",
        .ml_flags = python_c.METH_FASTCALL
    },
    python_c.PyMethodDef{
        .ml_name = "_test_lru\x00",
        .ml_meth = @ptrCast(&Control.loop_test_lru),
        .ml_doc = "Test LRU cache (internal use only).\x00",
        .ml_flags = python_c.METH_NOARGS
    },

    // --------------------- Sheduling ---------------------
    python_c.PyMethodDef{
        .ml_name = "call_soon\x00",
        .ml_meth = @ptrCast(&Scheduling.loop_call_soon),
        .ml_doc = "Schedule callback to be called with args arguments at the next iteration of the event loop.\x00",
        .ml_flags = python_c.METH_FASTCALL | python_c.METH_KEYWORDS
    },
    python_c.PyMethodDef{
        .ml_name = "call_soon_threadsafe\x00",
        .ml_meth = @ptrCast(&Scheduling.loop_call_soon_threadsafe),
        .ml_doc = "Thread-safe variant of `call_soon`.\x00",
        .ml_flags = python_c.METH_FASTCALL | python_c.METH_KEYWORDS
    },
    python_c.PyMethodDef{
        .ml_name = "call_later\x00",
        .ml_meth = @ptrCast(&Scheduling.loop_call_later),
        .ml_doc = "Thread-safe variant of `call_soon`.\x00",
        .ml_flags = python_c.METH_FASTCALL | python_c.METH_KEYWORDS
    },
    python_c.PyMethodDef{
        .ml_name = "call_at\x00",
        .ml_meth = @ptrCast(&Scheduling.loop_call_at),
        .ml_doc = "Thread-safe variant of `call_soon`.\x00",
        .ml_flags = python_c.METH_FASTCALL | python_c.METH_KEYWORDS
    },

    // --------------------- Utils ---------------------
    python_c.PyMethodDef{
        .ml_name = "time\x00",
        .ml_meth = @ptrCast(&Utils.Time.loop_time),
        .ml_doc = "Return the current time, as a float value, according to the event loop’s internal monotonic clock.\x00",
        .ml_flags = python_c.METH_NOARGS
    },

    python_c.PyMethodDef{
        .ml_name = "create_future\x00",
        .ml_meth = @ptrCast(&Utils.Future.loop_create_future),
        .ml_doc = "Schedule callback to be called with args arguments at the next iteration of the event loop.\x00",
        .ml_flags = python_c.METH_NOARGS
    },
    python_c.PyMethodDef{
        .ml_name = "create_task\x00",
        .ml_meth = @ptrCast(&Utils.Task.loop_create_task),
        .ml_doc = "Schedule callback to be called with args arguments at the next iteration of the event loop.\x00",
        .ml_flags = python_c.METH_FASTCALL | python_c.METH_KEYWORDS
    },


    python_c.PyMethodDef{
        .ml_name = "add_signal_handler\x00",
        .ml_meth = @ptrCast(&UnixSignal.loop_add_signal_handler),
        .ml_doc = "Schedule callback to be called with args arguments at the next iteration of the event loop.\x00",
        .ml_flags = python_c.METH_FASTCALL
    },
    python_c.PyMethodDef{
        .ml_name = "remove_signal_handler\x00",
        .ml_meth = @ptrCast(&UnixSignal.loop_remove_signal_handler),
        .ml_doc = "Schedule callback to be called with args arguments at the next iteration of the event loop.\x00",
        .ml_flags = python_c.METH_O
    },

    // --------------------- Watchers ---------------------
    python_c.PyMethodDef{
        .ml_name = "add_reader\x00",
        .ml_meth = @ptrCast(&IO.Watchers.loop_add_reader),
        .ml_doc = "Start monitoring the fd file descriptor for read availability\x00",
        .ml_flags = python_c.METH_FASTCALL
    },
    python_c.PyMethodDef{
        .ml_name = "add_writer\x00",
        .ml_meth = @ptrCast(&IO.Watchers.loop_add_writer),
        .ml_doc = "Start monitoring the fd file descriptor for write availability\x00",
        .ml_flags = python_c.METH_FASTCALL
    },

    python_c.PyMethodDef{
        .ml_name = "remove_reader\x00",
        .ml_meth = @ptrCast(&IO.Watchers.loop_remove_reader),
        .ml_doc = "Stop monitoring the fd file descriptor for read availability\x00",
        .ml_flags = python_c.METH_O
    },
    python_c.PyMethodDef{
        .ml_name = "remove_writer\x00",
        .ml_meth = @ptrCast(&IO.Watchers.loop_remove_writer),
        .ml_doc = "Stop monitoring the fd file descriptor for write availability\x00",
        .ml_flags = python_c.METH_O
    },
    // --------------------- Socket client ---------------------
    python_c.PyMethodDef{
        .ml_name = "create_connection\x00",
        .ml_meth = @ptrCast(&IO.Client.create_connection.loop_create_connection),
        .ml_doc = "Open a streaming transport connection to a given address specified by host and port.\x00",
        .ml_flags = python_c.METH_FASTCALL | python_c.METH_KEYWORDS
    },
    // --------------------- Socket server ---------------------
    python_c.PyMethodDef{
        .ml_name = "create_server\x00",
        .ml_meth = @ptrCast(&IO.Server.create_server.loop_create_server),
        .ml_doc = "Create a TCP server.\x00",
        .ml_flags = python_c.METH_FASTCALL | python_c.METH_KEYWORDS
    },
    // --------------------- Socket DNS ---------------------
    python_c.PyMethodDef{
        .ml_name = "getaddrinfo\x00",
        .ml_meth = @ptrCast(&IO.Socket.getaddrinfo.loop_getaddrinfo),
        .ml_doc = "Resolve a hostname to a list of address tuples.\x00",
        .ml_flags = python_c.METH_FASTCALL | python_c.METH_KEYWORDS
    },
    python_c.PyMethodDef{
        .ml_name = "getnameinfo\x00",
        .ml_meth = @ptrCast(&IO.Socket.getnameinfo.loop_getnameinfo),
        .ml_doc = "Resolve a sockaddr to a (host, port) tuple.\x00",
        .ml_flags = python_c.METH_FASTCALL
    },
    // --------------------- Socket Ops ---------------------
    python_c.PyMethodDef{
        .ml_name = "sock_accept\x00",
        .ml_meth = @ptrCast(&IO.Socket.ops.loop_sock_accept),
        .ml_doc = "Accept a connection.\x00",
        .ml_flags = python_c.METH_FASTCALL
    },
    python_c.PyMethodDef{
        .ml_name = "sock_connect\x00",
        .ml_meth = @ptrCast(&IO.Socket.ops.loop_sock_connect),
        .ml_doc = "Connect a socket.\x00",
        .ml_flags = python_c.METH_FASTCALL
    },
    python_c.PyMethodDef{
        .ml_name = "sock_recv\x00",
        .ml_meth = @ptrCast(&IO.Socket.ops.loop_sock_recv),
        .ml_doc = "Receive data.\x00",
        .ml_flags = python_c.METH_FASTCALL
    },
    python_c.PyMethodDef{
        .ml_name = "sock_sendall\x00",
        .ml_meth = @ptrCast(&IO.Socket.ops.loop_sock_sendall),
        .ml_doc = "Send all data.\x00",
        .ml_flags = python_c.METH_FASTCALL
    },
    python_c.PyMethodDef{
        .ml_name = "sock_recv_into\x00",
        .ml_meth = @ptrCast(&IO.Socket.ops.loop_sock_recv_into),
        .ml_doc = "Receive data into a buffer.\x00",
        .ml_flags = python_c.METH_FASTCALL
    },
    python_c.PyMethodDef{
        .ml_name = "sock_recvfrom\x00",
        .ml_meth = @ptrCast(&IO.Socket.ops.loop_sock_recvfrom),
        .ml_doc = "Receive data from a socket.\x00",
        .ml_flags = python_c.METH_FASTCALL
    },
    python_c.PyMethodDef{
        .ml_name = "sock_sendto\x00",
        .ml_meth = @ptrCast(&IO.Socket.ops.loop_sock_sendto),
        .ml_doc = "Send data to a specific address.\x00",
        .ml_flags = python_c.METH_FASTCALL
    },
    // --------------------- Unix pipes ---------------------
    python_c.PyMethodDef{
        .ml_name = "create_unix_connection\x00",
        .ml_meth = @ptrCast(&IO.Pipe.unix.loop_create_unix_connection),
        .ml_doc = "Create a Unix socket connection.\x00",
        .ml_flags = python_c.METH_FASTCALL | python_c.METH_KEYWORDS
    },
    python_c.PyMethodDef{
        .ml_name = "create_unix_server\x00",
        .ml_meth = @ptrCast(&IO.Pipe.unix.loop_create_unix_server),
        .ml_doc = "Create a Unix socket server.\x00",
        .ml_flags = python_c.METH_FASTCALL | python_c.METH_KEYWORDS
    },
    // --------------------- Datagram ---------------------
    python_c.PyMethodDef{
        .ml_name = "create_datagram_endpoint\x00",
        .ml_meth = @ptrCast(&IO.Datagram.endpoint.loop_create_datagram_endpoint),
        .ml_doc = "Create a datagram endpoint.\x00",
        .ml_flags = python_c.METH_FASTCALL | python_c.METH_KEYWORDS
    },
    // --------------------- Subprocess ---------------------
    python_c.PyMethodDef{
        .ml_name = "subprocess_exec\x00",
        .ml_meth = @ptrCast(&IO.Subprocess.exec.loop_subprocess_exec),
        .ml_doc = "Execute a subprocess.\x00",
        .ml_flags = python_c.METH_FASTCALL | python_c.METH_KEYWORDS
    },
    // python_c.PyMethodDef{
    //     .ml_name = "remove_writer\x00",
    //     .ml_meth = @ptrCast(&Watchers.loop_remove_writer),
    //     .ml_doc = "Stop monitoring the fd file descriptor for write availability\x00",
    //     .ml_flags = python_c.METH_O
    // },
    // --------------------- Introspection ---------------------
    python_c.PyMethodDef{
        .ml_name = "_get_ring_fd\x00",
        .ml_meth = @ptrCast(&Control.loop_get_ring_fd),
        .ml_doc = "Return the io_uring ring fd (for testing).\x00",
        .ml_flags = python_c.METH_NOARGS
    },

    // --------------------- Sentinel ---------------------
    python_c.PyMethodDef{
        .ml_name = null, .ml_meth = null, .ml_doc = null, .ml_flags = 0
    }
};


const LoopMembers: []const python_c.PyMemberDef = &[_]python_c.PyMemberDef{
    python_c.PyMemberDef{ // Just for be supported by asyncio.isfuture
        .name = "_asyncgens\x00",
        .type = python_c.Py_T_OBJECT_EX,
        .offset = @offsetOf(LoopObject, "asyncgens_set"),
        .doc = null,
    },
    python_c.PyMemberDef{
        .name = "__weakref__\x00",
        .type = python_c.Py_T_OBJECT_EX,
        .offset = @offsetOf(LoopObject, "weakref_list"),
        .flags = 0,
        .doc = null,
    },
    python_c.PyMemberDef{
        .name = null, .flags = 0, .offset = 0, .doc = null
    }
};

pub const LoopObject = extern struct {
    ob_base: python_c.PyObject,
    data: [@sizeOf(Loop)]u8 align(@alignOf(Loop)),

    asyncgens_set: ?PyObject,
    asyncgens_set_add: ?PyObject,
    asyncgens_set_discard: ?PyObject,
    old_asyncgen_hooks: ?PyObject,

    asyncio_tasks_set: ?PyObject,

    exception_handler: ?PyObject,
    task_name_counter: u64,
    owner_pid: std.posix.pid_t,
    owner_tid: u64,

    debug: bool,
    slow_callback_duration: f64,
    weakref_list: ?PyObject,

    task_factory: ?PyObject,
};

const loop_slots = [_]python_c.PyType_Slot{
    .{ .slot = python_c.Py_tp_doc, .pfunc = @constCast("Leviathan's loop class\x00") },
    .{ .slot = python_c.Py_tp_new, .pfunc = @constCast(&Constructors.loop_new) },
    .{ .slot = python_c.Py_tp_traverse, .pfunc = @constCast(&Constructors.loop_traverse) },
    .{ .slot = python_c.Py_tp_clear, .pfunc = @constCast(&Constructors.loop_clear) },
    .{ .slot = python_c.Py_tp_init, .pfunc = @constCast(&Constructors.loop_init) },
    .{ .slot = python_c.Py_tp_dealloc, .pfunc = @constCast(&Constructors.loop_dealloc) },
    .{ .slot = python_c.Py_tp_methods, .pfunc = @constCast(PythonLoopMethods.ptr) },
    .{ .slot = python_c.Py_tp_members, .pfunc = @constCast(LoopMembers.ptr) },
    .{ .slot = 0, .pfunc = null },
};

const loop_spec = python_c.PyType_Spec{
    .name = "leviathan.Loop\x00",
    .basicsize = @sizeOf(LoopObject),
    .itemsize = 0,
    .flags = python_c.Py_TPFLAGS_DEFAULT | python_c.Py_TPFLAGS_BASETYPE | python_c.Py_TPFLAGS_HAVE_GC,
    .slots = @constCast(&loop_slots),
};

pub var LoopType: *python_c.PyTypeObject = undefined;

pub fn create_type() !void {
    const type_obj = python_c.PyType_FromSpecWithBases(@constCast(&loop_spec), utils.PythonImports.base_event_loop)
        orelse return error.PythonError;
    LoopType = @ptrCast(type_obj);
}

pub inline fn check_forked(self: *LoopObject) bool {
    const loop_data = utils.get_data_ptr(Loop, self);
    if (!loop_data.initialized) return false;
    if (self.owner_pid != std.os.linux.getpid()) {
        python_c.raise_python_runtime_error("Event loop was created in a parent process and is now being used in a child process after a fork(). This is unsafe. Please create a new event loop in the child process.\x00");
        return true;
    }
    return false;
}

pub inline fn check_thread(self: *LoopObject) bool {
    if (self.debug) {
        if (self.owner_tid != python_c._c.PyThread_get_thread_ident()) {
            python_c.raise_python_runtime_error("Non-thread-safe operation: event loop is being used from a different thread than it was created in.\x00");
            return true;
        }
    }
    return false;
}

test {
    _ = IO;
}
