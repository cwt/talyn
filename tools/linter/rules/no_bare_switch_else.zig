const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    // src/python_c.zig defines wrapper macros and switch fallbacks for C types
    if (std.mem.endsWith(u8, file_path, "src/python_c.zig")) return;

    for (0..ast.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(i);
        const tag = ast.nodes.items(.tag)[i];
        if (tag != .switch_case_one and tag != .switch_case and tag != .switch_case_inline_one and tag != .switch_case_inline) continue;

        const main_token = ast.nodes.items(.main_token)[i];
        if (ast.fullSwitchCase(node)) |sc| {
            // If values.len == 0, it's an 'else' prong
            if (sc.ast.values.len == 0) {
                var buffer: [2]std.zig.Ast.Node.Index = undefined;
                if (ast.blockStatements(&buffer, sc.ast.target_expr)) |stmts| {
                    if (stmts.len == 0) {
                        const loc = ast.tokenLocation(0, main_token);
                        try diagnostics.append(gpa, .{
                            .file_path = file_path,
                            .line = loc.line + 1,
                            .column = loc.column + 1,
                            .rule_id = "TALYN-005/NO_BARE_SWITCH_ELSE",
                            .bug_ref = "BUG-096",
                            .message = "Bare 'else => {}' in switch statement silently drops unhandled variants.",
                            .risk = "Newly added enum or completion variants will be discarded silently with zero logging or error handling.",
                            .fix = "Explicitly handle all switch variants or log a warning in the fallback branch.",
                        });
                    }
                }
            }
        }
    }
}
