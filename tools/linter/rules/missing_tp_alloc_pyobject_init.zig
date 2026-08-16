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
    // We only inspect fields declared inside `struct { ... }` blocks.
    var pyobject_field_names: std.ArrayList([]const u8) = .empty;
    defer pyobject_field_names.deinit(gpa);

    var in_struct = false;
    var brace_depth: isize = 0;
    var prev_nl: usize = 0;

    var pos: usize = 0;
    while (pos < content.len) {
        const c = content[pos];
        if (c == '\n') {
            const line = content[prev_nl..pos];
            const trimmed = std.mem.trim(u8, line, " \t");

            if (!in_struct) {
                if (std.mem.indexOf(u8, trimmed, "struct {") != null and
                    (std.mem.indexOf(u8, trimmed, "const ") != null or std.mem.indexOf(u8, trimmed, "var ") != null))
                {
                    in_struct = true;
                    brace_depth = 0;
                    for (line) |ch| {
                        if (ch == '{') brace_depth += 1;
                        if (ch == '}') brace_depth -= 1;
                    }
                    if (brace_depth <= 0) in_struct = false;
                }
            } else {
                for (line) |ch| {
                    if (ch == '{') brace_depth += 1;
                    if (ch == '}') brace_depth -= 1;
                }

                // Check if this line is a struct field (not a function, var/const, or comment)
                if (!std.mem.startsWith(u8, trimmed, "fn ") and
                    !std.mem.startsWith(u8, trimmed, "pub fn ") and
                    !std.mem.startsWith(u8, trimmed, "inline fn ") and
                    !std.mem.startsWith(u8, trimmed, "pub inline fn ") and
                    !std.mem.startsWith(u8, trimmed, "const ") and
                    !std.mem.startsWith(u8, trimmed, "var ") and
                    !std.mem.startsWith(u8, trimmed, "//") and
                    std.mem.indexOf(u8, trimmed, ":") != null and
                    std.mem.indexOf(u8, trimmed, "PyObject") != null and
                    std.mem.indexOf(u8, trimmed, "?") != null)
                {
                    const colon_idx = std.mem.indexOfScalar(u8, trimmed, ':') orelse 0;
                    const fname = std.mem.trim(u8, trimmed[0..colon_idx], " \t");
                    if (fname.len > 0 and fname[0] != '_' and std.mem.indexOf(u8, fname, " ") == null) {
                        try pyobject_field_names.append(gpa, fname);
                    }
                }

                if (brace_depth <= 0) {
                    in_struct = false;
                }
            }
            prev_nl = pos + 1;
        }
        pos += 1;
    }

    if (pyobject_field_names.items.len == 0) return;

    // For each optional PyObject field, check it's initialized (e.g. `fname =` or `.fname =` or `fname: null`)
    // somewhere in the file.
    for (pyobject_field_names.items) |fname| {
        var search_pos: usize = 0;
        var found_init: bool = false;
        while (search_pos < content.len and !found_init) {
            const idx = std.mem.indexOfPos(u8, content, search_pos, fname) orelse break;
            const after = idx + fname.len;
            if (after < content.len) {
                const suffix = content[after..];
                const trimmed = std.mem.trimStart(u8, suffix, " \t");
                // An initialization is `fname = ...` or `.fname = ...` or `fname: null` (in struct literal),
                // but NOT `fname: ?*PyObject` or `fname: PyObject` (which is a type definition).
                if (std.mem.startsWith(u8, trimmed, "=")) {
                    // Check before idx that it's not `const fname =` or `var fname =`
                    var is_decl = false;
                    if (idx > 0) {
                        const before = content[0..idx];
                        const last_newline = std.mem.lastIndexOfScalar(u8, before, '\n') orelse 0;
                        const line_before = std.mem.trim(u8, before[last_newline..], " \t");
                        if (std.mem.startsWith(u8, line_before, "const ") or
                            std.mem.startsWith(u8, line_before, "var "))
                        {
                            is_decl = true;
                        }
                    }
                    if (!is_decl) {
                        found_init = true;
                    }
                } else if (std.mem.startsWith(u8, trimmed, ": null")) {
                    found_init = true;
                }
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
