const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    // Only enforced for src/ domain logic (tools/linter and build.zig are permitted)
    if (!std.mem.startsWith(u8, file_path, "src/")) return;

    for (0..ast.tokens.len) |tok_idx| {
        const tok_tag = ast.tokens.items(.tag)[tok_idx];
        if (tok_tag != .identifier) continue;

        const name = ast.tokenSlice(@intCast(tok_idx));
        if (std.mem.eql(u8, name, "mode")) {
            if (tok_idx >= 2) {
                const dot_tok = ast.tokenSlice(@intCast(tok_idx - 1));
                const prev_name = ast.tokenSlice(@intCast(tok_idx - 2));
                if (std.mem.eql(u8, dot_tok, ".") and std.mem.eql(u8, prev_name, "builtin")) {
                    const loc = ast.tokenLocation(0, @intCast(tok_idx));
                    try diagnostics.append(gpa, .{
                        .file_path = file_path,
                        .line = loc.line + 1,
                        .column = loc.column + 1,
                        .rule_id = "TALYN-019/NO_BUILTIN_MODE_IN_SRC",
                        .bug_ref = "BUG-365, Mandate #2: Dual-Toolchain Compatibility",
                        .message = "Direct use of 'builtin.mode' in source modules.",
                        .risk = "Breaks dual-toolchain compatibility across Zig 0.16 and 0.17 where OptimizeMode representation differs.",
                        .fix = "Expose build_options.is_debug in build.zig and use 'utils.is_debug' instead.",
                    });
                }
            }
        }
    }
}
