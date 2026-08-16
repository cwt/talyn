const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    // Only enforce strictly on runtime execution paths, not standalone test files
    const is_io_path = std.mem.indexOf(u8, file_path, "src/loop/") != null or
        std.mem.indexOf(u8, file_path, "src/transports/") != null or
        std.mem.indexOf(u8, file_path, "src/future/") != null or
        std.mem.indexOf(u8, file_path, "src/task/") != null or
        std.mem.indexOf(u8, file_path, "src/callback_manager.zig") != null;

    if (!is_io_path) return;

    for (0..ast.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(i);
        const tag = ast.nodes.items(.tag)[i];
        const main_token = ast.nodes.items(.main_token)[i];

        // Check builtin_call nodes for @panic
        const is_builtin_call = tag == .builtin_call_two or tag == .builtin_call or tag == .builtin_call_comma;
        if (is_builtin_call) {
            const token_bytes = ast.tokenSlice(main_token);
            if (std.mem.eql(u8, token_bytes, "@panic")) {
                const loc = ast.tokenLocation(0, main_token);
                try diagnostics.append(gpa, .{
                    .file_path = file_path,
                    .line = loc.line + 1,
                    .column = loc.column + 1,
                    .rule_id = "TALYN-002/NO_PANIC_IN_IO",
                    .bug_ref = "Mandate 1, BUG-105, BUG-188",
                    .message = "Use of '@panic' inside loop or transport IO execution path.",
                    .risk = "Unconditionally crashes the Python process instead of cleanly raising an asyncio exception.",
                    .fix = "Convert Zig errors via 'utils.handle_zig_function_error' or return error unions.",
                });
            }
        }

        // Check call nodes for panic function invocation
        var call_buffer: [1]std.zig.Ast.Node.Index = undefined;
        if (ast.fullCall(&call_buffer, node)) |call| {
            const fn_expr_node = call.ast.fn_expr;
            const fn_tag = ast.nodes.items(.tag)[@intFromEnum(fn_expr_node)];
            var is_panic = false;
            if (fn_tag == .field_access) {
                // e.g. std.debug.panic or debug.panic
                const field_tok = ast.nodes.items(.data)[@intFromEnum(fn_expr_node)].node_and_token[1];
                if (std.mem.eql(u8, ast.tokenSlice(field_tok), "panic")) {
                    is_panic = true;
                }
            } else {
                const fn_token = ast.nodes.items(.main_token)[@intFromEnum(fn_expr_node)];
                if (std.mem.eql(u8, ast.tokenSlice(fn_token), "panic")) {
                    is_panic = true;
                }
            }
            if (is_panic) {
                const loc = ast.tokenLocation(0, main_token);
                try diagnostics.append(gpa, .{
                    .file_path = file_path,
                    .line = loc.line + 1,
                    .column = loc.column + 1,
                    .rule_id = "TALYN-002/NO_PANIC_IN_IO",
                    .bug_ref = "Mandate 1, BUG-105, BUG-188",
                    .message = "Call to panic function inside IO path.",
                    .risk = "Terminates the host runtime without propagating error state to Python asyncio callers.",
                    .fix = "Propagate errors with 'try' or handle gracefully with error reporting.",
                });
            }
        }
    }
}
