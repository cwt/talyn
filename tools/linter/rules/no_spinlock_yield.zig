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
        if (std.mem.eql(u8, name, "yield")) {
            // Check if preceded by Thread or std.Thread
            if (tok_idx > 0) {
                const prev_name = ast.tokenSlice(@intCast(tok_idx - 1));
                if (std.mem.eql(u8, prev_name, "Thread") or std.mem.eql(u8, prev_name, "std.Thread")) {
                    const loc = ast.tokenLocation(0, @intCast(tok_idx));
                    try diagnostics.append(gpa, .{
                        .file_path = file_path,
                        .line = loc.line + 1,
                        .column = loc.column + 1,
                        .rule_id = "TALYN-007/NO_SPINLOCK_YIELD",
                        .bug_ref = "BUG-125",
                        .message = "Use of 'std.Thread.yield()' in locking paths.",
                        .risk = "Thread.yield() can return YieldError or behave inefficiently in high-contention spinlocks.",
                        .fix = "Use proper eventfd notification, futex, or handle YieldError explicitly.",
                    });
                }
            }
        }
    }
}
