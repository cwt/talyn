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
                if (std.mem.startsWith(u8, trimmed, "const ") and
                    std.mem.indexOf(u8, trimmed, "= struct {") != null)
                {
                    const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
                    const name_part = trimmed[6..eq_idx];
                    const name_trimmed = std.mem.trim(u8, name_part, " ");
                    if (name_trimmed.len > 0) {
                        in_struct = true;
                        struct_name = name_trimmed;
                        brace_depth = 1; // skip the opening brace
                    }
                }
            } else {
                var lc: usize = 0;
                while (lc < line.len) : (lc += 1) {
                    if (line[lc] == '{') brace_depth += 1;
                    if (line[lc] == '}') brace_depth -= 1;
                }

                if (std.mem.startsWith(u8, trimmed, "py_") and
                    std.mem.indexOf(u8, trimmed, ": ?PyObject") != null)
                {
                    var end: usize = 0;
                    while (end < trimmed.len and trimmed[end] != ':') end += 1;
                    const fname = trimmed[0..end];
                    for (structs.items) |*s| {
                        if (std.mem.eql(u8, s.name, struct_name)) {
                            try s.fields.append(gpa, fname);
                        }
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
            const ctx_start = if (pvc_idx > 2000) pvc_idx - 2000 else 0;
            const ctx_end = if (pvc_idx + 2000 < content.len) pvc_idx + 2000 else content.len;
            const ctx = content[ctx_start..ctx_end];

            for (st.fields.items) |fname| {
                const ref_pattern = std.fmt.allocPrint(gpa, "&{s}", .{fname}) catch continue;
                defer gpa.free(ref_pattern);
                if (std.mem.indexOf(u8, ctx, ref_pattern) != null) {
                    try parsed_fields.append(gpa, fname);
                }
            }
            search_pos = pvc_idx + 1;
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
