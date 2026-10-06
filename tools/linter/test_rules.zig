const std = @import("std");
const Diagnostic = @import("diagnostic.zig").Diagnostic;

const no_cimport = @import("rules/no_cimport.zig");
const no_panic_in_io = @import("rules/no_panic_in_io.zig");
const no_empty_catch = @import("rules/no_empty_catch.zig");
const unmanaged_containers = @import("rules/unmanaged_containers.zig");
const no_bare_switch_else = @import("rules/no_bare_switch_else.zig");
const syscall_safety = @import("rules/syscall_safety.zig");
const no_spinlock_yield = @import("rules/no_spinlock_yield.zig");
const gc_type_clear = @import("rules/gc_type_clear.zig");
const missing_errdefer_after_future = @import("rules/missing_errdefer_after_future.zig");
const missing_tp_alloc_pyobject_init = @import("rules/missing_tp_alloc_pyobject_init.zig");
const unparsed_pyobject_kwarg = @import("rules/unparsed_pyobject_kwarg.zig");
const no_forced_optional_pyobject_unwrap = @import("rules/no_forced_optional_pyobject_unwrap.zig");
const no_ptr_from_int_task_id = @import("rules/no_ptr_from_int_task_id.zig");
const method_flags_missing_keywords = @import("rules/method_flags_missing_keywords.zig");
const stale_cancel_bulk = @import("rules/stale_cancel_bulk.zig");
const clear_before_python = @import("rules/clear_before_python.zig");
const timer_io_mixing = @import("rules/timer_io_mixing.zig");

fn checkSnippet(
    gpa: std.mem.Allocator,
    file_path: []const u8,
    source: [:0]const u8,
    check_fn: anytype,
) !usize {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var ast = if (@hasDecl(std.zig.Ast, "ParseOptions"))
        try std.zig.Ast.parse(arena, source, .{})
    else
        try std.zig.Ast.parse(arena, source, .zig);
    defer ast.deinit(arena);

    var diags: std.ArrayList(Diagnostic) = .empty;
    defer diags.deinit(arena);

    try check_fn(&ast, file_path, arena, &diags);
    return diags.items.len;
}

test "TALYN-001: no @cImport" {
    const diags = try checkSnippet(std.testing.allocator, "src/foo.zig",
        \\const c = @cImport({ @cInclude("stdio.h"); });
    , no_cimport.check);
    try std.testing.expectEqual(@as(usize, 1), diags);
}

test "TALYN-002: no @panic in IO path" {
    const diags1 = try checkSnippet(std.testing.allocator, "src/loop/foo.zig",
        \\fn bad() void {
        \\    @panic("bad");
        \\}
    , no_panic_in_io.check);
    try std.testing.expectEqual(@as(usize, 1), diags1);

    const diags2 = try checkSnippet(std.testing.allocator, "src/loop/foo.zig",
        \\fn bad() void {
        \\    panic("bad");
        \\}
    , no_panic_in_io.check);
    try std.testing.expectEqual(@as(usize, 1), diags2);
}

test "TALYN-003: no empty catch" {
    const diags = try checkSnippet(std.testing.allocator, "src/foo.zig",
        \\fn bad() void {
        \\    foo() catch {};
        \\}
    , no_empty_catch.check);
    try std.testing.expectEqual(@as(usize, 1), diags);
}

test "TALYN-004: unmanaged containers" {
    const diags = try checkSnippet(std.testing.allocator, "src/foo.zig",
        \\const map = std.AutoHashMap(u32, u32).init(allocator);
    , unmanaged_containers.check);
    try std.testing.expectEqual(@as(usize, 1), diags);
}

test "TALYN-005: no bare switch else" {
    const diags = try checkSnippet(std.testing.allocator, "src/foo.zig",
        \\fn bad(x: u32) void {
        \\    switch (x) {
        \\        1 => {},
        \\        else => {},
        \\    }
        \\}
    , no_bare_switch_else.check);
    try std.testing.expectEqual(@as(usize, 1), diags);
}

test "TALYN-006: syscall safety (discarded getsockname)" {
    const diags = try checkSnippet(std.testing.allocator, "src/foo.zig",
        \\fn bad(fd: i32) void {
        \\    _ = std.os.linux.getsockname(fd, undefined, undefined);
        \\}
    , syscall_safety.check);
    try std.testing.expectEqual(@as(usize, 1), diags);
}

test "TALYN-007: no spinlock yield" {
    const diags1 = try checkSnippet(std.testing.allocator, "src/foo.zig",
        \\fn bad() void {
        \\    std.Thread.yield();
        \\}
    , no_spinlock_yield.check);
    try std.testing.expectEqual(@as(usize, 1), diags1);

    const diags2 = try checkSnippet(std.testing.allocator, "src/foo.zig",
        \\fn bad() void {
        \\    Thread.yield();
        \\}
    , no_spinlock_yield.check);
    try std.testing.expectEqual(@as(usize, 1), diags2);
}

test "TALYN-008: GC type requires tp_clear" {
    const diags = try checkSnippet(std.testing.allocator, "src/foo.zig",
        \\const flags = Py_TPFLAGS_HAVE_GC;
    , gc_type_clear.check);
    try std.testing.expectEqual(@as(usize, 1), diags);
}

test "TALYN-009: missing errdefer after fast_new_future" {
    const diags = try checkSnippet(std.testing.allocator, "src/foo.zig",
        \\fn make_fut() !*Future {
        \\    const fut = try fast_new_future(loop);
        \\    try step2();
        \\    return fut;
        \\}
    , missing_errdefer_after_future.check);
    try std.testing.expectEqual(@as(usize, 1), diags);
}

test "TALYN-010: uninitialized PyObject field after tp_alloc" {
    const diags = try checkSnippet(std.testing.allocator, "src/foo.zig",
        \\const MyType = struct {
        \\    py_callback: ?*PyObject,
        \\};
        \\fn alloc() !void {
        \\    const obj = tp_alloc();
        \\}
    , missing_tp_alloc_pyobject_init.check);
    try std.testing.expectEqual(@as(usize, 1), diags);
}

test "TALYN-011: unparsed PyObject kwarg" {
    const diags = try checkSnippet(std.testing.allocator, "src/foo.zig",
        \\const Options = struct {
        \\    py_timeout: ?PyObject,
        \\    py_unhandled: ?PyObject,
        \\};
        \\fn parse() void {
        \\    parse_vector_call_kwargs(&py_timeout);
        \\}
    , unparsed_pyobject_kwarg.check);
    try std.testing.expectEqual(@as(usize, 1), diags);
}

test "TALYN-012: forced .? on nullable protocol field in IO path" {
    // Should flag: .? on a known protocol field
    const diags_bad = try checkSnippet(std.testing.allocator, "src/transports/stream/read.zig",
        \\const ret = PyObject_CallNoArgs(transport.protocol_eof_received.?);
    , no_forced_optional_pyobject_unwrap.check);
    try std.testing.expectEqual(@as(usize, 1), diags_bad);

    // Should NOT flag: safe capture with |func|
    const diags_ok = try checkSnippet(std.testing.allocator, "src/transports/stream/read.zig",
        \\if (transport.protocol_eof_received) |func| {
        \\    _ = PyObject_CallNoArgs(func);
        \\}
    , no_forced_optional_pyobject_unwrap.check);
    try std.testing.expectEqual(@as(usize, 0), diags_ok);

    // Should NOT flag: .? on an unguarded field name
    const diags_unguarded = try checkSnippet(std.testing.allocator, "src/transports/stream/read.zig",
        \\const x = transport.some_other_field.?;
    , no_forced_optional_pyobject_unwrap.check);
    try std.testing.expectEqual(@as(usize, 0), diags_unguarded);

    // Should NOT flag: outside IO path
    const diags_outside = try checkSnippet(std.testing.allocator, "tools/other/helper.zig",
        \\const ret = foo.protocol_eof_received.?;
    , no_forced_optional_pyobject_unwrap.check);
    try std.testing.expectEqual(@as(usize, 0), diags_outside);
}

test "TALYN-013: @ptrFromInt(task_id) in IO path" {
    // Should flag: ptrFromInt on a task_id identifier
    const diags_bad = try checkSnippet(std.testing.allocator, "src/loop/scheduling/io/cancel.zig",
        \\const task: *BlockingTask = @ptrFromInt(task_id);
    , no_ptr_from_int_task_id.check);
    try std.testing.expectEqual(@as(usize, 1), diags_bad);

    // Should NOT flag: ptrFromInt on an unrelated identifier
    const diags_ok = try checkSnippet(std.testing.allocator, "src/loop/scheduling/io/cancel.zig",
        \\const ptr: *Foo = @ptrFromInt(raw_ptr);
    , no_ptr_from_int_task_id.check);
    try std.testing.expectEqual(@as(usize, 0), diags_ok);

    // Should NOT flag: outside IO path
    const diags_outside = try checkSnippet(std.testing.allocator, "scripts/gen.zig",
        \\const task: *BlockingTask = @ptrFromInt(task_id);
    , no_ptr_from_int_task_id.check);
    try std.testing.expectEqual(@as(usize, 0), diags_outside);
}

test "TALYN-014: METH_FASTCALL without METH_KEYWORDS" {
    // Should flag: multi-line table entry, FASTCALL only
    const diags_bad = try checkSnippet(std.testing.allocator, "src/loop/python/main.zig",
        \\const M = [_]PyMethodDef{
        \\    .{ .ml_name = "sock_connect\x00", .ml_flags = python_c.METH_FASTCALL },
        \\};
    , method_flags_missing_keywords.check);
    try std.testing.expectEqual(@as(usize, 1), diags_bad);

    // Should flag: single-line table entry, FASTCALL only
    const diags_single = try checkSnippet(std.testing.allocator, "src/transports/datagram/main.zig",
        \\const M = [_]PyMethodDef{ .{ .ml_name = "sendto\x00", .ml_flags = python_c.METH_FASTCALL } };
    , method_flags_missing_keywords.check);
    try std.testing.expectEqual(@as(usize, 1), diags_single);

    // Should NOT flag: METH_KEYWORDS present
    const diags_ok = try checkSnippet(std.testing.allocator, "src/loop/python/main.zig",
        \\const M = [_]PyMethodDef{
        \\    .{ .ml_name = "getaddrinfo\x00", .ml_flags = python_c.METH_FASTCALL | python_c.METH_KEYWORDS },
        \\};
    , method_flags_missing_keywords.check);
    try std.testing.expectEqual(@as(usize, 0), diags_ok);

    // Should NOT flag: exemption marker on the line above
    const diags_exempt = try checkSnippet(std.testing.allocator, "src/loop/python/main.zig",
        \\const M = [_]PyMethodDef{
        \\    // TALYN-014-EXEMPT: internal API, no CPython counterpart
        \\    .{ .ml_name = "_add_hook\x00", .ml_flags = python_c.METH_FASTCALL },
        \\};
    , method_flags_missing_keywords.check);
    try std.testing.expectEqual(@as(usize, 0), diags_exempt);

    // Should NOT flag: no PyMethodDef table in file
    const diags_unrelated = try checkSnippet(std.testing.allocator, "src/utils/main.zig",
        \\const flags = METH_FASTCALL;
    , method_flags_missing_keywords.check);
    try std.testing.expectEqual(@as(usize, 0), diags_unrelated);
}

test "TALYN-016: bulk CancelIO over task_ids without removal" {
    // Should flag: bulk cancel with no swapRemove/removeTaskId/fetchRemove
    const diags_bad = try checkSnippet(std.testing.allocator, "src/loop/foo.zig",
        \\fn deinit(self: *Mcs) void {
        \\    for (self.task_ids.items) |task_id| {
        \\        _ = queue(.{ .CancelIO = task_id }) catch continue;
        \\    }
        \\}
    , stale_cancel_bulk.check);
    try std.testing.expectEqual(@as(usize, 1), diags_bad);

    // Should NOT flag: fixed pattern with removal helper present
    const diags_ok = try checkSnippet(std.testing.allocator, "src/loop/foo.zig",
        \\fn removeTaskId(mcs: *Mcs, task_id: usize) void {
        \\    for (mcs.task_ids.items, 0..) |id, idx| {
        \\        if (id == task_id) {
        \\            _ = mcs.task_ids.swapRemove(idx);
        \\            return;
        \\        }
        \\    }
        \\}
        \\fn deinit(self: *Mcs) void {
        \\    for (self.task_ids.items) |task_id| {
        \\        _ = queue(.{ .CancelIO = task_id }) catch continue;
        \\    }
        \\}
    , stale_cancel_bulk.check);
    try std.testing.expectEqual(@as(usize, 0), diags_ok);
}

test "TALYN-017: clear ID before Python in completion callback" {
    // Should flag: Python call while ID field still holds the completed ID
    const diags_bad = try checkSnippet(std.testing.allocator, "src/transports/streamserver/main.zig",
        \\fn accept_callback(data: *const CallbackData) !void {
        \\    const server: *Server = @ptrCast(@alignCast(data.user_data.?));
        \\    const id = server.blocking_task_id;
        \\    const protocol = PyObject_CallNoArgs(protocol_factory) orelse return error.PythonError;
        \\    _ = protocol;
        \\    _ = id;
        \\}
    , clear_before_python.check);
    try std.testing.expectEqual(@as(usize, 1), diags_bad);

    // Should NOT flag: removeTaskId release before Python (fixed BUG-336 pattern)
    const diags_fixed = try checkSnippet(std.testing.allocator, "src/loop/python/io/client/create_connection.zig",
        \\fn socket_connected_callback(data: *const CallbackData) !void {
        \\    const completed_id = socket_data.task_id;
        \\    removeTaskId(mcs, completed_id);
        \\    const exc = PyObject_CallFunction(err, msg) orelse return error.PythonError;
        \\    _ = exc;
        \\}
    , clear_before_python.check);
    try std.testing.expectEqual(@as(usize, 0), diags_fixed);

    // Should NOT flag: ID cleared before Python (safe reference)
    const diags_ok = try checkSnippet(std.testing.allocator, "src/loop/python/io/watchers.zig",
        \\fn loop_watchers_callback(data: *const CallbackData) !void {
        \\    const watcher: *Watcher = @ptrCast(@alignCast(data.user_data.?));
        \\    watcher.blocking_task_id = 0;
        \\    try Soon.dispatch(loop_data, &callback);
        \\}
    , clear_before_python.check);
    try std.testing.expectEqual(@as(usize, 0), diags_ok);

    // Should NOT flag: no Python call in function
    const diags_no_py = try checkSnippet(std.testing.allocator, "src/loop/fs_watcher.zig",
        \\fn deinit(self: *FSWatcher) void {
        \\    if (self.inotify_task_id > 0) {
        \\        _ = self.loop.io.queue(.{ .CancelIO = self.inotify_task_id }) catch continue;
        \\        self.inotify_task_id = 0;
        \\    }
        \\}
    , clear_before_python.check);
    try std.testing.expectEqual(@as(usize, 0), diags_no_py);
}

test "TALYN-018: timer ID mixed into task_ids list" {
    // Should flag: task_ids append + WaitTimer without happy_timer_id separation
    const diags_bad = try checkSnippet(std.testing.allocator, "src/loop/foo.zig",
        \\fn submit(mcs: *Mcs) !void {
        \\    const timer_id = try queue(.{ .WaitTimer = .{ .duration = d } });
        \\    try mcs.task_ids.append(allocator, timer_id);
        \\}
    , timer_io_mixing.check);
    try std.testing.expectEqual(@as(usize, 1), diags_bad);

    // Should NOT flag: fixed pattern with happy_timer_id separation
    const diags_ok = try checkSnippet(std.testing.allocator, "src/loop/python/io/client/create_connection.zig",
        \\fn submit(mcs: *Mcs) !void {
        \\    const timer_task_id = try queue(.{ .WaitTimer = .{ .duration = d } });
        \\    mcs.happy_timer_id = timer_task_id;
        \\    try mcs.task_ids.append(allocator, task_id);
        \\}
    , timer_io_mixing.check);
    try std.testing.expectEqual(@as(usize, 0), diags_ok);
}
