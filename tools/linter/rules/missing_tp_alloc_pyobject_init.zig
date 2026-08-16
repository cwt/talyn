const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (std.mem.indexOf(u8, file_path, "/tests/") != null) return;
    if (std.mem.endsWith(u8, file_path, "src/python_c.zig")) return;

    const content = ast.source;
    if (std.mem.indexOf(u8, content, "tp_alloc") == null) return;
    if (std.mem.indexOf(u8, content, "initialize_object_fields") != null) return;

    // Collect optional PyObject field names from struct declarations.
    // Pattern: `field_name: ?*PyObject` or `field_name: ?PyObject`
    var pyobject_field_names: std.ArrayList([]const u8) = .empty;
    defer pyobject_field_names.deinit(gpa);

    var tok_idx: usize = 0;
    while (tok_idx < ast.tokens.len) : (tok_idx += 1) {
        if (ast.tokens.items(.tag)[tok_idx] != .identifier) continue;
        const text = ast.tokenSlice(@intCast(tok_idx));
        if (!std.mem.eql(u8, text, "PyObject")) continue;

        // Look backwards for `?` and field name pattern
        var bk: usize = if (tok_idx > 4) @as(usize, @intCast(tok_idx)) - 4 else 0;
        var found: bool = false;
        while (bk < tok_idx) : (bk += 1) {
            const btext = ast.tokenSlice(@intCast(bk));
            if (std.mem.eql(u8, btext, "?")) {
                if (bk > 0) {
                    const before_q = ast.tokenSlice(@intCast(bk - 1));
                    if (std.mem.eql(u8, before_q, "*") or
                        ast.tokens.items(.tag)[@intCast(bk - 1)] == .identifier)
                    {
                        var fb: usize = if (bk > 2) @intCast(bk - 2) else 0;
                        var fc: usize = 0;
                        while (fc < 4 and fb > 0) : ({
                            fb -= 1;
                            fc += 1;
                        }) {
                            const ftext = ast.tokenSlice(@intCast(fb));
                            if (std.mem.eql(u8, ftext, ":")) {
                                if (fb > 0 and ast.tokens.items(.tag)[@intCast(fb - 1)] == .identifier) {
                                    const fname = ast.tokenSlice(@intCast(fb - 1));
                                    try pyobject_field_names.append(gpa, fname);
                                }
                                break;
                            }
                            if (!std.mem.eql(u8, ftext, "*")) break;
                        }
                        found = true;
                    }
                }
                break;
            }
            if (!std.mem.eql(u8, btext, "*")) continue;
        }
    }

    if (pyobject_field_names.items.len == 0) return;

    // For each optional PyObject field, check it's initialized to null
    // somewhere after tp_alloc in the file.
    for (pyobject_field_names.items) |fname| {
        var search_pos: usize = 0;
        var found_init: bool = false;
        while (search_pos < content.len and !found_init) {
            const idx = std.mem.indexOfPos(u8, content, search_pos, fname) orelse break;
            const after = idx + fname.len;
            if (after >= content.len) break;
            const suffix = content[after..];
            const trimmed = std.mem.trimStart(u8, suffix, " \t");
            if (std.mem.startsWith(u8, trimmed, "= null") or
                std.mem.startsWith(u8, trimmed, ": null"))
            {
                found_init = true;
            }
            search_pos = after;
        }

        if (!found_init) {
            // Report at the tp_alloc location
            const alloc_pos = std.mem.indexOf(u8, content, "tp_alloc") orelse continue;
            var line_num: usize = 1;
            var nl: usize = 0;
            while (nl < alloc_pos) : (nl += 1) {
                if (content[nl] == '\n') line_num += 1;
            }
            const last_nl = std.mem.lastIndexOfScalar(u8, content[0..alloc_pos], '\n') orelse 0;
            const col: usize = @intCast(alloc_pos - last_nl);
            try diagnostics.append(gpa, .{
                .file_path = file_path,
                .line = line_num,
                .column = col,
                .rule_id = "TALYN-010/UNINITIALIZED_PYOBJECT_FIELD_AFTER_TP_ALLOC",
                .bug_ref = "BUG-204, BUG-087",
                .message = std.fmt.allocPrint(gpa, "Optional PyObject field '{s}' not initialized after tp_alloc.", .{fname}) catch "Optional PyObject field not initialized after tp_alloc.",
                .risk = "Uninitialized PyObject pointers cause garbage references during GC traversal and dealloc, leading to crashes or reference leaks.",
                .fix = "Explicitly set all ?PyObject fields to null after tp_alloc, or use python_c.initialize_object_fields().",
            });
        }
    }
}
