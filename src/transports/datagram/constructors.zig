const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const utils = @import("utils");
const DatagramTransport = @import("main.zig");
const Loop = @import("../../loop/main.zig");

pub fn datagram_new(
    @"type": ?*python_c.PyTypeObject, _: ?PyObject, _: ?PyObject
) callconv(.c) ?PyObject {
    const instance: *DatagramTransport.DatagramTransportObject = @ptrCast(
        @"type".?.tp_alloc.?(@"type".?, 0) orelse return null
    );
    python_c.initialize_object_fields(instance, &.{"ob_base"});
    instance.fd = -1;
    instance.closed = true;
    return @ptrCast(instance);
}

pub fn z_datagram_init(
    self: *DatagramTransport.DatagramTransportObject, args: ?PyObject, kwargs: ?PyObject
) !c_int {
    var kwlist: [4][*c]u8 = undefined;
    kwlist[0] = @constCast("loop\x00");
    kwlist[1] = @constCast("protocol\x00");
    kwlist[2] = @constCast("fd\x00");
    kwlist[3] = null;

    var py_loop: ?PyObject = null;
    var py_protocol: ?PyObject = null;
    var py_fd: ?PyObject = null;

    if (python_c.PyArg_ParseTupleAndKeywords(
        args, kwargs, "OO|L\x00", @ptrCast(&kwlist), &py_loop, &py_protocol, &py_fd
    ) < 0) return error.PythonError;

    if (!python_c.type_check(py_loop.?, Loop.Python.LoopType)) {
        python_c.raise_python_type_error("loop must be a talyn Loop\x00");
        return error.PythonError;
    }

    const fd: std.posix.fd_t = if (py_fd) |f| @intCast(python_c.PyLong_AsLongLong(f)) else -1;

    try init_configuration(self, py_protocol.?, @ptrCast(py_loop.?), fd);
    return 0;
}

pub fn init_configuration(
    self: *DatagramTransport.DatagramTransportObject,
    protocol: PyObject,
    loop: *Loop.Python.LoopObject,
    fd: std.posix.fd_t,
) !void {
    const loop_data = utils.get_data_ptr(Loop, loop);
    const allocator = loop_data.allocator;

    self.loop = python_c.py_newref(@as(*python_c.PyObject, @ptrCast(loop)));
    self.fd = fd;
    self.buffer_size = 0;
    self.writing_high_water_mark = std.math.maxInt(usize) / 2;
    self.writing_low_water_mark = std.math.maxInt(usize) / 2;
    self.is_writing = true;
    self.closed = false;

    // Register socket fd as fixed file
    const ffi = loop_data.io.register_fixed_file(fd) catch null;
    self.fixed_file_index = ffi orelse 0;

    // Lease registered buffer from the global pool
    var fixed_buffer_index: ?u16 = null;
    var buffer: []u8 = &.{};
    if (loop_data.io.lease_buffer()) |leased| {
        fixed_buffer_index = leased.index;
        buffer = leased.slice;
    } else {
        buffer = try allocator.alloc(u8, 65536);
    }
    self.fixed_buffer_index = fixed_buffer_index orelse 0xffff;
    self.buffer_ptr = buffer.ptr;
    self.buffer_len = buffer.len;

    try set_protocol(self, protocol);
}

pub fn set_protocol(
    self: *DatagramTransport.DatagramTransportObject, protocol: PyObject
) !void {
    if (python_c.PyObject_IsInstance(protocol, utils.PythonImports.asyncio_datagram_protocol) != 1) {
        python_c.raise_python_type_error("Invalid protocol\x00");
        return error.PythonError;
    }

    const old_protocol = self.protocol;
    const old_dr = self.protocol_datagram_received;
    const old_er = self.protocol_error_received;
    const old_cl = self.protocol_connection_lost;

    self.protocol = python_c.py_newref(protocol);
    errdefer {
        python_c.py_decref_and_set_null(&self.protocol);
        self.protocol = old_protocol;
        self.protocol_datagram_received = old_dr;
        self.protocol_error_received = old_er;
        self.protocol_connection_lost = old_cl;
    }

    self.protocol_datagram_received = python_c.PyObject_GetAttrString(protocol, "datagram_received\x00") orelse return error.PythonError;
    errdefer python_c.py_decref_and_set_null(&self.protocol_datagram_received);
    self.protocol_error_received = python_c.PyObject_GetAttrString(protocol, "error_received\x00") orelse return error.PythonError;
    errdefer python_c.py_decref_and_set_null(&self.protocol_error_received);
    self.protocol_connection_lost = python_c.PyObject_GetAttrString(protocol, "connection_lost\x00") orelse return error.PythonError;

    python_c.py_xdecref(old_protocol);
    python_c.py_xdecref(old_dr);
    python_c.py_xdecref(old_er);
    python_c.py_xdecref(old_cl);
}

pub fn new_datagram_transport(
    protocol: PyObject,
    loop: *Loop.Python.LoopObject,
    fd: std.posix.fd_t,
) !*DatagramTransport.DatagramTransportObject {
    const self: *DatagramTransport.DatagramTransportObject = @ptrCast(
        DatagramTransport.DatagramTransportType.?.tp_alloc.?(DatagramTransport.DatagramTransportType.?, 0) orelse return error.PythonError
    );
    errdefer DatagramTransport.DatagramTransportType.?.tp_free.?(@ptrCast(self));
    try init_configuration(self, protocol, loop, fd);
    return self;
}
