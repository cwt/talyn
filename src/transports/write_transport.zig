const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const Loop = @import("../loop/main.zig");
const CallbackManager = @import("callback_manager");
const utils = @import("utils");

const BuffersArrayList = std.ArrayList(std.posix.iovec_const);
const PyBuffersArrayList = std.ArrayList(python_c.Py_buffer);

pub const WriteCompletedCallback = *const fn (*WriteTransport, usize, usize, std.os.linux.E) anyerror!void;
const ConnectionLostCallback = *const fn (PyObject, PyObject) anyerror!void;

const ExceptionMessage: [:0]const u8 = "Failed to complete write operation on transport";
const ModuleName: [:0]const u8 = "transport";

loop: *Loop,
parent_transport: PyObject,
exception_handler: PyObject,

connection_lost_callback: ?ConnectionLostCallback,

write_completed_callback: WriteCompletedCallback,

pending_buffers: *BuffersArrayList,
pending_py_buffers: *PyBuffersArrayList,
pending_buffer_index: usize = 0,
pending_buffer_offset: usize = 0,
buffer_size: usize = 0,

fd: std.posix.fd_t,

write_in_flight: bool = false,
zero_copying: bool,

prepare_hook_node: ?Loop.HooksList.Node = null,

total_bytes_written: usize = 0,
writev_count: usize = 0,

is_closing: bool = false,
closed: bool = false,
initialized: bool = false,
fixed_file_index: ?u16 = null,


pub fn init(
    self: *WriteTransport, loop: *Loop, fd: std.posix.fd_t,
    callback: WriteCompletedCallback, parent_transport: PyObject,
    exception_handler: PyObject, connection_lost_callback: ConnectionLostCallback,
    zero_copying: bool
) !void {
    const allocator = loop.allocator;

    const pending_buffers = try allocator.create(BuffersArrayList);
    errdefer allocator.destroy(pending_buffers);

    const pending_py_objects = try allocator.create(PyBuffersArrayList);
    errdefer allocator.destroy(pending_py_objects);

    pending_buffers.* = .{ .items = &.{}, .capacity = 0 };
    pending_py_objects.* = .{ .items = &.{}, .capacity = 0 };

    self.* = WriteTransport{
        .loop = loop,
        .parent_transport = parent_transport,
        .exception_handler = exception_handler,

        .connection_lost_callback = connection_lost_callback,

        .write_completed_callback = callback,

        .pending_buffers = pending_buffers,
        .pending_py_buffers = pending_py_objects,

        .fd = fd,
        .zero_copying = zero_copying,
        .initialized = true,
    };

    self.prepare_hook_node = try loop.add_hook(.prepare, .{
        .func = &flush_buffered_writes,
        .cleanup = null,
        .data = .{ .user_data = self },
    });
}

fn flush_buffered_writes(data: *const CallbackManager.CallbackData) !void {
    if (data.cancelled()) return;
    const self: *WriteTransport = @alignCast(@ptrCast(data.user_data.?));
    if (!self.write_in_flight and self.buffer_size > 0) {
        try self.submit_next_chunk();
    }
}

pub fn close(self: *WriteTransport) !void {
    if (self.is_closing or self.closed) return;

    self.is_closing = true;
    self.connection_lost_callback = null;

    if (!self.write_in_flight and self.buffer_size == 0) {
        self.closed = true;
        const StreamLifecycle = @import("stream/lifecycle.zig");
        StreamLifecycle.maybe_close_fd(@ptrCast(self.parent_transport));
    }
}

pub fn force_close(self: *WriteTransport) !void {
    if (self.closed) return;
    self.closed = true;
    self.is_closing = true;
    self.connection_lost_callback = null;

    const StreamLifecycle = @import("stream/lifecycle.zig");
    StreamLifecycle.maybe_close_fd(@ptrCast(self.parent_transport));
}

pub fn deinit(self: *WriteTransport) void {
    if (!self.initialized) return;

    if (self.loop.initialized) {
        if (self.prepare_hook_node) |node| {
            self.loop.remove_hook(.prepare, node);
            self.prepare_hook_node = null;
        }
    }

    const allocator = self.loop.allocator;

    for (self.pending_py_buffers.items) |*v| {
        python_c.PyBuffer_Release(v);
    }

    self.pending_buffers.deinit(allocator);
    self.pending_py_buffers.deinit(allocator);

    allocator.destroy(self.pending_buffers);
    allocator.destroy(self.pending_py_buffers);

    self.initialized = false;
}

fn submit_next_chunk(self: *WriteTransport) !void {
    if (self.write_in_flight) return;
    if (self.pending_buffer_index >= self.pending_buffers.items.len) {
        // All buffers consumed — but buffer_size > 0 means partial buffer left.
        // This shouldn't happen if partial writes are tracked correctly.
        self.write_in_flight = false;
        return;
    }

    const iov = self.pending_buffers.items[self.pending_buffer_index];
    const offset = self.pending_buffer_offset;
    const remaining = iov.len - offset;
    if (remaining == 0) {
        // Advance to next buffer
        self.pending_buffer_index += 1;
        self.pending_buffer_offset = 0;
        return self.submit_next_chunk();
    }

    const data_slice: []const u8 = @as([*]const u8, @ptrCast(iov.base))[offset..][0..remaining];

    _ = try self.loop.io.queue(.{
        .PerformWrite = .{
            .callback = .{
                .func = &write_operation_completed,
                .cleanup = &cleanup_resources_callback,
                .data = .{
                    .user_data = self,
                },
            },
            .fd = self.fd,
            .fixed_file_index = self.fixed_file_index,
            .data = data_slice,
            .zero_copy = false,
        },
    });
    _ = try self.loop.io.flush_pending_sqes();

    self.writev_count += 1;
    self.write_in_flight = true;
}

fn cleanup_resources_callback(ptr: ?*anyopaque) void {
    const self: *WriteTransport = @alignCast(@ptrCast(ptr.?));
    python_c.py_decref(self.parent_transport);
}

fn write_operation_completed(data: *const CallbackManager.CallbackData) !void {
    const self: *WriteTransport = @alignCast(@ptrCast(data.user_data.?));
    if (data.cancelled()) {
        python_c.py_decref(self.parent_transport);
        return;
    }

    const io_uring_res = data.io_uring_res();
    const io_uring_err = data.io_uring_err();
    self.write_in_flight = false;

    if (io_uring_res > 0) {
        const written = @as(usize, @intCast(io_uring_res));
        self.buffer_size -= @min(written, self.buffer_size);
        self.total_bytes_written += written;

        // Advance the current buffer position by bytes written
        const iov = self.pending_buffers.items[self.pending_buffer_index];
        const iov_remaining = iov.len - self.pending_buffer_offset;
        if (written < iov_remaining) {
            // Partial write — advance offset within current buffer
            self.pending_buffer_offset += written;
        } else {
            // Full buffer consumed
            self.pending_buffer_index += 1;
            self.pending_buffer_offset = 0;
            // Release the consumed buffer's Py_buffer
            if (self.pending_buffer_index - 1 < self.pending_py_buffers.items.len) {
                python_c.PyBuffer_Release(&self.pending_py_buffers.items[self.pending_buffer_index - 1]);
            }
        }
    }

    if (io_uring_err != .SUCCESS and io_uring_err != .CANCELED) {
        // Real error — report via connection_lost
        if (!self.is_closing) {
            var exception: PyObject = undefined;
            exception = python_c.PyObject_CallFunction(
                python_c.PyExc_OSError, "Ls\x00", @as(c_long, @intFromEnum(io_uring_err)),
                "Write operation failed\x00"
            ) orelse return error.PythonError;

            defer {
                self.is_closing = true;
                self.closed = true;
                const StreamLifecycle = @import("stream/lifecycle.zig");
                StreamLifecycle.maybe_close_fd(@ptrCast(self.parent_transport));
                python_c.py_decref(exception);
            }

            if (self.connection_lost_callback) |callback| {
                try callback(self.parent_transport, exception);
            }
            return;
        }
        return;
    }

    // Check if more data needs to be written
    if (self.buffer_size > 0) {
        try self.submit_next_chunk();
    } else {
        // All data written — clean up consumed buffers
        // Release any remaining Py_buffers (at the current index and beyond)
        for (self.pending_py_buffers.items[self.pending_buffer_index..]) |*v| {
            python_c.PyBuffer_Release(v);
        }
        self.pending_buffers.clearRetainingCapacity();
        self.pending_py_buffers.clearRetainingCapacity();
        self.pending_buffer_index = 0;
        self.pending_buffer_offset = 0;

        if (self.is_closing) {
            self.closed = true;
            const StreamLifecycle = @import("stream/lifecycle.zig");
            StreamLifecycle.maybe_close_fd(@ptrCast(self.parent_transport));
        }

        const bw = self.total_bytes_written;
        self.total_bytes_written = 0;
        _ = self.write_completed_callback(self, bw, 0, .SUCCESS) catch |err| {
            utils.handle_zig_function_error(err, {});
            const exception = python_c.PyErr_GetRaisedException()
                orelse return error.PythonError;

            defer {
                self.is_closing = true;
                self.closed = true;
                const StreamLifecycle = @import("stream/lifecycle.zig");
                StreamLifecycle.maybe_close_fd(@ptrCast(self.parent_transport));
                python_c.PyErr_SetRaisedException(exception);
            }

            if (self.connection_lost_callback) |callback| {
                try callback(self.parent_transport, exception);
            }
            return error.PythonError;
        };
    }
}

pub fn append_new_buffer_to_write(self: *WriteTransport, py_object: PyObject) !usize {
    if (self.closed) {
        return error.TransportClosed;
    }

    const new_buffer_size: usize = blk: {
        var pbuffer: python_c.Py_buffer = undefined;
        if (python_c.PyObject_GetBuffer(py_object, &pbuffer, 0) < 0) {
            return error.PythonError;
        }
        errdefer python_c.PyBuffer_Release(&pbuffer);

        if (pbuffer.len <= 0) {
            python_c.PyBuffer_Release(&pbuffer);
            return self.buffer_size;
        }

        const buffer_len: usize = @intCast(pbuffer.len);

        try self.pending_py_buffers.append(self.loop.allocator, pbuffer);
        errdefer _ = self.pending_py_buffers.pop();

        try self.pending_buffers.append(self.loop.allocator, .{
            .base = @ptrCast(pbuffer.buf.?),
            .len = buffer_len
        });

        break :blk self.buffer_size + buffer_len;
    };
    self.buffer_size = new_buffer_size;

    return new_buffer_size;
}

pub fn queue_eof(self: *WriteTransport) !void {
    if (self.buffer_size > 0) return;

    try self.close();

    _ = try self.loop.io.queue(.{
        .SocketShutdown = .{
            .socket_fd = self.fd,
            .how = std.os.linux.SHUT.WR
        }
    });
}

const WriteTransport = @This();
