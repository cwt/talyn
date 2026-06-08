const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const DatagramTransport = @import("main.zig");
const utils = @import("utils");

pub fn z_datagram_get_extra_info(self: *DatagramTransport.DatagramTransportObject, py_name: ?PyObject) !?PyObject {
    const name_obj = py_name orelse {
        python_c.raise_python_value_error("name argument is required");
        return error.PythonError;
    };
    var c_size: python_c.Py_ssize_t = 0;
    const name_ptr = python_c.PyUnicode_AsUTF8AndSize(name_obj, &c_size) orelse return error.PythonError;
    const name = name_ptr[0..@intCast(c_size)];

    if (std.mem.eql(u8, name, "socket")) {
        if (self.fd < 0) return python_c.get_py_none();
        const socket_module = utils.PythonImports.socket_module;
        const fromfd = python_c.PyObject_GetAttrString(socket_module, "fromfd") orelse return error.PythonError;
        defer python_c.py_decref(fromfd);
        const py_fd = python_c.PyLong_FromLong(@intCast(self.fd)) orelse return error.PythonError;
        defer python_c.py_decref(py_fd);
        const fam = python_c.PyLong_FromLong(2) orelse return error.PythonError;
        defer python_c.py_decref(fam);
        const typ = python_c.PyLong_FromLong(2) orelse return error.PythonError;
        defer python_c.py_decref(typ);
        const args = python_c.PyTuple_Pack(3, py_fd, fam, typ) orelse return error.PythonError;
        defer python_c.py_decref(args);
        return python_c.PyObject_CallObject(fromfd, args);
    }

    if (std.mem.eql(u8, name, "sockname")) {
        if (self.fd < 0) return python_c.get_py_none();
        var storage: std.posix.sockaddr.storage = undefined;
        var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
        _ = std.os.linux.getsockname(self.fd, @ptrCast(&storage), &addrlen);
        const address = switch (storage.family) {
            std.posix.AF.INET => blk: {
                const sa: *align(1) const std.posix.sockaddr.in = @ptrCast(&storage);
                break :blk utils.Address.initIp4(@as([4]u8, @bitCast(sa.addr)), std.mem.bigToNative(u16, sa.port));
            },
            std.posix.AF.INET6 => blk: {
                const sa: *align(1) const std.posix.sockaddr.in6 = @ptrCast(&storage);
                break :blk utils.Address.initIp6(sa.addr, std.mem.bigToNative(u16, sa.port), sa.flowinfo, sa.scope_id);
            },
            else => return python_c.get_py_none(),
        };
        return utils.Address.toPyAddr(address);
    }

    return python_c.get_py_none();
}
