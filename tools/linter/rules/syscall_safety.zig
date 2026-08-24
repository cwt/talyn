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
        //
        // Zig 0.16 layout:
        //   .assign           → nodeData().node_and_node: [0]=lhs node, [1]=rhs node
        //   .assign_destructure → use ast.assignDestructure(); value_expr is the rhs
        if (tag == .assign or tag == .assign_destructure) {
            const node: std.zig.Ast.Node.Index = @enumFromInt(i);
            const main_token = ast.nodes.items(.main_token)[i];

            var rhs_node: std.zig.Ast.Node.Index = undefined;
            var lhs_text: []const u8 = "";

            if (tag == .assign) {
                const d = ast.nodeData(node);
                const lhs_node = d.node_and_node[0];
                rhs_node = d.node_and_node[1];
                const lhs_tok = ast.nodes.items(.main_token)[@intFromEnum(lhs_node)];
                lhs_text = ast.tokenSlice(lhs_tok);
            } else {
                // assign_destructure: use the structured accessor
                const ad = ast.assignDestructure(node);
                rhs_node = ad.ast.value_expr;
                if (ad.ast.variables.len == 1) {
                    const lhs_node = ad.ast.variables[0];
                    const lhs_tok = ast.nodes.items(.main_token)[@intFromEnum(lhs_node)];
                    lhs_text = ast.tokenSlice(lhs_tok);
                }
            }

            if (std.mem.eql(u8, lhs_text, "_")) {
                var call_buffer: [1]std.zig.Ast.Node.Index = undefined;
                if (ast.fullCall(&call_buffer, rhs_node)) |call| {
                    const fn_expr = call.ast.fn_expr;
                    const fn_tag = ast.nodes.items(.tag)[@intFromEnum(fn_expr)];
                    var call_name: []const u8 = "";
                    if (fn_tag == .field_access) {
                        const field_tok = ast.nodeData(fn_expr).node_and_token[1];
                        call_name = ast.tokenSlice(field_tok);
                    } else {
                        const fn_tok = ast.nodes.items(.main_token)[@intFromEnum(fn_expr)];
                        call_name = ast.tokenSlice(fn_tok);
                    }

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
