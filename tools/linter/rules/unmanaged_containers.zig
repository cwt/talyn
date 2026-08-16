const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    for (0..ast.tokens.len) |tok_idx| {
        const tok_tag = ast.tokens.items(.tag)[tok_idx];
        if (tok_tag != .identifier) continue;

        const name = ast.tokenSlice(@intCast(tok_idx));
        if (std.mem.eql(u8, name, "AutoHashMap") or std.mem.eql(u8, name, "StringHashMap")) {
            // Check if next token is not Unmanaged or if it's directly from std
            var is_managed = true;
            if (tok_idx + 1 < ast.tokens.len) {
                const next_name = ast.tokenSlice(@intCast(tok_idx + 1));
                if (std.mem.eql(u8, next_name, "Unmanaged")) {
                    is_managed = false;
                }
            }

            if (is_managed) {
                const loc = ast.tokenLocation(0, @intCast(tok_idx));
                try diagnostics.append(gpa, .{
                    .file_path = file_path,
                    .line = loc.line + 1,
                    .column = loc.column + 1,
                    .rule_id = "TALYN-004/UNMANAGED_CONTAINERS",
                    .bug_ref = "BUG-126, Zig 0.16 Rule 4",
                    .message = "Use of managed container 'std.AutoHashMap' or 'std.StringHashMap'.",
                    .risk = "Managed containers embed allocators, causing memory lifecycle inconsistencies in Zig 0.16.",
                    .fix = "Use 'std.AutoHashMapUnmanaged' or 'std.StringHashMapUnmanaged' with '.empty' and pass allocator explicitly.",
                });
            }
        }
    }
}
