const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

/// TALYN-013/NO_PTR_FROM_INT_TASK_ID
///
/// Flags any `@ptrFromInt(expr)` call where the argument is a simple
/// identifier whose name contains "task_id" (case-sensitive).
///
/// This is the syntactic pattern of BUG-290: casting a raw task-slot integer
/// back to a `*BlockingTask` pointer to read `task.operation` after the slot
/// may already have been returned to the free pool — an integer-to-pointer
/// use-after-free.  Task IDs must be passed as opaque u64 values to the
/// kernel; they must never be dereferenced as struct pointers.
///
/// AST layout (Zig 0.16):
///   builtin_call_two / builtin_call_two_comma →
///     nodeData().opt_node_and_opt_node: [2]Node.OptionalIndex (up to 2 args)
///   builtin_call / builtin_call_comma →
///     nodeData().extra_range: Node.SubRange of Node.Index slice
pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    const is_io_path = std.mem.indexOf(u8, file_path, "src/transports/") != null or
        std.mem.indexOf(u8, file_path, "src/loop/") != null or
        std.mem.indexOf(u8, file_path, "src/task/") != null or
        std.mem.indexOf(u8, file_path, "src/future/") != null or
        std.mem.indexOf(u8, file_path, "src/callback_manager.zig") != null;

    if (!is_io_path) return;

    const tags = ast.nodes.items(.tag);
    const main_tokens = ast.nodes.items(.main_token);

    for (0..ast.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(i);
        const tag = tags[i];

        const is_builtin = tag == .builtin_call_two or
            tag == .builtin_call_two_comma or
            tag == .builtin_call or
            tag == .builtin_call_comma;
        if (!is_builtin) continue;

        if (!std.mem.eql(u8, ast.tokenSlice(main_tokens[i]), "@ptrFromInt")) continue;

        if (tag == .builtin_call_two or tag == .builtin_call_two_comma) {
            const opt_lhs, const opt_rhs = ast.nodeData(node).opt_node_and_opt_node;
            if (opt_lhs.unwrap()) |arg| try flag_if_task_id(ast, arg, main_tokens[i], file_path, gpa, diagnostics);
            if (opt_rhs.unwrap()) |arg| try flag_if_task_id(ast, arg, main_tokens[i], file_path, gpa, diagnostics);
        } else {
            const arg_nodes = ast.extraDataSlice(ast.nodeData(node).extra_range, std.zig.Ast.Node.Index);
            for (arg_nodes) |arg| try flag_if_task_id(ast, arg, main_tokens[i], file_path, gpa, diagnostics);
        }
    }
}

fn flag_if_task_id(
    ast: *const std.zig.Ast,
    arg_node: std.zig.Ast.Node.Index,
    call_main_token: std.zig.Ast.TokenIndex,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (ast.nodes.items(.tag)[@intFromEnum(arg_node)] != .identifier) return;

    const arg_token = ast.nodes.items(.main_token)[@intFromEnum(arg_node)];
    const arg_name = ast.tokenSlice(arg_token);
    if (std.mem.indexOf(u8, arg_name, "task_id") == null) return;

    const loc = ast.tokenLocation(0, call_main_token);
    try diagnostics.append(gpa, .{
        .file_path = file_path,
        .line = loc.line + 1,
        .column = loc.column + 1,
        .rule_id = "TALYN-013/NO_PTR_FROM_INT_TASK_ID",
        .bug_ref = "BUG-290",
        .message = try std.fmt.allocPrint(
            gpa,
            "'@ptrFromInt({s})' casts a task slot integer back to a pointer.",
            .{arg_name},
        ),
        .risk = "The BlockingTask slot may have been returned to the free pool before Cancel.perform runs — integer-to-pointer use-after-free (UAF).",
        .fix = "Pass task_id as an opaque u64 to ring.cancel() / ring.timeout_remove(); never dereference it as a BlockingTask pointer.",
    });
}
