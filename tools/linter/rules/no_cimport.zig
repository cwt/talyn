const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    // src/python_c.zig is the approved C-API bridge module
    if (std.mem.endsWith(u8, file_path, "src/python_c.zig")) return;

    for (0..ast.nodes.len) |i| {
        const tag = ast.nodes.items(.tag)[i];
        const main_token = ast.nodes.items(.main_token)[i];

        // Only check builtin_call nodes that invoke @cImport
        const is_builtin_call = tag == .builtin_call_two or tag == .builtin_call or tag == .builtin_call_comma;
        if (!is_builtin_call) continue;

        const token_bytes = ast.tokenSlice(main_token);
        if (std.mem.eql(u8, token_bytes, "@cImport")) {
            const loc = ast.tokenLocation(0, main_token);
            try diagnostics.append(gpa, .{
                .file_path = file_path,
                .line = loc.line + 1,
                .column = loc.column + 1,
                .rule_id = "TALYN-001/NO_CIMPORT",
                .bug_ref = "BUG-123, Mandate: Pure Zig",
                .message = "Use of '@cImport' builtin is prohibited in source modules.",
                .risk = "Causes build friction and C ABI incompatibility across cross-compilation targets.",
                .fix = "Use 'addTranslateC' in build.zig or declare inline extern functions.",
            });
        }
    }
}
