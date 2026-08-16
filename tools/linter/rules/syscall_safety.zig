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

        // 1. Check for discarded syscall returns: _ = std.os.linux.getsockname / getpeername
        if (tag == .assign_destructure or tag == .assign) {
            const main_token = ast.nodes.items(.main_token)[i];
            const data = ast.nodes.items(.data)[i];
            const lhs_node = data.node_and_node[0];
            const rhs_node = data.node_and_node[1];

            const lhs_token = ast.nodes.items(.main_token)[@intFromEnum(lhs_node)];
            const lhs_text = ast.tokenSlice(lhs_token);

            if (std.mem.eql(u8, lhs_text, "_")) {
                const rhs_token = ast.nodes.items(.main_token)[@intFromEnum(rhs_node)];
                const rhs_tag = ast.nodes.items(.tag)[@intFromEnum(rhs_node)];
                if (rhs_tag == .call or rhs_tag == .call_one or rhs_tag == .call_one_comma or rhs_tag == .call_comma) {
                    const call_name = ast.tokenSlice(rhs_token);
                    if (std.mem.eql(u8, call_name, "getsockname") or
                        std.mem.eql(u8, call_name, "getpeername"))
                    {
                        const loc = ast.tokenLocation(0, main_token);
                        try diagnostics.append(gpa, .{
                            .file_path = file_path,
                            .line = loc.line + 1,
                            .column = loc.column + 1,
                            .rule_id = "TALYN-006/DISCARDED_SYSCALL_RETURN",
                            .bug_ref = "BUG-190, BUG-199",
                            .message = "Discarded return value of getsockname/getpeername syscall.",
                            .risk = "If the syscall fails, subsequent code reads uninitialized stack memory as address data.",
                            .fix = "Check 'if (std.posix.errno(rc) == .SUCCESS)' before reading output buffer.",
                        });
                    }
                }
            }
        }
    }
}
