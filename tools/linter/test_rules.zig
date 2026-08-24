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

fn checkSnippet(
    gpa: std.mem.Allocator,
    file_path: []const u8,
    source: [:0]const u8,
    check_fn: anytype,
) !usize {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var ast = try std.zig.Ast.parse(arena, source, .zig);
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
