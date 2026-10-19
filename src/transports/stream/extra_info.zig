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

    // Use PseudoSocket instead of real socket
    const py_sock = try utils.PseudoSocket.fast_new_pseudosocket(self.fd, self.family, std.posix.SOCK.STREAM, 0);

    self.socket = @ptrCast(py_sock);
    return @ptrCast(py_sock);
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
        } else {
            result = try create_socket_instance(self);
            python_c.py_incref(result);
        }
    } else if (std.mem.eql(u8, name, "peername")) {
        if (self.peername) |py_peername| {
            result = python_c.py_newref(py_peername);
        } else {
            var socket: PyObject = undefined;
            if (self.socket) |py_sock| {
                socket = py_sock;
            } else {
                socket = try create_socket_instance(self);
            }

            const getpeername_func = python_c.PyObject_GetAttrString(socket, "getpeername\x00") orelse return error.PythonError;
            defer python_c.py_decref(getpeername_func);

            result = python_c.PyObject_CallNoArgs(getpeername_func) orelse return error.PythonError;
            self.peername = python_c.py_newref(result);
        }
    } else if (std.mem.eql(u8, name, "sockname")) {
        if (self.sockname) |py_sockname| {
            result = python_c.py_newref(py_sockname);
        } else {
            var socket: PyObject = undefined;
            if (self.socket) |py_sock| {
                socket = py_sock;
            } else {
                socket = try create_socket_instance(self);
            }

            const getsockname_func = python_c.PyObject_GetAttrString(socket, "getsockname\x00") orelse return error.PythonError;
            defer python_c.py_decref(getsockname_func);

            result = python_c.PyObject_CallNoArgs(getsockname_func) orelse return error.PythonError;
            self.sockname = python_c.py_newref(result);
        }
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
