const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const Loop = @import("../../loop/main.zig");

const Stream = @import("main.zig");
const StreamTransportObject = Stream.StreamTransportObject;

fn create_socket_instance(self: *StreamTransportObject) !PyObject {
    const loop_obj: *Loop.Python.LoopObject = @ptrCast(self.loop.?);
    const loop_data = utils.get_data_ptr(Loop, loop_obj);
    _ = loop_data;

    // Use PseudoSocket instead of real socket.
    // BUG-427 / BUG-447: the pseudo-socket used to alias the transport's
    // raw fd. Whichever side closed first, the other side later closed the
    // same descriptor number — by then possibly reused by an unrelated
    // socket (transport teardown closing the app's `sock.close()` number,
    // or the app close dangling the transport's). dup() gives each side
    // its own descriptor; both directions of the hazard are closed, and
    // option/name operations keep working through the shared file
    // description.
    const dup_ret = std.os.linux.dup(self.fd);
    if (@as(isize, @bitCast(dup_ret)) < 0) {
        python_c.raise_python_value_error("get_extra_info('socket'): fd dup failed\x00");
        return error.PythonError;
    }
    const dup_fd: std.posix.fd_t = @intCast(dup_ret);
    const py_sock = utils.PseudoSocket.fast_new_pseudosocket(dup_fd, self.family, std.posix.SOCK.STREAM, 0) catch {
        _ = std.os.linux.close(dup_fd);
        return error.PythonError;
    };

    self.socket = @ptrCast(py_sock);
    return @ptrCast(py_sock);
}

/// BUG-427 / BUG-447: transport-owned teardown of the cached pseudo-socket.
/// The pseudo-socket owns a dup of the transport fd; when the transport
/// tears down, both descriptors must go away and the object must become
/// inert, so a later app close() is a no-op and can never target a reused
/// number (and RST/FIN semantics keep firing on the last close, matching
/// the single-fd behavior).
pub fn invalidate_socket(self: *StreamTransportObject) void {
    if (self.socket) |sock_obj| {
        const sock: *utils.PseudoSocket.PseudoSocketObject = @ptrCast(@alignCast(sock_obj));
        utils.PseudoSocket.invalidate_and_close(sock);
    }
}

fn get_or_query_sockaddr(
    self: *StreamTransportObject,
    cached: *?PyObject,
    method_name: [:0]const u8,
    default_value: PyObject,
) !PyObject {
    if (cached.*) |py_val| {
        return python_c.py_newref(py_val);
    }
    if (self.fd < 0) {
        return python_c.py_newref(default_value);
    }
    const socket = self.socket orelse try create_socket_instance(self);
    const func = python_c.PyObject_GetAttrString(socket, method_name.ptr) orelse return error.PythonError;
    defer python_c.py_decref(func);

    const result = python_c.PyObject_CallNoArgs(func) orelse return error.PythonError;
    cached.* = python_c.py_newref(result);
    return result;
}

inline fn z_transport_get_extra_info(self: *StreamTransportObject, args: []?PyObject, knames: ?PyObject) !PyObject {
    if (args.len < 1) {
        python_c.raise_python_type_error("get_extra_info() missing required argument 'name'");
        return error.PythonError;
    }
    if (args.len > 2) {
        python_c.raise_python_type_error("get_extra_info() takes at most 2 positional arguments");
        return error.PythonError;
    }

    const info_name = args[0].?;
    var kw_default: ?PyObject = null;

    try python_c.parse_vector_call_kwargs(knames, args.ptr + args.len, &.{"default\x00"}, &.{&kw_default});
    defer python_c.py_xdecref(kw_default);

    if (kw_default != null and args.len >= 2) {
        python_c.raise_python_type_error("get_extra_info() got multiple values for argument 'default'");
        return error.PythonError;
    }

    const default_value: PyObject = if (kw_default) |d|
        d
    else if (args.len >= 2)
        args[1].?
    else
        python_c.get_py_none();

    var info_name_length: python_c.Py_ssize_t = undefined;
    const name_ptr: [*]const u8 = python_c.PyUnicode_AsUTF8AndSize(info_name, &info_name_length) orelse return error.PythonError;

    var result: PyObject = undefined;

    const name = name_ptr[0..@intCast(info_name_length)];
    if (std.mem.eql(u8, name, "socket")) {
        if (self.socket) |py_sock| {
            result = python_c.py_newref(py_sock);
        } else if (self.fd < 0) {
            // BUG-427: transport already closed its fd before any caller
            // cached a PseudoSocket — return default instead of dup(-1).
            result = python_c.py_newref(default_value);
        } else {
            result = try create_socket_instance(self);
            python_c.py_incref(result);
        }
    } else if (std.mem.eql(u8, name, "peername")) {
        result = try get_or_query_sockaddr(self, &self.peername, "getpeername\x00", default_value);
    } else if (std.mem.eql(u8, name, "sockname")) {
        result = try get_or_query_sockaddr(self, &self.sockname, "getsockname\x00", default_value);
    } else if (std.mem.eql(u8, name, "writev_count")) {
        const write_transport = utils.get_data_ptr2(@import("../write_transport.zig"), "write_transport", self);
        result = python_c.PyLong_FromUnsignedLongLong(@intCast(write_transport.writev_count)) orelse return error.PythonError;
    } else {
        result = python_c.py_newref(default_value);
    }

    return result;
}

pub fn transport_get_extra_info(self: ?*StreamTransportObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject) callconv(.c) ?PyObject {
    if (nargs < 0) return null;
    var empty: [0]?PyObject = undefined;
    const actual_args = if (args) |a| a[0..@as(usize, @intCast(nargs))] else empty[0..];
    return utils.execute_zig_function(z_transport_get_extra_info, .{ self.?, actual_args, knames });
}
