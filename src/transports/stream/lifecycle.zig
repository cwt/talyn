const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const Loop = @import("../../loop/main.zig");
const LoopObject = Loop.Python.LoopObject;

const Stream = @import("main.zig");
const StreamTransportObject = Stream.StreamTransportObject;

const Constructors = @import("constructors.zig");

const WriteTransport = @import("../write_transport.zig");
const ReadTransport = @import("../read_transport.zig");

pub fn connection_lost_callback(transport_obj: PyObject, exception: PyObject) !void {
    const transport: *StreamTransportObject = @ptrCast(transport_obj);

    const read_transport = utils.get_data_ptr2(ReadTransport, "read_transport", transport);
    const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", transport);

    close_transports(transport, read_transport, write_transport, exception);
}

/// BUG-376: tell the Python Server wrapper this client connection is
/// gone, exactly once (the field is nulled as the once-guard), BEFORE
/// protocol.connection_lost can run arbitrary app code. Errors are
/// swallowed: the counter must not break the transport teardown.
/// BUG-369 ordering: resolve _detach BEFORE releasing the field — the
/// decref can drop the wrapper's last reference and free it, and the
/// captured `srv` pointer alone does not keep the object alive.
pub fn detach_server(transport: *StreamTransportObject) void {
    if (transport.server_ref) |srv| {
        const detach = python_c.PyObject_GetAttrString(srv, "_detach\x00");
        python_c.py_decref_and_set_null(&transport.server_ref);
        if (detach) |d| {
            defer python_c.py_decref(d);
            const r = python_c.PyObject_CallOneArg(d, @ptrCast(transport));
            if (r) |v| {
                python_c.py_decref(v);
            } else {
                python_c.PyErr_Clear();
            }
        } else {
            python_c.PyErr_Clear();
        }
    }
}

pub fn close_transports(transport: *StreamTransportObject, read_transport: *ReadTransport, write_transport: *WriteTransport, exception: PyObject) void {
    const closed_already = transport.closed;

    read_transport.close() catch |err| std.log.warn("read_transport close failed: {s}", .{@errorName(err)});
    write_transport.close() catch |err| std.log.warn("write_transport close failed: {s}", .{@errorName(err)});

    transport.is_reading = false;
    // BUG-378: reaching this function means the transport is shutting
    // down (EOF, I/O error or user close). is_closing must be true so a
    // later transport.close() cannot run the machinery a second time.
    transport.is_closing = true;

    if (closed_already) return;

    detach_server(transport);

    // BUG-378: connection_lost() fires only at the fully-closed
    // transition (both sides drained/force-closed), so stash the
    // exception this close came with and let maybe_close_fd do the
    // notify-once at the right moment.
    if (transport.pending_lost_exc == null) {
        transport.pending_lost_exc = python_c.py_newref(exception);
    }
    maybe_close_fd(transport);
}

/// BUG-378: dispatch protocol.connection_lost(exception) exactly once,
/// either directly when the loop is already closed or via call_soon.
/// `exception` must be an owned reference (decrefed here).
fn connection_lost_fp(loop_obj: PyObject, connection_lost: PyObject, exception_obj: PyObject) void {
    const is_closed_attr = python_c.PyObject_GetAttrString(loop_obj, "is_closed\x00") orelse {
        python_c.PyErr_Clear();
        python_c.py_decref(exception_obj);
        return;
    };
    defer python_c.py_decref(is_closed_attr);
    const is_closed_py = python_c.PyObject_CallNoArgs(is_closed_attr) orelse {
        python_c.PyErr_Clear();
        python_c.py_decref(exception_obj);
        return;
    };
    defer python_c.py_decref(is_closed_py);

    const rc = python_c.PyObject_IsTrue(is_closed_py);
    if (rc < 0) {
        python_c.PyErr_Clear();
        python_c.py_decref(exception_obj);
        return;
    }
    const closed = (rc == 1);

    if (closed) {
        const ret = python_c.PyObject_CallOneArg(connection_lost, exception_obj);
        if (ret) |v| {
            python_c.py_decref(v);
        } else {
            const exc = python_c.PyErr_GetRaisedException();
            if (exc) |e| {
                defer python_c.py_decref(e);
                const ctx = python_c.PyDict_New();
                if (ctx) |c| {
                    defer python_c.py_decref(c);
                    const msg = python_c.PyUnicode_FromString("Exception in connection_lost callback\x00");
                    if (msg) |m| {
                        _ = python_c.PyDict_SetItemString(c, "message\x00", m);
                        python_c.py_decref(m);
                    }
                    _ = python_c.PyDict_SetItemString(c, "exception\x00", e);
                    const ret2 = python_c.PyObject_CallMethod(loop_obj, "call_exception_handler\x00", "O\x00", c);
                    if (ret2) |r2| python_c.py_decref(r2) else python_c.PyErr_Clear();
                }
            }
        }
        python_c.py_decref(exception_obj);
    } else {
        const call_soon = python_c.PyObject_GetAttrString(loop_obj, "call_soon\x00") orelse {
            python_c.PyErr_Clear();
            python_c.py_decref(exception_obj);
            return;
        };
        defer python_c.py_decref(call_soon);
        const ret = python_c.PyObject_CallFunctionObjArgs(call_soon, connection_lost, exception_obj, @as(?*python_c.PyObject, null));
        if (ret) |v| python_c.py_decref(v) else python_c.PyErr_Clear();
        python_c.py_decref(exception_obj);
    }
}

fn schedule_connection_lost_once(transport: *StreamTransportObject) void {
    detach_server(transport);

    // BUG-378: at-most-once guard across close()/abort()/EOF/error paths.
    if (transport.connection_lost_notified) {
        return;
    }
    transport.connection_lost_notified = true;

    const stashed = transport.pending_lost_exc;
    transport.pending_lost_exc = null;

    const loop_obj = transport.loop orelse {
        python_c.py_xdecref(stashed);
        return;
    };
    const connection_lost = transport.protocol_connection_lost orelse {
        python_c.py_xdecref(stashed);
        return;
    };

    const exception_obj: PyObject = stashed orelse python_c.get_py_none();
    connection_lost_fp(loop_obj, connection_lost, exception_obj);
}

pub fn transport_close(self: ?*StreamTransportObject) callconv(.c) ?PyObject {
    const instance = self.?;

    if (instance.is_closing or instance.closed) {
        return python_c.get_py_none();
    }
    instance.is_closing = true;

    const read_transport = utils.get_data_ptr2(ReadTransport, "read_transport", instance);
    const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", instance);

    if (read_transport.closed and write_transport.closed) {
        instance.closed = true;

        cancel_and_close_fd(instance);
        // BUG-378: both sides are already closed; if no path has
        // scheduled the notification yet, fire it now (the guard makes
        // this a no-op otherwise).
        schedule_connection_lost_once(instance);

        return python_c.get_py_none();
    }

    const arg = python_c.get_py_none();
    close_transports(instance, read_transport, write_transport, arg);

    return arg;
}

pub fn maybe_close_fd(self: *StreamTransportObject) void {
    const read_transport = utils.get_data_ptr2(ReadTransport, "read_transport", self);
    const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", self);

    if (read_transport.closed and write_transport.closed) {
        // BUG-32: Bump dispatch_generation BEFORE mutating `closed` so any
        // in-flight completion records captured before the close see a stale
        // generation and are skipped at dispatch.
        @atomicStore(u64, &self.dispatch_generation, self.dispatch_generation + 1, .release);
        self.closed = true;
        cancel_and_close_fd(self);
        // BUG-378: this is the fully-closed transition — connection_lost
        // fires exactly once here (buffered writes have drained, or the
        // transports were force-closed).
        schedule_connection_lost_once(self);
    }
}

pub fn transport_is_closing(self: ?*StreamTransportObject) callconv(.c) ?PyObject {
    const instance = self.?;

    return python_c.PyBool_FromLong(@intCast(@intFromBool(instance.is_closing or instance.closed)));
}

pub fn transport_get_protocol(self: ?*StreamTransportObject) callconv(.c) ?PyObject {
    return python_c.py_newref(self.?.protocol.?);
}

pub fn transport_set_protocol(self: ?*StreamTransportObject, new_protocol: ?PyObject) callconv(.c) ?PyObject {
    _ = Constructors.set_protocol(self.?, new_protocol.?) catch |err| {
        return utils.handle_zig_function_error(err, null);
    };

    return python_c.get_py_none();
}

pub fn transport_force_close(self: ?*StreamTransportObject, exc: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;

    if (instance.closed) {
        return python_c.get_py_none();
    }

    // BUG-376 (server tracking): an aborted connection must detach from its
    // Python Server wrapper exactly like the graceful close path, otherwise
    // Server._active_count / _clients stay inflated and abort() bypasses the
    // accounting that close() performs. detach_server is idempotent (it
    // nulls server_ref), so a later GC (stream_clear) is a no-op.
    detach_server(instance);

    // BUG-32: Bump dispatch_generation before mutating state. Stale completion
    // records captured before the force close will see a mismatched generation.
    @atomicStore(u64, &instance.dispatch_generation, instance.dispatch_generation + 1, .release);
    instance.closed = true;

    // BUG-378: abort()'s exception argument replaces any pending close
    // exception BEFORE the chain of force-closes reaches
    // maybe_close_fd/schedule_connection_lost_once, so the once-only
    // notification carries the abort's exception (stdlib semantics).
    const new_exc = if (exc) |e| python_c.py_newref(e) else null;
    python_c.py_xdecref(instance.pending_lost_exc);
    instance.pending_lost_exc = new_exc;

    const read_transport = utils.get_data_ptr2(ReadTransport, "read_transport", instance);
    const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", instance);

    read_transport.force_close() catch |err| std.log.warn("read_transport force_close failed: {s}", .{@errorName(err)});
    write_transport.force_close() catch |err| std.log.warn("write_transport force_close failed: {s}", .{@errorName(err)});

    instance.is_reading = false;
    instance.is_writing = false;

    // BUG-378: the notification is driven by the force-closes' already
    // set `closed` flags via the maybe_close_fd/schedule path, so this
    // method only guarantees the fd teardown is complete (idempotent).
    cancel_and_close_fd(instance);

    return python_c.get_py_none();
}

pub fn transport_abort(self: ?*StreamTransportObject) callconv(.c) ?PyObject {
    return transport_force_close(self, null);
}

pub fn cancel_and_close_fd(self: *StreamTransportObject) void {
    const fd = self.fd;
    if (fd >= 0) {
        if (self.loop) |loop_obj| {
            const loop_data = utils.get_data_ptr(Loop, @as(*LoopObject, @ptrCast(loop_obj)));
            if (loop_data.initialized) {
                const read_transport = utils.get_data_ptr2(ReadTransport, "read_transport", self);
                const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", self);
                const has_pending = (read_transport.initialized and read_transport.blocking_task_id > 0) or
                    (write_transport.initialized and write_transport.blocking_task_id > 0);
                if (has_pending) {
                    _ = loop_data.io.queue(.{ .CancelByFd = @intCast(fd) }) catch |err| std.log.warn("queue cancel failed: {s}", .{@errorName(err)});
                }
            }
            if (self.fixed_file_index != 0) {
                loop_data.io.unregister_fixed_file(self.fixed_file_index);
                self.fixed_file_index = 0;
            }
        }
        if (self.owns_fd) {
            _ = std.os.linux.close(fd);
        }
        self.fd = -1;
    }
}
