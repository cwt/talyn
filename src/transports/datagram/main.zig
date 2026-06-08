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

    write_buf: [@sizeOf(WriteTransport)]u8 align(@alignOf(WriteTransport)),
    read_buf: [@sizeOf(ReadTransport)]u8 align(@alignOf(ReadTransport)),

    buffer_size: usize,
    writing_high_water_mark: usize,
    writing_low_water_mark: usize,
    is_writing: bool,
    closed: bool,
    read_task_id: usize = 0,
    fixed_file_index: u16 = 0,
    fixed_buffer_index: i32 = -1,
    buffer_ptr: ?[*]u8 = null,
    buffer_len: usize = 0,
};

pub const WriteTransport = @import("write.zig");
pub const ReadTransport = @import("read.zig");

pub const Constructors = @import("constructors.zig");
const ExtraInfo = @import("extra_info.zig");

fn cleanup_resources(instance: *DatagramTransportObject) void {
    if (instance.fixed_file_index != 0) {
        if (instance.loop) |loop| {
            const loop_obj: *LoopObject = @alignCast(@ptrCast(loop));
            const loop_data = utils.get_data_ptr(Loop, loop_obj);
            if (loop_data.initialized) {
                loop_data.io.unregister_fixed_file(instance.fixed_file_index);
            }
        }
        instance.fixed_file_index = 0;
    }
    if (instance.fixed_buffer_index != -1) {
        if (instance.loop) |loop| {
            const loop_obj: *LoopObject = @alignCast(@ptrCast(loop));
            const loop_data = utils.get_data_ptr(Loop, loop_obj);
            if (loop_data.initialized) {
                loop_data.io.release_buffer(@intCast(instance.fixed_buffer_index));
            }
        }
        instance.fixed_buffer_index = -1;
        instance.buffer_ptr = null;
        instance.buffer_len = 0;
    } else if (instance.buffer_len > 0) {
        if (instance.loop) |loop| {
            const loop_obj: *LoopObject = @alignCast(@ptrCast(loop));
            const loop_data = utils.get_data_ptr(Loop, loop_obj);
            if (loop_data.initialized) {
                if (instance.buffer_ptr) |ptr| {
                    loop_data.allocator.free(ptr[0..instance.buffer_len]);
                }
            }
        }
        instance.buffer_ptr = null;
        instance.buffer_len = 0;
    }
}

fn datagram_dealloc(self: ?*DatagramTransportObject) callconv(.c) void {
    const instance = self.?;
    python_c.PyObject_GC_UnTrack(instance);
    cleanup_resources(instance);
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
    const instance = self.?;

    // Visit type object (required for heap types)
    if (python_c.Py_TYPE(@ptrCast(instance))) |t| {
        const vret_t = visit.?(@ptrCast(t), arg);
        if (vret_t != 0) return vret_t;
    }

    // Visit managed dictionary (for dynamically added attributes)
    if (python_c.has_managed_dict(@ptrCast(instance))) {
        const vret_dict = python_c.PyObject_VisitManagedDict(@ptrCast(instance), visit, arg);
        if (vret_dict != 0) return vret_dict;
    }

    return python_c.py_visit(instance, visit, arg);
}

fn datagram_clear(self: ?*DatagramTransportObject) callconv(.c) c_int {
    const instance = self.?;
    cleanup_resources(instance);
    if (instance.fd >= 0) {
        _ = std.os.linux.close(instance.fd);
        instance.fd = -1;
    }
    instance.closed = true;

    python_c.deinitialize_object_fields(instance, &.{});
    if (python_c.has_managed_dict(@ptrCast(instance))) {
        python_c.PyObject_ClearManagedDict(@ptrCast(instance));
    }
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
        if (instance.loop) |loop| {
            const loop_obj: *LoopObject = @alignCast(@ptrCast(loop));
            const loop_data = utils.get_data_ptr(Loop, loop_obj);
            if (loop_data.initialized) {
                if (instance.read_task_id != 0) {
                    _ = loop_data.io.queue(.{ .Cancel = instance.read_task_id }) catch {};
                }
                if (instance.fd >= 0) {
                    _ = loop_data.io.queue(.{ .CancelByFd = @intCast(instance.fd) }) catch {};
                }
            }
        }
        if (instance.fd >= 0) {
            _ = std.os.linux.close(instance.fd);
            instance.fd = -1;
        }
        // BUG-52: cleanup_resources releases the fixed file slot
        // and the registered buffer (or frees the heap-allocated
        // buffer if not registered). Without this call, repeatedly
        // creating and closing datagram transports would exhaust
        // fixed file slots and the buffer pool.
        cleanup_resources(instance);
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
    .{ .slot = python_c.Py_tp_doc, .pfunc = @constCast("Talyn DatagramTransport.\x00") },
    .{ .slot = 0, .pfunc = null },
};

// const PythonDatagramMembers: []const python_c.PyMemberDef = &[_]python_c.PyMemberDef{

var datagram_spec = python_c.PyType_Spec{
    .name = "talyn.DatagramTransport\x00",
    .basicsize = @sizeOf(DatagramTransportObject),
    .itemsize = 0,
    .flags = python_c.Py_TPFLAGS_DEFAULT | python_c.Py_TPFLAGS_BASETYPE | python_c.Py_TPFLAGS_HAVE_GC,
    .slots = @constCast(DatagramSlots.ptr),
};

pub var DatagramTransportType: ?*python_c.PyTypeObject = null;

pub fn create_type() !void {
    if (DatagramTransportType != null) return;
    DatagramTransportType = @ptrCast(python_c.PyType_FromSpecWithBases(
        @constCast(&datagram_spec), utils.PythonImports.get("asyncio_datagram_transport")
    ) orelse return error.PythonError);
}
