const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");
const CallbackManager = @import("callback_manager");

const Loop = @import("../../../main.zig");
const LoopObject = Loop.Python.LoopObject;
const Future = @import("../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;

const GetAddrInfoData = struct {
    future: *FutureObject,
    loop: *LoopObject,
    host: []u8,
    port: u16,
    family: i32,
    socket_type: i32,
    proto: i32,
    allocator: std.mem.Allocator,

    comptime {
        python_c.verify_gc_coverage(@This(), &.{ "allocator", "host" });
    }
};

fn getaddrinfo_callback(data: *const CallbackManager.CallbackData) !void {
    const gaid: *GetAddrInfoData = @alignCast(@ptrCast(data.user_data.?));
    defer {
        python_c.py_decref(@ptrCast(gaid.future));
        python_c.py_decref(@ptrCast(gaid.loop));
        gaid.allocator.free(gaid.host);
        gaid.allocator.destroy(gaid);
    }
    const loop_data = utils.get_data_ptr(Loop, gaid.loop);
    
    if (data.cancelled()) {
        return;
    }

    const address_list = try loop_data.dns.lookup(gaid.host, null) orelse {
        // This shouldn't happen if we are called back after Resolv.queue
        const exc = python_c.PyObject_CallFunction(python_c.PyExc_RuntimeError, "s\x00", "Failed to resolve host\x00") orelse return error.PythonError;
        defer python_c.py_decref(exc);
        const future_data = utils.get_data_ptr(Future, gaid.future);
        try Future.Python.Result.future_fast_set_exception(gaid.future, future_data, exc);
        return;
        }
;

    const py_tuple = try build_result_tuple(address_list, gaid.port, gaid.family, gaid.socket_type, gaid.proto);
    defer python_c.py_decref(py_tuple);

    const future_data = utils.get_data_ptr(Future, gaid.future);
    try Future.Python.Result.future_fast_set_result(future_data, py_tuple);
}

fn build_result_tuple(address_list: []const utils.Address, port: u16, family_filter: i32, socket_type: i32, proto: i32) !PyObject {
    var filtered_count: usize = 0;
    for (address_list) |addr| {
        if (family_filter != 0 and addr.any.family != family_filter) continue;
        filtered_count += 1;
    }

    const py_tuple = python_c.PyTuple_New(@intCast(filtered_count)) orelse return error.PythonError;
    errdefer python_c.py_decref(py_tuple);
    
    var idx: usize = 0;
    for (address_list) |addr| {
        if (family_filter != 0 and addr.any.family != family_filter) continue;

        const sockaddr = try utils.Address.toPyAddrWithPort(addr, port);
        defer python_c.py_decref(sockaddr);

        const py_family = python_c.PyLong_FromLong(addr.any.family) orelse return error.PythonError;
        defer python_c.py_decref(py_family);

        const py_type = python_c.PyLong_FromLong(if (socket_type != 0) socket_type else std.posix.SOCK.STREAM) orelse return error.PythonError;
        defer python_c.py_decref(py_type);

        const py_proto = python_c.PyLong_FromLong(proto) orelse return error.PythonError;
        defer python_c.py_decref(py_proto);

        const entry = python_c.PyTuple_Pack(5,
            py_family,
            py_type,
            py_proto,
            python_c.get_py_none_without_incref(),
            sockaddr,
        ) orelse return error.PythonError;
        
        if (python_c.PyTuple_SetItem(py_tuple, @intCast(idx), entry) != 0) {
            python_c.py_decref(entry);
            return error.PythonError;
        }
        idx += 1;
    }
    return py_tuple;
}

inline fn z_loop_getaddrinfo(self: *LoopObject, args: []const ?PyObject, knames: ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (args.len < 1) {
        python_c.raise_python_value_error("host argument is required\x00");
        return error.PythonError;
    }
    const py_host = args[0].?;
    var py_port: ?PyObject = null;
    if (args.len > 1) py_port = args[1].?;

    var py_family: ?PyObject = null;
    var py_type: ?PyObject = null;
    var py_proto: ?PyObject = null;
    var py_flags: ?PyObject = null;
    try python_c.parse_vector_call_kwargs(
        knames, @constCast(args.ptr + args.len),
        &.{ "family", "type", "proto", "flags" },
        &.{ &py_family, &py_type, &py_proto, &py_flags },
    );

    const port: u16 = blk: {
        if (py_port) |p| {
            if (python_c.is_none(p)) break :blk 0;
            const v = python_c.PyLong_AsInt(p);
            if (v == -1 and python_c.PyErr_Occurred() != null) return error.PythonError;
            break :blk @intCast(v);
        }
        break :blk 0;
    };

    const family: i32 = if (py_family) |f| @intCast(python_c.PyLong_AsLong(f)) else 0;
    const socket_type: i32 = if (py_type) |t| @intCast(python_c.PyLong_AsLong(t)) else 0;
    const proto: i32 = if (py_proto) |pr| @intCast(python_c.PyLong_AsLong(pr)) else 0;

    const loop_data = utils.get_data_ptr(Loop, self);
    const alloc = loop_data.allocator;
    const fut = try Future.Python.Constructors.fast_new_future(self);
    errdefer python_c.py_decref(@ptrCast(fut));

    var c_size: python_c.Py_ssize_t = 0;
    const ptr = python_c.PyUnicode_AsUTF8AndSize(py_host, &c_size) orelse return error.PythonError;
    const host_str = try alloc.dupe(u8, ptr[0..@intCast(c_size)]);
    errdefer alloc.free(host_str);

    const gaid = try alloc.create(GetAddrInfoData);
    errdefer alloc.destroy(gaid);
    gaid.* = .{
        .future = @ptrCast(python_c.py_newref(@as(*python_c.PyObject, @ptrCast(fut)))),
        .loop = python_c.py_newref(self),
        .host = host_str,
        .port = port,
        .family = family,
        .socket_type = socket_type,
        .proto = proto,
        .allocator = alloc,
    };

    const callback = CallbackManager.Callback{
        .func = &getaddrinfo_callback,
        .cleanup = null,
        .data = .{ .user_data = gaid },
    };
    
    const address_list = try loop_data.dns.lookup(host_str, &callback);
    if (address_list) |al| {
        // Result was in cache
        const py_res = try build_result_tuple(al, port, family, socket_type, proto);
        defer python_c.py_decref(py_res);
        const future_data = utils.get_data_ptr(Future, fut);
        try Future.Python.Result.future_fast_set_result(future_data, py_res);
        
        // Cleanup gaid and host_str since callback won't be called
        python_c.py_decref(@ptrCast(gaid.future));
        python_c.py_decref(@ptrCast(gaid.loop));
        alloc.free(host_str);
        alloc.destroy(gaid);
    }

    return fut;
}

pub fn loop_getaddrinfo(
    self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t, knames: ?PyObject
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_getaddrinfo, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames },
    );
}
