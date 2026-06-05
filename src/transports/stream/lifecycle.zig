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

pub fn close_transports(
    transport: *StreamTransportObject,
    read_transport: *ReadTransport,
    write_transport: *WriteTransport,
    exception: PyObject
) void {
    const closed_already = transport.closed;

    read_transport.close() catch {};
    write_transport.close() catch {};

    transport.is_reading = false;

    if (closed_already) return;

    const loop_obj = transport.loop orelse return;
    const connection_lost = transport.protocol_connection_lost orelse return;

    // Check if loop is closed
    const is_closed_attr = python_c.PyObject_GetAttrString(loop_obj, "is_closed\x00") orelse {
        python_c.PyErr_Clear();
        return;
    };
    defer python_c.py_decref(is_closed_attr);
    const is_closed_py = python_c.PyObject_CallNoArgs(is_closed_attr) orelse {
        python_c.PyErr_Clear();
        return;
    };
    defer python_c.py_decref(is_closed_py);

    const closed = python_c.PyObject_IsTrue(is_closed_py) != 0;

    if (closed) {
        const ret = python_c.PyObject_CallOneArg(connection_lost, exception);
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
    } else {
        const call_soon = python_c.PyObject_GetAttrString(loop_obj, "call_soon\x00") orelse {
            python_c.PyErr_Clear();
            return;
        };
        defer python_c.py_decref(call_soon);
        const ret = python_c.PyObject_CallFunctionObjArgs(call_soon, connection_lost, exception, @as(?*python_c.PyObject, null));
        if (ret) |v| python_c.py_decref(v) else python_c.PyErr_Clear();
    }
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

        const fd = instance.fd;
        if (fd >= 0) {
            if (instance.fixed_file_index != 0) {
                if (instance.loop) |loop_obj| {
                    const loop_data = utils.get_data_ptr(Loop, @as(*LoopObject, @ptrCast(loop_obj)));
                    loop_data.io.unregister_fixed_file(instance.fixed_file_index);
                }
                instance.fixed_file_index = 0;
            }
            if (instance.owns_fd) {
                _ = std.os.linux.close(fd);
            }
            instance.fd = -1;
        }

        return python_c.get_py_none();
    }

    const arg = python_c.get_py_none();
    close_transports(instance, read_transport, write_transport, arg);

    // We don't set instance.closed = true here anymore.
    // Instead, we wait for both transports to be closed.
    // We also don't close the FD here.
    
    maybe_close_fd(instance);

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
        const fd = self.fd;
        if (fd >= 0) {
            if (self.fixed_file_index != 0) {
                if (self.loop) |loop_obj| {
                    const loop_data = utils.get_data_ptr(Loop, @as(*LoopObject, @ptrCast(loop_obj)));
                    loop_data.io.unregister_fixed_file(self.fixed_file_index);
                }
                self.fixed_file_index = 0;
            }
            if (self.owns_fd) {
                _ = std.os.linux.close(fd);
            }
            self.fd = -1;
        }
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
    // BUG-32: Bump dispatch_generation before mutating state. Stale completion
    // records captured before the force close will see a mismatched generation.
    @atomicStore(u64, &instance.dispatch_generation, instance.dispatch_generation + 1, .release);
    instance.closed = true;

    const read_transport = utils.get_data_ptr2(ReadTransport, "read_transport", instance);
    const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", instance);

    read_transport.force_close() catch {};
    write_transport.force_close() catch {};

    instance.is_reading = false;
    instance.is_writing = false;

    const fd = instance.fd;
    if (fd >= 0) {
        if (instance.fixed_file_index != 0) {
            if (instance.loop) |loop_obj| {
                const loop_data = utils.get_data_ptr(Loop, @as(*LoopObject, @ptrCast(loop_obj)));
                loop_data.io.unregister_fixed_file(instance.fixed_file_index);
            }
            instance.fixed_file_index = 0;
        }
        if (instance.owns_fd) {
            _ = std.os.linux.close(fd);
        }
        instance.fd = -1;
    }

    const exc_arg = if (exc) |e| python_c.py_newref(e) else python_c.get_py_none();
    defer python_c.py_decref(exc_arg);

    const connection_lost = instance.protocol_connection_lost orelse return python_c.get_py_none();
    const ret = python_c.PyObject_CallOneArg(connection_lost, exc_arg)
        orelse return null;
    python_c.py_decref(ret);

    return python_c.get_py_none();
}
