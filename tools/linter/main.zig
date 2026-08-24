const std = @import("std");
const Diagnostic = @import("diagnostic.zig").Diagnostic;

// Rules
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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const w = &stdout_writer.interface;

    try w.print("\x1b[1;35m==> Talyn Offline Bug Hunter & AST Linter (v0.9.6-dev)\x1b[0m\n", .{});
    try w.flush();

    const arena = init.arena.allocator();
    const start_time = std.Io.Clock.awake.now(io);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(arena);

    var total_zig_files: usize = 0;
    var total_ast_nodes: usize = 0;

    // Scan src/
    if (std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true })) |src_dir_val| {
        var src_dir = src_dir_val;
        defer src_dir.close(io);

        var walker = try src_dir.walk(gpa);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

            total_zig_files += 1;

            const full_path = try std.fmt.allocPrint(arena, "src/{s}", .{entry.path});

            const content = try src_dir.readFileAlloc(io, entry.path, gpa, .limited(10 * 1024 * 1024));
            defer gpa.free(content);

            const null_terminated = try gpa.allocSentinel(u8, content.len, 0);
            defer gpa.free(null_terminated);
            @memcpy(null_terminated, content);

            var ast = try std.zig.Ast.parse(gpa, null_terminated, .zig);
            defer ast.deinit(gpa);

            total_ast_nodes += ast.nodes.len;

            // Run Zig AST rule checkers
            try no_cimport.check(&ast, full_path, arena, &diagnostics);
            try no_panic_in_io.check(&ast, full_path, arena, &diagnostics);
            try no_empty_catch.check(&ast, full_path, arena, &diagnostics);
            try unmanaged_containers.check(&ast, full_path, arena, &diagnostics);
            try no_bare_switch_else.check(&ast, full_path, arena, &diagnostics);
            try syscall_safety.check(&ast, full_path, arena, &diagnostics);
            try no_spinlock_yield.check(&ast, full_path, arena, &diagnostics);
            try gc_type_clear.check(&ast, full_path, arena, &diagnostics);
            try missing_errdefer_after_future.check(&ast, full_path, arena, &diagnostics);
            try missing_tp_alloc_pyobject_init.check(&ast, full_path, arena, &diagnostics);
            try unparsed_pyobject_kwarg.check(&ast, full_path, arena, &diagnostics);
            try no_forced_optional_pyobject_unwrap.check(&ast, full_path, arena, &diagnostics);
            try no_ptr_from_int_task_id.check(&ast, full_path, arena, &diagnostics);
        }
    } else |err| {
        try w.print("Failed to open 'src' directory: {t}\n", .{err});
        try w.flush();
    }

    // Also scan the linter's own source to practice what it preaches
    if (std.Io.Dir.cwd().openDir(io, "tools/linter", .{ .iterate = true })) |linter_dir_val| {
        var linter_dir = linter_dir_val;
        defer linter_dir.close(io);

        var walker = try linter_dir.walk(gpa);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            if (std.mem.startsWith(u8, entry.path, "test") or std.mem.indexOf(u8, entry.path, "test") != null) continue;

            total_zig_files += 1;

            const full_path = try std.fmt.allocPrint(arena, "tools/linter/{s}", .{entry.path});

            const content = try linter_dir.readFileAlloc(io, entry.path, gpa, .limited(10 * 1024 * 1024));
            defer gpa.free(content);

            const null_terminated = try gpa.allocSentinel(u8, content.len, 0);
            defer gpa.free(null_terminated);
            @memcpy(null_terminated, content);

            var ast = try std.zig.Ast.parse(gpa, null_terminated, .zig);
            defer ast.deinit(gpa);

            total_ast_nodes += ast.nodes.len;

            try no_cimport.check(&ast, full_path, arena, &diagnostics);
            try no_panic_in_io.check(&ast, full_path, arena, &diagnostics);
            try no_empty_catch.check(&ast, full_path, arena, &diagnostics);
            try unmanaged_containers.check(&ast, full_path, arena, &diagnostics);
            try no_bare_switch_else.check(&ast, full_path, arena, &diagnostics);
            try syscall_safety.check(&ast, full_path, arena, &diagnostics);
            try no_spinlock_yield.check(&ast, full_path, arena, &diagnostics);
            try gc_type_clear.check(&ast, full_path, arena, &diagnostics);
            try missing_errdefer_after_future.check(&ast, full_path, arena, &diagnostics);
            try missing_tp_alloc_pyobject_init.check(&ast, full_path, arena, &diagnostics);
            try unparsed_pyobject_kwarg.check(&ast, full_path, arena, &diagnostics);
            try no_forced_optional_pyobject_unwrap.check(&ast, full_path, arena, &diagnostics);
            try no_ptr_from_int_task_id.check(&ast, full_path, arena, &diagnostics);
        }
    } else |err| {
        try w.print("Failed to open 'tools/linter' directory: {t}\n", .{err});
        try w.flush();
    }

    // Print Zig AST diagnostics
    for (diagnostics.items) |diag| {
        try diag.print(io, gpa);
    }

    const end_time = std.Io.Clock.awake.now(io);
    const elapsed_ns = start_time.durationTo(end_time).toNanoseconds();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    if (diagnostics.items.len == 0) {
        try w.print("\x1b[1;32m[OK] Scanned {d} Zig files ({d} AST nodes) in {d:.2}ms: 0 violations found.\x1b[0m\n", .{
            total_zig_files,
            total_ast_nodes,
            elapsed_ms,
        });
    } else {
        try w.print("\x1b[1;31m[FAILED] Found {d} policy violations across {d} Zig files in {d:.2}ms.\x1b[0m\n", .{
            diagnostics.items.len,
            total_zig_files,
            elapsed_ms,
        });
    }
    try w.flush();

    // Run Python AST rules
    var py_child = try std.process.spawn(io, .{
        .argv = &.{ "python3", "tools/linter/rules/python_rules.py" },
    });
    const term = try py_child.wait(io);

    var has_py_errors = false;
    switch (term) {
        .exited => |code| {
            if (code != 0) has_py_errors = true;
        },
        else => has_py_errors = true,
    }

    if (diagnostics.items.len > 0 or has_py_errors) {
        std.process.exit(1);
    }
}
