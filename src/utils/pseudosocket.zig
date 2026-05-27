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
    _ = self;
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

const PseudoSocketMethods = [_]python_c.PyMethodDef{
    .{ .ml_name = "fileno\x00", .ml_meth = @ptrCast(&pseudosocket_fileno), .ml_flags = python_c.METH_NOARGS, .ml_doc = "Return the file descriptor\x00" },
    .{ .ml_name = "getsockname\x00", .ml_meth = @ptrCast(&pseudosocket_getsockname), .ml_flags = python_c.METH_NOARGS, .ml_doc = "Return the socket name\x00" },
    .{ .ml_name = "getpeername\x00", .ml_meth = @ptrCast(&pseudosocket_getpeername), .ml_flags = python_c.METH_NOARGS, .ml_doc = "Return the peer name\x00" },
    .{ .ml_name = "setblocking\x00", .ml_meth = @ptrCast(&pseudosocket_setblocking), .ml_flags = python_c.METH_O, .ml_doc = "Set blocking mode (no-op)\x00" },
    .{ .ml_name = "close\x00", .ml_meth = @ptrCast(&pseudosocket_close), .ml_flags = python_c.METH_NOARGS, .ml_doc = "Close the socket (no-op)\x00" },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null }
};

const PseudoSocketGetSet = [_]python_c.PyGetSetDef{
    .{ .name = "family\x00", .get = @ptrCast(&pseudosocket_get_family), .set = null, .doc = "Socket family\x00", .closure = null },
    .{ .name = "type\x00", .get = @ptrCast(&pseudosocket_get_type), .set = null, .doc = "Socket type\x00", .closure = null },
    .{ .name = "proto\x00", .get = @ptrCast(&pseudosocket_get_proto), .set = null, .doc = "Socket protocol\x00", .closure = null },
    .{ .name = null, .get = null, .set = null, .doc = null, .closure = null }
};

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

