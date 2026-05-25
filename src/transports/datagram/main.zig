const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const utils = @import("utils");
const CallbackManager = @import("callback_manager");

const Loop = @import("../../loop/main.zig");
const LoopObject = Loop.Python.LoopObject;

pub const ProtocolType = enum { Datagram };

pub const DatagramTransportObject = extern struct {
    ob_base: python_c.PyObject,

    loop: ?PyObject,
    fd: std.posix.fd_t,

    protocol: ?PyObject,
    protocol_datagram_received: ?PyObject,
    protocol_error_received: ?PyObject,
    protocol_connection_lost: ?PyObject,

    write_buf: [@sizeOf(WriteTransport)]u8,
    read_buf: [@sizeOf(ReadTransport)]u8,

    buffer_size: usize,
    writing_high_water_mark: usize,
    writing_low_water_mark: usize,
    is_writing: bool,
    closed: bool,
};

pub const WriteTransport = @import("write.zig");
pub const ReadTransport = @import("read.zig");

pub const Constructors = @import("constructors.zig");
const ExtraInfo = @import("extra_info.zig");

fn datagram_dealloc(self: ?*DatagramTransportObject) callconv(.c) void {
    const instance = self.?;
    if (!instance.closed and instance.fd >= 0) {
        if (instance.loop) |loop| {
            const loop_obj: *LoopObject = @alignCast(@ptrCast(loop));
            if (loop_obj.debug) {
                const msg = python_c.PyUnicode_FromFormat("unclosed transport <DatagramTransport fd=%d>\x00", instance.fd);
                if (msg) |m| {
                    defer python_c.py_decref(m);
                    python_c.py_warn(python_c.PyExc_ResourceWarning.?, m, 1);
                }
            }
        }
    }
    if (instance.fd >= 0) {
        _ = std.os.linux.close(instance.fd);
        instance.fd = -1;
    }
    instance.closed = true;
    python_c.py_xdecref(instance.loop);
    python_c.py_xdecref(instance.protocol);
    python_c.py_xdecref(instance.protocol_datagram_received);
    python_c.py_xdecref(instance.protocol_error_received);
    python_c.py_xdecref(instance.protocol_connection_lost);

    const @"type" = python_c.get_type(@ptrCast(instance)) orelse return;
    @"type".tp_free.?(@ptrCast(instance));
}

fn datagram_traverse(self: ?*DatagramTransportObject, visit: python_c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    return python_c.py_visit(self.?, visit, arg);
}

fn datagram_clear(self: ?*DatagramTransportObject) callconv(.c) c_int {
    const instance = self.?;
    if (instance.fd >= 0) {
        _ = std.os.linux.close(instance.fd);
        instance.fd = -1;
    }
    instance.closed = true;
    return 0;
}

fn datagram_init(self: ?*DatagramTransportObject, args: ?PyObject, kwargs: ?PyObject) callconv(.c) c_int {
    return utils.execute_zig_function(Constructors.z_datagram_init, .{ self.?, args, kwargs });
}

fn datagram_sendto(self: ?*DatagramTransportObject, args: ?[*]?PyObject, nargs: isize) callconv(.c) ?PyObject {
    return WriteTransport.z_datagram_sendto(self.?, args.?[0..@as(usize, @intCast(nargs))]) catch |err| {
        return utils.handle_zig_function_error(err, null);
    };
}

fn datagram_close(self: ?*DatagramTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    if (!instance.closed) {
        instance.closed = true;
        if (instance.fd >= 0) {
            _ = std.os.linux.close(instance.fd);
            instance.fd = -1;
        }
    }
    return python_c.get_py_none();
}

fn datagram_abort(self: ?*DatagramTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    return datagram_close(self, null);
}

fn datagram_is_closing(self: ?*DatagramTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    return python_c.PyBool_FromLong(@intFromBool(self.?.closed));
}

fn datagram_get_extra_info(self: ?*DatagramTransportObject, args: ?PyObject) callconv(.c) ?PyObject {
    return ExtraInfo.z_datagram_get_extra_info(self.?, args) catch |err| {
        return utils.handle_zig_function_error(err, null);
    };
}

fn datagram_set_write_buffer_limits(self: ?*DatagramTransportObject, args: ?[*]?PyObject, nargs: isize) callconv(.c) ?PyObject {
    _ = WriteTransport.z_datagram_set_write_buffer_limits(self.?, args.?[0..@as(usize, @intCast(nargs))]) catch |err| {
        return utils.handle_zig_function_error(err, null);
    };
    return python_c.get_py_none();
}

fn datagram_get_write_buffer_size(self: ?*DatagramTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    return python_c.PyLong_FromUnsignedLongLong(@intCast(self.?.buffer_size));
}

fn datagram_get_write_buffer_limits(self: ?*DatagramTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    const low = python_c.PyLong_FromUnsignedLongLong(@intCast(instance.writing_low_water_mark)) orelse return null;
    defer python_c.py_decref(low);
    const high = python_c.PyLong_FromUnsignedLongLong(@intCast(instance.writing_high_water_mark)) orelse return null;
    defer python_c.py_decref(high);
    
    return python_c.PyTuple_Pack(2, low, high);
}

const DatagramMethods: []const python_c.PyMethodDef = &[_]python_c.PyMethodDef{
    .{ .ml_name = "sendto\x00", .ml_meth = @ptrCast(&datagram_sendto), .ml_doc = "Send a datagram.\x00", .ml_flags = python_c.METH_FASTCALL },
    .{ .ml_name = "close\x00", .ml_meth = @ptrCast(&datagram_close), .ml_doc = "Close the transport.\x00", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = "abort\x00", .ml_meth = @ptrCast(&datagram_abort), .ml_doc = "Abort the transport.\x00", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = "is_closing\x00", .ml_meth = @ptrCast(&datagram_is_closing), .ml_doc = "Return True if the transport is closing.\x00", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = "get_extra_info\x00", .ml_meth = @ptrCast(&datagram_get_extra_info), .ml_doc = "Get extra transport info.\x00", .ml_flags = python_c.METH_O },
    .{ .ml_name = "set_write_buffer_limits\x00", .ml_meth = @ptrCast(&datagram_set_write_buffer_limits), .ml_doc = "Set write buffer limits.\x00", .ml_flags = python_c.METH_FASTCALL },
    .{ .ml_name = "get_write_buffer_size\x00", .ml_meth = @ptrCast(&datagram_get_write_buffer_size), .ml_doc = "Get write buffer size.\x00", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = "get_write_buffer_limits\x00", .ml_meth = @ptrCast(&datagram_get_write_buffer_limits), .ml_doc = "Get write buffer limits.\x00", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = null, .ml_meth = null, .ml_doc = null, .ml_flags = 0 },
};

const DatagramSlots: []const python_c.PyType_Slot = &[_]python_c.PyType_Slot{
    .{ .slot = python_c.Py_tp_new, .pfunc = @constCast(&Constructors.datagram_new) },
    .{ .slot = python_c.Py_tp_init, .pfunc = @constCast(&datagram_init) },
    .{ .slot = python_c.Py_tp_dealloc, .pfunc = @constCast(&datagram_dealloc) },
    .{ .slot = python_c.Py_tp_traverse, .pfunc = @constCast(&datagram_traverse) },
    .{ .slot = python_c.Py_tp_clear, .pfunc = @constCast(&datagram_clear) },
    .{ .slot = python_c.Py_tp_methods, .pfunc = @constCast(DatagramMethods.ptr) },
    .{ .slot = python_c.Py_tp_doc, .pfunc = @constCast("Leviathan DatagramTransport.\x00") },
    .{ .slot = 0, .pfunc = null },
};

// const PythonDatagramMembers: []const python_c.PyMemberDef = &[_]python_c.PyMemberDef{

const datagram_spec = python_c.PyType_Spec{
    .name = "leviathan.DatagramTransport\x00",
    .basicsize = @sizeOf(DatagramTransportObject),
    .itemsize = 0,
    .flags = python_c.Py_TPFLAGS_DEFAULT | python_c.Py_TPFLAGS_BASETYPE,
    .slots = @constCast(DatagramSlots.ptr),
};

pub var DatagramTransportType: ?*python_c.PyTypeObject = null;

pub fn create_type() !void {
    if (DatagramTransportType != null) return;
    DatagramTransportType = @ptrCast(python_c.PyType_FromSpecWithBases(
        @constCast(&datagram_spec), utils.PythonImports.asyncio_datagram_transport
    ) orelse return error.PythonError);
}
