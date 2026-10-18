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
const Resolv = @import("../../../dns/resolv.zig");

const GetNameInfoData = struct {
    future: *FutureObject,
    loop: *LoopObject,
    addr: utils.Address,
    flags: i32,
    allocator: std.mem.Allocator,

    comptime {
        python_c.verify_gc_coverage(@This(), &.{"allocator"});
    }
};

/// BUG-357: resolve a still-pending future with an exception (see
/// getaddrinfo.zig for rationale).
fn resolve_future_error(future: *FutureObject, msg: [:0]const u8) !void {
    const future_data = utils.get_data_ptr(Future, future);
    if (future_data.status != .pending) return;
    if (python_c.PyErr_Occurred() == null) {
        const exc = python_c.PyObject_CallFunction(python_c.PyExc_RuntimeError, "s\x00", msg.ptr) orelse return error.PythonError;
        defer python_c.py_decref(exc);
        try Future.Python.Result.future_fast_set_exception(future, future_data, exc);
        return;
    }
    const pending = python_c.PyErr_GetRaisedException() orelse return;
    defer python_c.py_decref(pending);
    try Future.Python.Result.future_fast_set_exception(future, future_data, pending);
}

fn getnameinfo_callback(data: *const CallbackManager.CallbackData) !void {
    const gnid: *GetNameInfoData = @ptrCast(@alignCast(data.user_data.?));
    defer {
        python_c.py_decref(@ptrCast(gnid.future));
        python_c.py_decref(@ptrCast(gnid.loop));
        gnid.allocator.destroy(gnid);
    }
    const loop_data = utils.get_data_ptr(Loop, gnid.loop);

    if (data.cancelled()) {
        // BUG-357: resolve the future instead of leaving the awaiter
        // hanging forever.
        try resolve_future_error(gnid.future, "DNS resolution cancelled\x00");
        return;
    }

    var buf: [128]u8 = undefined;
    const rev_name = Parsers.build_reverse_name(gnid.addr, &buf) catch |err| {
        try resolve_future_error(gnid.future, "Failed to build reverse name\x00");
        return err;
    };
    const cache_slot = loop_data.dns.get_cache_slot(rev_name);
    const record = cache_slot.get(rev_name) orelse {
        try resolve_future_error(gnid.future, "Failed to resolve name\x00");
        return;
    };

    const hostname = switch (record.state) {
        .ptr => |name| name,
        else => {
            try resolve_future_error(gnid.future, "Reverse DNS failed\x00");
            return;
        },
    };

    const py_host = python_c.PyUnicode_FromStringAndSize(hostname.ptr, @intCast(hostname.len)) orelse {
        try resolve_future_error(gnid.future, "Failed to build nameinfo result\x00");
        return error.PythonError;
    };
    defer python_c.py_decref(py_host);
    const py_port = python_c.PyLong_FromLong(@intCast(gnid.addr.getPort())) orelse {
        try resolve_future_error(gnid.future, "Failed to build nameinfo result\x00");
        return error.PythonError;
    };
    defer python_c.py_decref(py_port);

    const py_res = python_c.PyTuple_Pack(2, py_host, py_port) orelse {
        try resolve_future_error(gnid.future, "Failed to build nameinfo result\x00");
        return error.PythonError;
    };
    defer python_c.py_decref(py_res);

    const future_data = utils.get_data_ptr(Future, gnid.future);
    try Future.Python.Result.future_fast_set_result(future_data, py_res);
}

inline fn z_loop_getnameinfo(self: *LoopObject, args: []const ?PyObject, knames: ?PyObject) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;

    var merged: [3]?PyObject = undefined;
    try python_c.merge_vector_call_args(args, knames, &.{ "sockaddr", "flags", "dns_timeout" }, &merged);
    if (merged[0] == null) {
        python_c.raise_python_value_error("sockaddr argument is required\x00");
        return error.PythonError;
    }
    const py_addr = merged[0].?;
    const flags: i32 = if (merged[1]) |py_flags| blk: {
        const v = python_c.PyLong_AsLong(py_flags);
        if (python_c.PyErr_Occurred() != null) return error.PythonError;
        break :blk @intCast(v);
    } else 0;

    const addr = try utils.Address.fromPyAddr(py_addr, null);

    const dns_timeout = blk: {
        if (merged[2]) |pt| {
            break :blk try Resolv.parse_dns_timeout(pt);
        } else break :blk null;
    };

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
    errdefer {
        python_c.py_decref(@ptrCast(gnid.future));
        python_c.py_decref(@ptrCast(gnid.loop));
    }

    const callback = CallbackManager.Callback{
        .func = &getnameinfo_callback,
        .cleanup = null,
        .data = .{ .user_data = gnid },
    };

    try loop_data.dns.reverse_lookup(addr, &callback, dns_timeout);

    return fut;
}

pub fn loop_getnameinfo(self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t, knames: ?PyObject) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_getnameinfo,
        .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames },
    );
}
