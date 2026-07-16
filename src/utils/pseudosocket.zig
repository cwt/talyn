const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const address_mod = @import("address.zig");
const Address = address_mod.Address;

pub const PseudoSocketObject = extern struct {
    ob_base: python_c.PyObject,
    fd: std.posix.fd_t,
    family: i32,
    type: i32,
    proto: i32,
};

fn pseudosocket_fileno(self: ?*PseudoSocketObject, _: ?PyObject) callconv(.c) ?PyObject {
    return python_c.PyLong_FromLong(self.?.fd);
}

fn pseudosocket_getsockname(self: ?*PseudoSocketObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    var addr: std.posix.sockaddr.storage = undefined;
    var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);

    _ = std.os.linux.getsockname(instance.fd, @ptrCast(&addr), &addrlen);
    if (addrlen == 0 or addr.family == 0) {
        python_c.raise_python_runtime_error("getsockname failed\x00");
        return null;
    }

    if (addr.family == std.posix.AF.UNIX) {
        if (addrlen <= @offsetOf(std.posix.sockaddr.un, "path")) {
            return python_c.PyUnicode_FromStringAndSize("", 0);
        }
        const un: *const std.posix.sockaddr.un = @ptrCast(&addr);
        const path = std.mem.span(@as([*:0]const u8, @ptrCast(&un.path)));
        return python_c.PyUnicode_FromStringAndSize(path.ptr, @intCast(path.len));
    }

    return Address.toPyAddr(Address.initPosix(@ptrCast(&addr))) catch {
        python_c.raise_python_runtime_error("Failed to convert address\x00");
        return null;
    };
}

fn pseudosocket_getpeername(self: ?*PseudoSocketObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    var addr: std.posix.sockaddr.storage = undefined;
    var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);

    std.posix.getpeername(instance.fd, @ptrCast(&addr), &addrlen) catch {
        python_c.raise_python_runtime_error("getpeername failed\x00");
        return null;
    };

    if (addr.family == std.posix.AF.UNIX) {
        if (addrlen <= @offsetOf(std.posix.sockaddr.un, "path")) {
            return python_c.PyUnicode_FromStringAndSize("", 0);
        }
        const un: *const std.posix.sockaddr.un = @ptrCast(&addr);
        const path = std.mem.span(@as([*:0]const u8, @ptrCast(&un.path)));
        return python_c.PyUnicode_FromStringAndSize(path.ptr, @intCast(path.len));
    }

    return Address.toPyAddr(Address.initPosix(@ptrCast(&addr))) catch {
        python_c.raise_python_runtime_error("Failed to convert address\x00");
        return null;
    };
}

fn pseudosocket_setblocking(self: ?*PseudoSocketObject, _: ?PyObject) callconv(.c) ?PyObject {
    _ = self;
    return python_c.get_py_none();
}

fn pseudosocket_close(self: ?*PseudoSocketObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    _ = std.os.linux.close(instance.fd);
    return python_c.get_py_none();
}

/// Apply a socket option by operating on the raw file descriptor. Libraries
/// such as aiohttp call sock.setsockopt(IPPROTO_TCP, TCP_NODELAY, ...) during
/// connection setup, which the previous no-op-free PseudoSocket did not
/// support. The option value may be an int or a bytes/bytearray buffer.
fn pseudosocket_setsockopt(self: ?*PseudoSocketObject, args: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    if (args == null) {
        python_c.raise_python_type_error("setsockopt() missing required arguments\x00");
        return null;
    }
    // Parse (level, optname, value) where value is int or buffer.
    const arg_tuple: *python_c.PyObject = @ptrCast(@constCast(args));
    if (python_c.PyTuple_Size(arg_tuple) < 3) {
        python_c.raise_python_type_error("setsockopt() requires (level, optname, value)\x00");
        return null;
    }
    const level: i32 = @intCast(python_c.PyLong_AsLong(python_c.PyTuple_GetItem(arg_tuple, 0)));
    const optname: u32 = @intCast(python_c.PyLong_AsLong(python_c.PyTuple_GetItem(arg_tuple, 1)));
    if (level < 0 or optname < 0) {
        python_c.raise_python_value_error("setsockopt() invalid level/optname\x00");
        return null;
    }
    const value_obj = python_c.PyTuple_GetItem(arg_tuple, 2);
    // Value may be an int or a bytes/bytearray buffer. Try int first;
    // if it is not a convertible integer, fall back to a bytes buffer.
    const long_val = python_c.PyLong_AsLong(value_obj);
    if (python_c.PyErr_Occurred() == null) {
        const value: c_int = @intCast(long_val);
        std.posix.setsockopt(instance.fd, level, optname, std.mem.asBytes(&value)) catch {
            python_c.raise_python_value_error("setsockopt() failed\x00");
            return null;
        };
        return python_c.get_py_none();
    }
    _ = python_c.PyErr_Clear();
    if (python_c.PyBytes_Check(value_obj) != 0) {
        const buf_ptr: [*]const u8 = @ptrCast(python_c.PyBytes_AsString(value_obj));
        const buf_len: usize = @intCast(python_c.PyBytes_Size(value_obj));
        std.posix.setsockopt(instance.fd, level, optname, buf_ptr[0..buf_len]) catch {
            python_c.raise_python_value_error("setsockopt() failed\x00");
            return null;
        };
        return python_c.get_py_none();
    }
    python_c.raise_python_type_error("setsockopt() value must be int or bytes\x00");
    return null;
}

fn pseudosocket_getsockopt(self: ?*PseudoSocketObject, args: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    const arg_tuple: *python_c.PyObject = @ptrCast(@constCast(args));
    const argc = if (args != null) python_c.PyTuple_Size(arg_tuple) else 0;
    if (argc < 2) {
        python_c.raise_python_type_error("getsockopt() requires (level, optname[, buflen])\x00");
        return null;
    }
    const level: i32 = @intCast(python_c.PyLong_AsLong(python_c.PyTuple_GetItem(arg_tuple, 0)));
    const optname: u32 = @intCast(python_c.PyLong_AsLong(python_c.PyTuple_GetItem(arg_tuple, 1)));
    if (level < 0 or optname < 0) {
        python_c.raise_python_value_error("getsockopt() invalid level/optname\x00");
        return null;
    }
    var buf: [256]u8 = undefined;
    var buflen: std.c.socklen_t = 256;
    if (argc >= 3) {
        const bl = python_c.PyLong_AsLong(python_c.PyTuple_GetItem(arg_tuple, 2));
        if (bl >= 0 and bl <= buf.len) buflen = @intCast(bl);
    }
    const rc = std.os.linux.getsockopt(instance.fd, level, optname, &buf, &buflen);
    if (rc != 0) {
        python_c.raise_python_value_error("getsockopt() failed\x00");
        return null;
    }
    // If the option fits in a single integer (typical for flags like
    // TCP_NODELAY), return it as an int; otherwise return the raw bytes.
    if (buflen == 4) {
        const int_val: i32 = @bitCast(buf[0..4].*);
        return python_c.PyLong_FromLong(@intCast(int_val));
    }
    return python_c.PyBytes_FromStringAndSize(@ptrCast(&buf), @intCast(buflen));
}

fn pseudosocket_settimeout(self: ?*PseudoSocketObject, args: ?PyObject) callconv(.c) ?PyObject {
    // Talyn manages timeouts at the loop level; accept the call for API
    // compatibility and return None.
    _ = self;
    _ = args;
    return python_c.get_py_none();
}

fn pseudosocket_gettimeout(self: ?*PseudoSocketObject, _: ?PyObject) callconv(.c) ?PyObject {
    _ = self;
    return python_c.get_py_none();
}

fn pseudosocket_getblocking(self: ?*PseudoSocketObject, _: ?PyObject) callconv(.c) ?PyObject {
    _ = self;
    return python_c.PyBool_FromLong(1);
}

fn pseudosocket_dup(self: ?*PseudoSocketObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    const new_fd = std.os.linux.dup(instance.fd);
    if (new_fd == @as(usize, @bitCast(@as(isize, -1)))) {
        python_c.raise_python_value_error("dup() failed\x00");
        return null;
    }
    return @ptrCast(fast_new_pseudosocket(@intCast(new_fd), instance.family, instance.type, instance.proto) catch {
        python_c.raise_python_value_error("dup() failed\x00");
        return null;
    });
}

fn pseudosocket_set_inheritable(self: ?*PseudoSocketObject, args: ?PyObject) callconv(.c) ?PyObject {
    _ = self;
    _ = args;
    return python_c.get_py_none();
}

fn pseudosocket_get_family(self: ?*PseudoSocketObject, _: ?*anyopaque) callconv(.c) ?PyObject {
    return python_c.PyLong_FromLong(self.?.family);
}

fn pseudosocket_get_type(self: ?*PseudoSocketObject, _: ?*anyopaque) callconv(.c) ?PyObject {
    return python_c.PyLong_FromLong(self.?.type);
}

fn pseudosocket_get_proto(self: ?*PseudoSocketObject, _: ?*anyopaque) callconv(.c) ?PyObject {
    return python_c.PyLong_FromLong(self.?.proto);
}

const PseudoSocketMethods = [_]python_c.PyMethodDef{ .{ .ml_name = "fileno\x00", .ml_meth = @ptrCast(&pseudosocket_fileno), .ml_flags = python_c.METH_NOARGS, .ml_doc = "Return the file descriptor\x00" }, .{ .ml_name = "getsockname\x00", .ml_meth = @ptrCast(&pseudosocket_getsockname), .ml_flags = python_c.METH_NOARGS, .ml_doc = "Return the socket name\x00" }, .{ .ml_name = "getpeername\x00", .ml_meth = @ptrCast(&pseudosocket_getpeername), .ml_flags = python_c.METH_NOARGS, .ml_doc = "Return the peer name\x00" }, .{ .ml_name = "setblocking\x00", .ml_meth = @ptrCast(&pseudosocket_setblocking), .ml_flags = python_c.METH_O, .ml_doc = "Set blocking mode (no-op)\x00" }, .{ .ml_name = "close\x00", .ml_meth = @ptrCast(&pseudosocket_close), .ml_flags = python_c.METH_NOARGS, .ml_doc = "Close the socket\x00" }, .{ .ml_name = "setsockopt\x00", .ml_meth = @ptrCast(&pseudosocket_setsockopt), .ml_flags = python_c.METH_VARARGS, .ml_doc = "Set a socket option\x00" }, .{ .ml_name = "getsockopt\x00", .ml_meth = @ptrCast(&pseudosocket_getsockopt), .ml_flags = python_c.METH_VARARGS, .ml_doc = "Get a socket option\x00" }, .{ .ml_name = "settimeout\x00", .ml_meth = @ptrCast(&pseudosocket_settimeout), .ml_flags = python_c.METH_O, .ml_doc = "Set timeout (no-op)\x00" }, .{ .ml_name = "gettimeout\x00", .ml_meth = @ptrCast(&pseudosocket_gettimeout), .ml_flags = python_c.METH_NOARGS, .ml_doc = "Return timeout (None)\x00" }, .{ .ml_name = "getblocking\x00", .ml_meth = @ptrCast(&pseudosocket_getblocking), .ml_flags = python_c.METH_NOARGS, .ml_doc = "Return blocking mode\x00" }, .{ .ml_name = "dup\x00", .ml_meth = @ptrCast(&pseudosocket_dup), .ml_flags = python_c.METH_NOARGS, .ml_doc = "Duplicate the socket\x00" }, .{ .ml_name = "set_inheritable\x00", .ml_meth = @ptrCast(&pseudosocket_set_inheritable), .ml_flags = python_c.METH_O, .ml_doc = "Set inheritable flag (no-op)\x00" }, .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null } };

const PseudoSocketGetSet = [_]python_c.PyGetSetDef{ .{ .name = "family\x00", .get = @ptrCast(&pseudosocket_get_family), .set = null, .doc = "Socket family\x00", .closure = null }, .{ .name = "type\x00", .get = @ptrCast(&pseudosocket_get_type), .set = null, .doc = "Socket type\x00", .closure = null }, .{ .name = "proto\x00", .get = @ptrCast(&pseudosocket_get_proto), .set = null, .doc = "Socket protocol\x00", .closure = null }, .{ .name = null, .get = null, .set = null, .doc = null, .closure = null } };

pub var PseudoSocketType = python_c.PyTypeObject{
    .tp_name = "talyn.PseudoSocket\x00",
    .tp_basicsize = @sizeOf(PseudoSocketObject),
    .tp_flags = python_c.Py_TPFLAGS_DEFAULT,
    .tp_methods = @constCast(&PseudoSocketMethods),
    .tp_getset = @constCast(&PseudoSocketGetSet),
};

pub fn fast_new_pseudosocket(fd: std.posix.fd_t, family: i32, socket_type: i32, proto: i32) !*PseudoSocketObject {
    if (python_c.PyType_Ready(&PseudoSocketType) < 0) return error.PythonError;
    const instance: *PseudoSocketObject = @ptrCast(PseudoSocketType.tp_alloc.?(&PseudoSocketType, 0) orelse return error.PythonError);
    instance.fd = fd;
    instance.family = family;
    instance.type = socket_type;
    instance.proto = proto;
    return instance;
}
