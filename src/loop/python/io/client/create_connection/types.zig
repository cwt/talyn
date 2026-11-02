// TALYN-016-EXEMPT: removeTaskId lives in connect.zig (MultiConnectState method split across modules)
const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const CallbackManager = @import("callback_manager");
const Resolv = @import("../../../../dns/resolv.zig");

const Loop = @import("../../../../main.zig");
const LoopObject = Loop.Python.LoopObject;

const Future = @import("../../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;

const Stream = @import("../../../../../transports/stream/main.zig");

pub const SocketCreationData = struct {
    py_host: ?PyObject = null,
    py_port: ?PyObject = null,
    py_ssl: ?PyObject = null,
    py_family: ?PyObject = null,
    py_proto: ?PyObject = null,
    py_local_addr: ?PyObject = null,
    py_server_hostname: ?PyObject = null,
    py_ssl_handshake_timeout: ?PyObject = null,
    py_ssl_shutdown_timeout: ?PyObject = null,
    py_happy_eyeballs_delay: ?PyObject = null, // Happy eyeballs? hahaha
    py_interleave: ?PyObject = null,
    py_all_errors: ?PyObject = null,
    py_dns_timeout: ?PyObject = null,
    dns_timeout: ?Resolv.DnsTimeout = null,

    protocol_factory: ?PyObject = null,
    future: ?*FutureObject = null,
    loop: ?*LoopObject = null,

    comptime {
        python_c.verify_gc_coverage(@This(), &.{});
    }

    pub fn deinit(self: *SocketCreationData) void {
        const loop_data = utils.get_data_ptr(Loop, self.loop.?);
        const allocator = loop_data.allocator;

        if (self.future) |f| {
            python_c.py_decref(@ptrCast(f));
            self.future = null;
        }
        if (self.loop) |l| {
            python_c.py_decref(@ptrCast(l));
            self.loop = null;
        }

        python_c.deinitialize_object_fields(self, &.{});
        allocator.destroy(self);
    }

    pub fn traverse(ptr: ?*anyopaque, visit_ptr: ?*anyopaque, arg: ?*anyopaque) c_int {
        const visit: python_c.visitproc = @ptrCast(@alignCast(visit_ptr));
        if (ptr) |p| {
            const self: *SocketCreationData = @ptrCast(@alignCast(p));
            return python_c.py_visit(self, visit, arg);
        }
        return 0;
    }
};

pub const TransportCreationData = struct {
    protocol_factory: PyObject,
    future: *FutureObject,
    loop: *LoopObject,
    socket_fd: std.posix.fd_t,
    zero_copying: bool,
    fd_created: bool = true,
    owns_fd: bool = true,
    // BUG-328: the caller's socket object on the sock= path - the transport
    // adopts the connection via dup and closes the caller's object the way
    // CPython's _SelectorTransport._call_connection_lost closes the wrapped
    // socket (otherwise the object keeps the connection open forever and a
    // peer waiting for EOF is wedged).
    py_sock: ?PyObject = null,
    python_payload: CallbackManager.PythonPayload = .{},
    dns_timeout: ?Resolv.DnsTimeout = null,

    comptime {
        python_c.verify_gc_coverage(@This(), &.{});
    }

    pub fn traverse(ptr: ?*anyopaque, visit_ptr: ?*anyopaque, arg: ?*anyopaque) c_int {
        const visit: python_c.visitproc = @ptrCast(@alignCast(visit_ptr));
        if (ptr) |p| {
            const self: *TransportCreationData = @ptrCast(@alignCast(p));
            var vret = visit.?(@ptrCast(self.protocol_factory), arg);
            if (vret != 0) return vret;
            vret = visit.?(@ptrCast(self.future), arg);
            if (vret != 0) return vret;
            vret = visit.?(@ptrCast(self.loop), arg);
            if (vret != 0) return vret;
            if (self.py_sock) |py_sock| {
                vret = visit.?(py_sock, arg);
                if (vret != 0) return vret;
            }
        }
        return 0;
    }
};

pub const SocketConnectionMethod = union(enum) {
    Single: usize, // Blocking task id
    HappyEyeballs: []usize, // Blocking task id per address
};

pub const SocketConnectionData = struct {
    creation_data: *SocketCreationData,
    address_list: ?[]utils.Address,
    local_addr_list: ?[]utils.Address,
    method: SocketConnectionMethod,
    python_payload: CallbackManager.PythonPayload = .{},
    dns_timeout: ?Resolv.DnsTimeout = null,

    comptime {
        python_c.verify_gc_coverage(@This(), &.{ "creation_data", "address_list", "local_addr_list" });
    }

    pub fn deinit(self: *SocketConnectionData) void {
        const loop_data = utils.get_data_ptr(Loop, self.creation_data.loop.?);
        const allocator = loop_data.allocator;

        self.creation_data.deinit();
        if (self.address_list) |v| {
            allocator.free(v);
        }

        if (self.local_addr_list) |v| {
            allocator.free(v);
        }

        allocator.destroy(self);
    }

    pub fn traverse(ptr: ?*anyopaque, visit_ptr: ?*anyopaque, arg: ?*anyopaque) c_int {
        if (ptr) |p| {
            const self: *SocketConnectionData = @ptrCast(@alignCast(p));
            return SocketCreationData.traverse(self.creation_data, visit_ptr, arg);
        }
        return 0;
    }
};

pub const MultiConnectState = struct {
    connection_data: *SocketConnectionData,
    pending: usize,
    succeeded: bool,
    timer_scheduled: bool,
    timer_fired: bool,
    // BUG-336: the happy-eyeballs timer is tracked separately from the
    // connect task_ids below. Cancelling a *completed* task is not just
    // wasteful: its BlockingTask slot is already freed and may have been
    // reused (e.g. by a factory-scheduled call_later timer queued during
    // transport creation), so a stale CancelIO would kill the new occupant
    // and its callback would fire immediately. Connect IDs are removed from
    // task_ids on completion; the timer ID lives here and is cleared when
    // the timer fires or is cancelled.
    happy_timer_id: ?usize = null,
    /// Set when the connect round is torn down after a submit failure
    /// while connects are still in flight (S4c/S4d). The future is already
    /// resolved and mcs stays alive until the last completion; completions
    /// must only close their fd and count down — never touch the future
    /// (double-resolve leaks the exception ref and re-fires done
    /// callbacks) and never create a transport.
    aborted: bool = false,
    failed_count: usize,
    task_ids: std.ArrayList(usize),
    all_errors: bool,
    exceptions: ?PyObject = null,
    python_payload: CallbackManager.PythonPayload = .{},

    comptime {
        python_c.verify_gc_coverage(@This(), &.{"connection_data"});
    }

    pub fn init(allocator: std.mem.Allocator, connection_data: *SocketConnectionData, all_errors: bool) !*MultiConnectState {
        const self = try allocator.create(MultiConnectState);
        self.* = .{ .connection_data = connection_data, .pending = 0, .succeeded = false, .timer_scheduled = false, .timer_fired = false, .failed_count = 0, .task_ids = .empty, .all_errors = all_errors, .python_payload = .{
            .module_ptr = @ptrCast(connection_data.creation_data.loop.?),
            .callback_ptr = @ptrCast(connection_data.creation_data.future.?),
            .traverse = &MultiConnectState.traverse_raw,
        } };
        if (all_errors) {
            self.exceptions = python_c.PyList_New(0) orelse return error.PythonError;
        }
        return self;
    }

    pub fn deinit(self: *MultiConnectState) void {
        const loop = self.connection_data.creation_data.loop.?;
        const loop_data = utils.get_data_ptr(Loop, loop);
        const allocator = loop_data.allocator;

        // task_ids holds only still-pending connects (completed ones are
        // removed in socket_connected_callback); the happy-eyeballs timer
        // is cancelled separately below, if still armed.
        for (self.task_ids.items) |task_id| {
            _ = Loop.Scheduling.IO.queue(&loop_data.io, .{ .CancelIO = task_id }) catch |err| std.log.warn("queue cancel failed: {s}", .{@errorName(err)});
        }
        if (self.happy_timer_id) |timer_id| {
            _ = Loop.Scheduling.IO.queue(&loop_data.io, .{ .CancelIO = timer_id }) catch |err| std.log.warn("queue cancel failed: {s}", .{@errorName(err)});
            self.happy_timer_id = null;
        }
        self.task_ids.deinit(allocator);
        if (self.exceptions) |e| python_c.py_decref(e);
        self.connection_data.deinit();
        allocator.destroy(self);
    }

    pub fn traverse_raw(ptr: ?*anyopaque, visit_ptr: ?*anyopaque, arg: ?*anyopaque) c_int {
        const visit: python_c.visitproc = @ptrCast(@alignCast(visit_ptr));
        if (ptr) |p| {
            const self: *MultiConnectState = @ptrCast(@alignCast(p));
            if (self.exceptions) |e| {
                const vret = visit.?(@ptrCast(e), arg);
                if (vret != 0) return vret;
            }

            const creation_data = self.connection_data.creation_data;
            if (creation_data.future) |f| {
                const vret = visit.?(@ptrCast(f), arg);
                if (vret != 0) return vret;
            }
            if (creation_data.loop) |l| {
                const vret = visit.?(@ptrCast(l), arg);
                if (vret != 0) return vret;
            }
            if (creation_data.protocol_factory) |pf| {
                const vret = visit.?(@ptrCast(pf), arg);
                if (vret != 0) return vret;
            }
        }

        return 0;
    }
};

pub const SocketData = struct {
    multi_state: *MultiConnectState,
    socket_fd: std.posix.fd_t,
    // io_uring task id of this connect request. Cleared from
    // multi_state.task_ids when this request completes (BUG-336).
    task_id: usize = 0,
    python_payload: CallbackManager.PythonPayload = .{},

    comptime {
        python_c.verify_gc_coverage(@This(), &.{"multi_state"});
    }

    pub fn traverse(ptr: ?*anyopaque, visit_ptr: ?*anyopaque, arg: ?*anyopaque) c_int {
        if (ptr) |p| {
            const self: *SocketData = @ptrCast(@alignCast(p));
            return MultiConnectState.traverse_raw(self.multi_state, visit_ptr, arg);
        }
        return 0;
    }
};
