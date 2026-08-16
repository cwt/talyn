const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    const content = ast.source;
    if (std.mem.indexOf(u8, content, "Py_TPFLAGS_HAVE_GC") != null) {
        // If the file registers a GC type, it MUST also implement tp_clear
        if (std.mem.indexOf(u8, content, "tp_clear") == null) {
            // Find location of Py_TPFLAGS_HAVE_GC
            for (0..ast.tokens.len) |tok_idx| {
                const name = ast.tokenSlice(@intCast(tok_idx));
                if (std.mem.eql(u8, name, "Py_TPFLAGS_HAVE_GC")) {
                    const loc = ast.tokenLocation(0, @intCast(tok_idx));
                    try diagnostics.append(gpa, .{
                        .file_path = file_path,
                        .line = loc.line + 1,
                        .column = loc.column + 1,
                        .rule_id = "TALYN-008/GC_TYPE_REQUIRES_TP_CLEAR",
                        .bug_ref = "BUG-155, BUG-193",
                        .message = "Type specifies 'Py_TPFLAGS_HAVE_GC' but omits '.tp_clear'.",
                        .risk = "Python cyclic garbage collector cannot break reference cycles involving this type, permanently leaking memory.",
                        .fix = "Implement a 'tp_clear' function and register it in the PyTypeObject slot.",
                    });
                    break;
                }
            }
        }
    }
}
