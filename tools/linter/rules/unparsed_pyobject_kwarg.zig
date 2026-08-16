const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    // Skip test files and the bridge module
    if (std.mem.indexOf(u8, file_path, "/tests/") != null) return;
    if (std.mem.endsWith(u8, file_path, "src/python_c.zig")) return;

    const content = ast.source;
    if (std.mem.indexOf(u8, content, "parse_vector_call_kwargs") == null) return;
    if (std.mem.indexOf(u8, content, "py_") == null) return;

    // Find struct declarations with py_* fields
    var structs: std.ArrayList(struct { name: []const u8, fields: std.ArrayList([]const u8) }) = .empty;
    defer {
        for (structs.items) |*s| s.fields.deinit(gpa);
        structs.deinit(gpa);
    }

    var ln: usize = 0;
    var in_struct: bool = false;
    var struct_name: []const u8 = "";
    var brace_depth: isize = 0;
    var prev_nl: usize = 0;

    var pos: usize = 0;
    while (pos < content.len) {
        const c = content[pos];
        if (c == '\n') {
            const line = content[prev_nl..pos];
            const trimmed = std.mem.trim(u8, line, " \t");

            if (!in_struct) {
                var decl_idx: ?usize = null;
                if (std.mem.indexOf(u8, trimmed, "const ") != null and std.mem.indexOf(u8, trimmed, "= struct {") != null) {
                    decl_idx = std.mem.indexOf(u8, trimmed, "const ").? + 6;
                }
                if (decl_idx) |d_idx| {
                    const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
                        prev_nl = pos + 1;
                        pos += 1;
                        continue;
                    };
                    if (eq_idx > d_idx) {
                        const name_part = trimmed[d_idx..eq_idx];
                        const name_trimmed = std.mem.trim(u8, name_part, " ");
                        if (name_trimmed.len > 0) {
                            in_struct = true;
                            struct_name = name_trimmed;
                            brace_depth = 1;
                            try structs.append(gpa, .{
                                .name = struct_name,
                                .fields = .empty,
                            });
                        }
                    }
                }
            } else {
                for (line) |ch| {
                    if (ch == '{') brace_depth += 1;
                    if (ch == '}') brace_depth -= 1;
                }

                if (std.mem.startsWith(u8, trimmed, "py_") and
                    (std.mem.indexOf(u8, trimmed, "PyObject") != null))
                {
                    var end: usize = 0;
                    while (end < trimmed.len and trimmed[end] != ':') end += 1;
                    const fname = trimmed[0..end];
                    if (structs.items.len > 0) {
                        try structs.items[structs.items.len - 1].fields.append(gpa, fname);
                    }
                }

                if (brace_depth <= 0) {
                    in_struct = false;
                }
            }
            prev_nl = pos + 1;
            ln += 1;
        }
        pos += 1;
    }

    if (structs.items.len == 0) return;

    // For each struct, find parse_vector_call_kwargs calls and check coverage
    for (structs.items) |st| {
        if (st.fields.items.len == 0) continue;

        var parsed_fields: std.ArrayList([]const u8) = .empty;
        defer parsed_fields.deinit(gpa);

        var search_pos: usize = 0;
        while (search_pos < content.len) {
            const pvc_idx = std.mem.indexOfPos(u8, content, search_pos, "parse_vector_call_kwargs") orelse break;
            const open_paren = std.mem.indexOfScalarPos(u8, content, pvc_idx, '(') orelse break;
            var depth: usize = 1;
            var cp = open_paren + 1;
            while (cp < content.len and depth > 0) : (cp += 1) {
                if (content[cp] == '(') depth += 1;
                if (content[cp] == ')') depth -= 1;
            }
            const call_args = content[open_paren..cp];

            for (st.fields.items) |fname| {
                if (std.mem.indexOf(u8, call_args, fname) != null) {
                    try parsed_fields.append(gpa, fname);
                }
            }
            search_pos = cp;
        }

        for (st.fields.items) |fname| {
            var found: bool = false;
            for (parsed_fields.items) |pf| {
                if (std.mem.eql(u8, pf, fname)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                // Check if the field is assigned elsewhere in the file (e.g. positional arg assignment)
                var search_assign: usize = 0;
                while (search_assign < content.len) {
                    const assign_idx = std.mem.indexOfPos(u8, content, search_assign, fname) orelse break;
                    const after = assign_idx + fname.len;
                    if (after < content.len) {
                        const trimmed = std.mem.trimStart(u8, content[after..], " \t");
                        if (std.mem.startsWith(u8, trimmed, "=")) {
                            // Verify it's not a const/var definition
                            if (assign_idx > 0) {
                                const before = content[0..assign_idx];
                                const last_nl = std.mem.lastIndexOfScalar(u8, before, '\n') orelse 0;
                                const line_before = std.mem.trim(u8, before[last_nl..], " \t");
                                if (!std.mem.startsWith(u8, line_before, "const ") and
                                    !std.mem.startsWith(u8, line_before, "var "))
                                {
                                    found = true;
                                    break;
                                }
                            }
                        }
                    }
                    search_assign = after;
                }
            }
            if (!found) {
                try diagnostics.append(gpa, .{
                    .file_path = file_path,
                    .line = 1,
                    .column = 1,
                    .rule_id = "TALYN-011/UNPARSED_PYOBJECT_KWARG",
                    .bug_ref = "BUG-189, BUG-205",
                    .message = std.fmt.allocPrint(gpa, "Struct field '{s}.{s}' is not populated by any parse_vector_call_kwargs call.", .{ st.name, fname }) catch "Struct field not populated by kwargs parsing.",
                    .risk = "The corresponding Python keyword argument will be silently ignored for this struct.",
                    .fix = "Add the field reference to a parse_vector_call_kwargs call.",
                });
            }
        }
    }
}
