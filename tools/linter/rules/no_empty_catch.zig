const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    for (0..ast.nodes.len) |i| {
        const tag = ast.nodes.items(.tag)[i];
        if (tag != .@"catch") continue;

        const main_token = ast.nodes.items(.main_token)[i];
        const data = ast.nodes.items(.data)[i];
        const rhs_node = data.node_and_node[1];

        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        if (ast.blockStatements(&buffer, rhs_node)) |stmts| {
            if (stmts.len == 0) {
                const loc = ast.tokenLocation(0, main_token);
                try diagnostics.append(gpa, .{
                    .file_path = file_path,
                    .line = loc.line + 1,
                    .column = loc.column + 1,
                    .rule_id = "TALYN-003/NO_EMPTY_CATCH",
                    .bug_ref = "BUG-122, Zig 0.16 Rule 6",
                    .message = "Empty 'catch {}' block silently swallows errors.",
                    .risk = "Suppresses critical errors (allocations, kernel cancellations, socket disconnections) without logging or cleanup.",
                    .fix = "Replace with 'catch |err| std.log.warn(\"...\", .{err})' or propagate with 'try'.",
                });
            }
        }
    }
}
