const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");
const CallbackManager = @import("callback_manager");

const Loop = @import("../../../main.zig");
const LoopObject = Loop.Python.LoopObject;
const Future = @import("../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;
const Parsers = @import("../../../dns/parsers.zig");

const GetNameInfoData = struct {
    future: *FutureObject,
    loop: *LoopObject,
    addr: utils.Address,
    flags: i32,
    allocator: std.mem.Allocator,

    comptime {
        python_c.verify_gc_coverage(@This(), &.{ "allocator" });
    }
};

fn getnameinfo_callback(data: *const CallbackManager.CallbackData) !void {
    const gnid: *GetNameInfoData = @alignCast(@ptrCast(data.user_data.?));
    defer {
        python_c.py_decref(@ptrCast(gnid.future));
        python_c.py_decref(@ptrCast(gnid.loop));
        gnid.allocator.destroy(gnid);
    }
    const loop_data = utils.get_data_ptr(Loop, gnid.loop);
    
    if (data.cancelled()) {
        return;
    }

    var buf: [128]u8 = undefined;
    const rev_name = try Parsers.build_reverse_name(gnid.addr, &buf);
    const cache_slot = loop_data.dns.get_cache_slot(rev_name);
    const record = cache_slot.get(rev_name) orelse {
        const exc = python_c.PyObject_CallFunction(python_c.PyExc_RuntimeError, "s\x00", "Failed to resolve name\x00") orelse return error.PythonError;
        defer python_c.py_decref(exc);
        const future_data = utils.get_data_ptr(Future, gnid.future);
        try Future.Python.Result.future_fast_set_exception(gnid.future, future_data, exc);
        return;
    };


    const hostname = switch (record.state) {
        .ptr => |name| name,
        else => {
            const exc = python_c.PyObject_CallFunction(python_c.PyExc_RuntimeError, "s\x00", "Reverse DNS failed\x00") orelse return error.PythonError;
            defer python_c.py_decref(exc);
            const future_data = utils.get_data_ptr(Future, gnid.future);
            try Future.Python.Result.future_fast_set_exception(gnid.future, future_data, exc);
            return;
        },
    };

    const py_host = python_c.PyUnicode_FromStringAndSize(hostname.ptr, @intCast(hostname.len)) orelse return error.PythonError;
    defer python_c.py_decref(py_host);
    const py_port = python_c.PyLong_FromLong(@intCast(gnid.addr.getPort())) orelse return error.PythonError;
    defer python_c.py_decref(py_port);
    
    const py_res = python_c.PyTuple_Pack(2, py_host, py_port) orelse return error.PythonError;
    defer python_c.py_decref(py_res);

    const future_data = utils.get_data_ptr(Future, gnid.future);
    try Future.Python.Result.future_fast_set_result(future_data, py_res);
}

inline fn z_loop_getnameinfo(self: *LoopObject, args: []const ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (args.len < 1) {
        python_c.raise_python_value_error("sockaddr argument is required\x00");
        return error.PythonError;
    }
    const py_addr = args[0].?;
    const flags: i32 = if (args.len > 1) @intCast(python_c.PyLong_AsLong(args[1].?)) else 0;

    const addr = try utils.Address.fromPyAddr(py_addr, null);

    const loop_data = utils.get_data_ptr(Loop, self);
    const alloc = loop_data.allocator;
    const fut = try Future.Python.Constructors.fast_new_future(self);
    errdefer python_c.py_decref(@ptrCast(fut));

    const gnid = try alloc.create(GetNameInfoData);
    errdefer alloc.destroy(gnid);
    gnid.* = .{
        .future = @ptrCast(python_c.py_newref(@as(*python_c.PyObject, @ptrCast(fut)))),
        .loop = python_c.py_newref(self),
        .addr = addr,
        .flags = flags,
        .allocator = alloc,
    };

    const callback = CallbackManager.Callback{
        .func = &getnameinfo_callback,
        .cleanup = null,
        .data = .{ .user_data = gnid },
    };
    
    try loop_data.dns.reverse_lookup(addr, &callback);

    return fut;
}

pub fn loop_getnameinfo(
    self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_getnameinfo, .{ self.?, args.?[0..@as(usize, @intCast(nargs))] },
    );
}
