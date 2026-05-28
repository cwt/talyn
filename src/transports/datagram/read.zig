const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const utils = @import("utils");
const CallbackManager = @import("callback_manager");
const Loop = @import("../../loop/main.zig");
const DatagramTransport = @import("main.zig");

const MAX_DGRAM: usize = 65536;

pub fn queue_read(self: *DatagramTransport.DatagramTransportObject) !void {
    if (self.closed or self.fd < 0) return;

    const loop_data = utils.get_data_ptr(Loop, @as(*Loop.Python.LoopObject, @ptrCast(self.loop.?)));
    const alloc = loop_data.allocator;

    const rd = try alloc.create(ReadData);
    errdefer alloc.destroy(rd);

    rd.* = .{
        .transport = self,
        .alloc = alloc,
        .msg = undefined,
        .iov = undefined,
        .addr = undefined,
    };

    rd.iov = .{ .base = self.buffer_ptr.?, .len = self.buffer_len };
    rd.msg = .{
        .name = @ptrCast(&rd.addr),
        .namelen = @sizeOf(std.posix.sockaddr.storage),
        .iov = @ptrCast(&rd.iov),
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    const ffi = if (self.fixed_file_index != 0) self.fixed_file_index else null;

    _ = try loop_data.io.queue(.{
        .PerformRecvMsg = .{
            .fd = self.fd,
            .fixed_file_index = ffi,
            .msg = &rd.msg,
            .callback = .{
                .func = &read_completed,
                .cleanup = &cleanup_read,
                .data = .{
                    .user_data = rd,
                },
            },
            .flags = 0,
        },
    });
    python_c.py_incref(@ptrCast(self));
}

const ReadData = struct {
    transport: *DatagramTransport.DatagramTransportObject,
    alloc: std.mem.Allocator,
    msg: std.posix.msghdr,
    iov: std.posix.iovec,
    addr: std.posix.sockaddr.storage,
};

fn cleanup_read(ptr: ?*anyopaque) void {
    const rd: *ReadData = @ptrCast(@alignCast(ptr.?));
    const transport = rd.transport;
    python_c.py_decref(@ptrCast(transport));
    rd.alloc.destroy(rd);
}

fn read_completed(data: *const CallbackManager.CallbackData) !void {
    const rd: *ReadData = @alignCast(@ptrCast(data.user_data.?));
    defer cleanup_read(@ptrCast(@alignCast(rd)));

    const self = rd.transport;
    if (data.cancelled() or self.closed) return;

    const io_uring_err = data.io_uring_err();
    if (io_uring_err != .SUCCESS) {
        // Error — notify protocol and re-arm
        if (self.protocol_error_received) |er| {
            const exc = python_c.PyObject_CallFunction(
                python_c.PyExc_OSError, "Ls", @as(c_long, @intFromEnum(io_uring_err)), "Read error"
            ) orelse return error.PythonError;
            defer python_c.py_decref(exc);
            const r = python_c.PyObject_CallOneArg(er, exc) orelse return error.PythonError;
            python_c.py_decref(r);
        }
        try queue_read(self);
        return;
    }

    const nread: usize = @intCast(@max(data.io_uring_res(), 0));
    if (nread == 0) {
        // Empty datagram — re-arm
        try queue_read(self);
        return;
    }

    // Deliver data to protocol
    if (self.protocol_datagram_received) |dr| {
        const py_data = python_c.PyBytes_FromStringAndSize(self.buffer_ptr.?, @intCast(nread)) orelse return error.PythonError;
        defer python_c.py_decref(py_data);
        
        // Format source address using universal helper
        const addr = blk: {
            if (rd.msg.namelen == 0) break :blk null;
            const storage: *const std.posix.sockaddr.storage = &rd.addr;
            switch (storage.family) {
                std.posix.AF.INET => {
                    const sa: *const std.posix.sockaddr.in = @ptrCast(storage);
                    break :blk utils.Address.toPyAddr(utils.Address.initIp4(@as([4]u8, @bitCast(sa.addr)), std.mem.bigToNative(u16, sa.port))) catch null;
                },
                std.posix.AF.INET6 => {
                    const sa: *const std.posix.sockaddr.in6 = @ptrCast(storage);
                    break :blk utils.Address.toPyAddr(utils.Address.initIp6(sa.addr, std.mem.bigToNative(u16, sa.port), sa.flowinfo, sa.scope_id)) catch null;
                },
                else => break :blk null,
            }
        };
        const py_addr = addr orelse python_c.get_py_none();
        defer python_c.py_decref(py_addr);

        const args = python_c.PyTuple_Pack(2, py_data, py_addr) orelse return error.PythonError;
        defer python_c.py_decref(args);
        const r = python_c.PyObject_CallObject(dr, args) orelse return error.PythonError;
        python_c.py_decref(r);
    }

    // Re-arm read
    try queue_read(self);
}
