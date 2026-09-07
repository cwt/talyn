const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const DatagramTransport = @import("main.zig");
const utils = @import("utils");

pub fn z_datagram_get_extra_info(self: *DatagramTransport.DatagramTransportObject, args: []?PyObject, knames: ?PyObject) !?PyObject {
    if (args.len < 1) {
        python_c.raise_python_type_error("get_extra_info() missing required argument 'name'");
        return error.PythonError;
    }
    if (args.len > 2) {
        python_c.raise_python_type_error("get_extra_info() takes at most 2 positional arguments");
        return error.PythonError;
    }

    // BUG-320: accept the standard asyncio signature (name, default=None)
    // including the default= keyword.
    var kw_default: ?PyObject = null;
    try python_c.parse_vector_call_kwargs(knames, args.ptr + args.len, &.{"default\x00"}, &.{&kw_default});
    defer python_c.py_xdecref(kw_default);

    const default_obj: PyObject = if (kw_default) |d|
        d
    else if (args.len >= 2)
        args[1].?
    else
        python_c.get_py_none(); // owned None reference; the extra incref below is harmless (immortal)

    const name_obj = args[0].?;
    var c_size: python_c.Py_ssize_t = 0;
    const name_ptr = python_c.PyUnicode_AsUTF8AndSize(name_obj, &c_size) orelse return error.PythonError;
    const name = name_ptr[0..@intCast(c_size)];

    if (std.mem.eql(u8, name, "socket")) {
        if (self.fd < 0) return python_c.get_py_none();
        // BUG-320: query the actual socket family - the hardcoded AF_INET
        // (2) returned a wrong-family socket object for IPv6/UNIX datagram
        // transports.
        var storage: std.posix.sockaddr.storage = undefined;
        var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
        const rc = std.os.linux.getsockname(self.fd, @ptrCast(&storage), &addrlen);
        const family: i32 = if (utils.getSyscallErrno(rc) == .SUCCESS)
            @intCast(storage.family)
        else
            std.posix.AF.INET;
        const socket_module = utils.PythonImports.get("socket_module");
        const fromfd = python_c.PyObject_GetAttrString(socket_module, "fromfd") orelse return error.PythonError;
        defer python_c.py_decref(fromfd);
        const py_fd = python_c.PyLong_FromLong(@intCast(self.fd)) orelse return error.PythonError;
        defer python_c.py_decref(py_fd);
        const fam = python_c.PyLong_FromLong(family) orelse return error.PythonError;
        defer python_c.py_decref(fam);
        const typ = python_c.PyLong_FromLong(std.posix.SOCK.DGRAM) orelse return error.PythonError;
        defer python_c.py_decref(typ);
        const fargs = python_c.PyTuple_Pack(3, py_fd, fam, typ) orelse return error.PythonError;
        defer python_c.py_decref(fargs);
        return python_c.PyObject_CallObject(fromfd, fargs);
    }

    if (std.mem.eql(u8, name, "sockname")) {
        if (self.fd < 0) return python_c.get_py_none();
        var storage: std.posix.sockaddr.storage = undefined;
        var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
        const rc = std.os.linux.getsockname(self.fd, @ptrCast(&storage), &addrlen);
        // BUG-326: raw-syscall errno decoding; std.posix.errno mis-decoded
        // failures as SUCCESS and this read the uninitialized storage.
        if (utils.getSyscallErrno(rc) != .SUCCESS) return python_c.get_py_none();
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

    // BUG-320: unknown keys return the caller-provided default (standard
    // asyncio behaviour) instead of always Py_None.
    return python_c.py_newref(default_obj);
}
