const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const utils = @import("utils");
const CallbackManager = @import("callback_manager");
const Loop = @import("../../loop/main.zig");
const DatagramTransport = @import("main.zig");

const SendToData = struct {
    alloc: std.mem.Allocator,
    transport: *DatagramTransport.DatagramTransportObject,
    buf: []u8,
    address: utils.Address,
    msg: std.posix.msghdr_const,
    iov: std.posix.iovec_const,
};

fn cleanup_sendto(ptr: ?*anyopaque) void {
    const sd: *SendToData = @ptrCast(@alignCast(ptr.?));
    sd.alloc.free(sd.buf);
    const transport = sd.transport;
    python_c.py_decref(@ptrCast(transport));
    sd.alloc.destroy(sd);
}

fn sendto_completed(data: *const CallbackManager.CallbackData) !void {
    const sd: *SendToData = @alignCast(@ptrCast(data.user_data.?));
    defer cleanup_sendto(@ptrCast(@alignCast(sd)));

    const self = sd.transport;
    if (data.cancelled or self.closed) return;
    if (data.io_uring_err != .SUCCESS) {
        if (self.protocol_error_received) |er| {
            const exc = python_c.PyObject_CallFunction(
                python_c.PyExc_OSError, "Ls", @as(c_long, @intFromEnum(data.io_uring_err)), "Sendto error"
            ) orelse return error.PythonError;
            defer python_c.py_decref(exc);
            const r = python_c.PyObject_CallOneArg(er, exc) orelse return error.PythonError;
            python_c.py_decref(r);
        }
        return;
    }

    const written: usize = @intCast(@max(data.io_uring_res, 0));
    if (self.buffer_size >= written) {
        self.buffer_size -= written;
    } else {
        self.buffer_size = 0;
    }

    if (!self.is_writing and self.buffer_size <= self.writing_low_water_mark) {
        self.is_writing = true;
        if (self.protocol) |proto| {
            const rw = python_c.PyObject_GetAttrString(proto, "resume_writing") orelse return error.PythonError;
            defer python_c.py_decref(rw);
            const r = python_c.PyObject_CallNoArgs(rw) orelse return error.PythonError;
            python_c.py_decref(r);
        }
    }
}

fn buffer_watermark_check(self: *DatagramTransport.DatagramTransportObject, len: usize) !void {
    self.buffer_size += len;
    if (self.buffer_size > self.writing_high_water_mark and self.is_writing) {
        self.is_writing = false;
        if (self.protocol) |proto| {
            const pw = python_c.PyObject_GetAttrString(proto, "pause_writing") orelse return error.PythonError;
            defer python_c.py_decref(pw);
            const r = python_c.PyObject_CallNoArgs(pw) orelse return error.PythonError;
            python_c.py_decref(r);
        }
    }
}

pub fn z_datagram_sendto(self: *DatagramTransport.DatagramTransportObject, args: []?PyObject) !?PyObject {
    if (args.len < 1) {
        python_c.raise_python_value_error("data argument is required");
        return error.PythonError;
    }
    const data = args[0].?;
    if (self.closed) {
        python_c.raise_python_runtime_error("Transport is closed");
        return error.PythonError;
    }
    if (!self.is_writing) {
        return python_c.get_py_none();
    }

    var pbuffer: python_c.Py_buffer = undefined;
    if (python_c.PyObject_GetBuffer(data, &pbuffer, 0) < 0) return error.PythonError;
    defer python_c.PyBuffer_Release(&pbuffer);

    const len: usize = @intCast(pbuffer.len);
    if (len == 0) return python_c.get_py_none();

    const loop_data = utils.get_data_ptr(Loop, @as(*Loop.Python.LoopObject, @ptrCast(self.loop.?)));

    // Allocate storage on heap for both data and SendToData struct
    const data_buf = try loop_data.allocator.alloc(u8, len);
    errdefer loop_data.allocator.free(data_buf);
    @memcpy(data_buf, @as([*]const u8, @ptrCast(pbuffer.buf))[0..len]);

    const sd = try loop_data.allocator.create(SendToData);
    errdefer loop_data.allocator.free(data_buf);
    sd.* = .{
        .alloc = loop_data.allocator,
        .transport = self,
        .buf = data_buf,
        .address = undefined, // Only used if unconnected
        .msg = undefined,
        .iov = undefined,
    };

    sd.iov = .{ .base = data_buf.ptr, .len = data_buf.len };
    sd.msg = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&sd.iov),
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    // Check if addr argument is provided (sendto with explicit destination)
    if (args.len > 1 and args[1] != null and !python_c.is_none(args[1].?)) {
        const py_addr = args[1].?;

        // Determine socket family for address parsing
        var family: ?i32 = null;
        if (self.fd >= 0) {
            var storage: std.posix.sockaddr.storage = undefined;
            var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
            _ = std.os.linux.getsockname(self.fd, @ptrCast(&storage), &addrlen);
            family = storage.family;
        }

        sd.address = try utils.Address.fromPyAddr(py_addr, family);
        sd.msg.name = &sd.address.any;
        sd.msg.namelen = sd.address.getOsSockLen();
    }

    _ = try loop_data.io.queue(.{
        .PerformSendMsg = .{
            .fd = self.fd,
            .msg = &sd.msg,
            .callback = .{
                .func = &sendto_completed,
                .cleanup = &cleanup_sendto,
                .data = .{
                    .user_data = sd,
                    .module_ptr = @ptrCast(self),
                    .callback_ptr = null,
                },
            },
            .flags = 0,
        },
    });
    python_c.py_incref(@ptrCast(self));

    try buffer_watermark_check(self, len);
    return python_c.get_py_none();
}

fn write_completed(data: *const CallbackManager.CallbackData) !void {
    const self: *DatagramTransport.DatagramTransportObject = @alignCast(@ptrCast(data.user_data.?));
    if (data.cancelled or self.closed) return;
    if (data.io_uring_err != .SUCCESS) {
        if (self.protocol_error_received) |er| {
            const exc = python_c.PyObject_CallFunction(
                python_c.PyExc_OSError, "Ls", @as(c_long, @intFromEnum(data.io_uring_err)), "Write error"
            ) orelse return error.PythonError;
            defer python_c.py_decref(exc);
            const r = python_c.PyObject_CallOneArg(er, exc) orelse return error.PythonError;
            python_c.py_decref(r);
        }
        return;
    }

    const written: usize = @intCast(@max(data.io_uring_res, 0));
    if (self.buffer_size >= written) {
        self.buffer_size -= written;
    } else {
        self.buffer_size = 0;
    }

    if (!self.is_writing and self.buffer_size <= self.writing_low_water_mark) {
        self.is_writing = true;
        if (self.protocol) |proto| {
            const rw = python_c.PyObject_GetAttrString(proto, "resume_writing") orelse return error.PythonError;
            defer python_c.py_decref(rw);
            const r = python_c.PyObject_CallNoArgs(rw) orelse return error.PythonError;
            python_c.py_decref(r);
        }
    }
}

pub fn z_datagram_set_write_buffer_limits(self: *DatagramTransport.DatagramTransportObject, args: []?PyObject) !?PyObject {
    if (args.len < 1) return error.InvalidArgs;
    const py_high = args[0].?;
    const py_low: ?PyObject = if (args.len > 1 and args[1] != null and !python_c.is_none(args[1].?)) args[1].? else null;

    const high = @as(usize, @intCast(python_c.PyLong_AsUnsignedLongLong(py_high)));
    const low: usize = if (py_low) |l| @as(usize, @intCast(python_c.PyLong_AsUnsignedLongLong(l))) else high / 4;
    self.writing_high_water_mark = high;
    self.writing_low_water_mark = @min(low, high);
    return python_c.get_py_none();
}
