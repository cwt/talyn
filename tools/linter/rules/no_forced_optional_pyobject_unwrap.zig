const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

/// TALYN-012/NO_FORCED_OPTIONAL_PYOBJECT_UNWRAP
///
/// Flags every `.?` (unwrap_optional) node whose direct child is a
/// field_access on a known nullable protocol/callback field name.
///
/// Concretely: `transport.protocol_eof_received.?` is the pattern that caused
/// BUG-293.  When a stream transport is concurrently torn down (e.g. fast 403
/// close before the kernel delivers the read-EOF CQE), these fields are null,
/// so PyObject_Call*(NULL) raises SIGSEGV.
///
/// AST layout (Zig 0.16):
///   unwrap_optional → nodeData().node_and_token[0] = child node
///                     nodeData().node_and_token[1] = '?' token
///   field_access    → nodeData().node_and_token[0] = object node
///                     nodeData().node_and_token[1] = field identifier token
pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    const is_io_path = std.mem.indexOf(u8, file_path, "src/transports/") != null or
        std.mem.indexOf(u8, file_path, "src/loop/") != null or
        std.mem.indexOf(u8, file_path, "src/task/") != null or
        std.mem.indexOf(u8, file_path, "src/future/") != null;

    if (!is_io_path) return;

    const guarded_fields = [_][]const u8{
        "protocol_eof_received",
        "protocol_data_received",
        "protocol_buffer_updated",
        "protocol_get_buffer",
        "protocol_connection_lost",
        "protocol_pause_writing",
        "protocol_resume_writing",
        "protocol_max_read_constant",
        "protocol_factory",
        "connection_lost_callback",
        "read_completed_callback",
        "write_completed_callback",
    };

    const tags = ast.nodes.items(.tag);
    const main_tokens = ast.nodes.items(.main_token);

    for (0..ast.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(i);
        if (tags[i] != .unwrap_optional) continue;

        // unwrap_optional: node_and_token[0] = child node, [1] = '?' token
        const child_node = ast.nodeData(node).node_and_token[0];
        if (tags[@intFromEnum(child_node)] != .field_access) continue;

        // field_access: node_and_token[0] = object, [1] = field identifier token
        const field_token = ast.nodeData(child_node).node_and_token[1];
        const field_name = ast.tokenSlice(field_token);

        var matched = false;
        for (guarded_fields) |guarded| {
            if (std.mem.eql(u8, field_name, guarded)) {
                matched = true;
                break;
            }
        }
        if (!matched) continue;

        const loc = ast.tokenLocation(0, main_tokens[i]);
        try diagnostics.append(gpa, .{
            .file_path = file_path,
            .line = loc.line + 1,
            .column = loc.column + 1,
            .rule_id = "TALYN-012/NO_FORCED_OPTIONAL_PYOBJECT_UNWRAP",
            .bug_ref = "BUG-293",
            .message = try std.fmt.allocPrint(
                gpa,
                "Forced '.?' unwrap on nullable protocol field '{s}' in IO execution path.",
                .{field_name},
            ),
            .risk = "Field may be null if transport is concurrently torn down before the kernel delivers the read-EOF CQE — PyObject_Call*(NULL) raises SIGSEGV.",
            .fix = "Use safe capture: 'if (transport.field) |func| { ... }' and handle null (typically: close both transports).",
        });
    }
}
