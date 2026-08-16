const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    // Skip constructor definition file and test files
    if (std.mem.endsWith(u8, file_path, "future/python/constructors.zig")) return;
    if (std.mem.indexOf(u8, file_path, "/tests/") != null) return;

    var tok_idx: usize = 0;
    while (tok_idx < ast.tokens.len) : (tok_idx += 1) {
        const text = ast.tokenSlice(@intCast(tok_idx));
        if (!std.mem.eql(u8, text, "fast_new_future")) continue;

        // Skip if this is part of a function definition: fn fast_new_future(...)
        var is_fn_def = false;
        var bk: usize = if (tok_idx > 5) tok_idx - 5 else 0;
        while (bk < tok_idx) : (bk += 1) {
            if (std.mem.eql(u8, ast.tokenSlice(@intCast(bk)), "fn")) {
                is_fn_def = true;
                break;
            }
        }
        if (is_fn_def) continue;

        // Find the variable name from the preceding const/var declaration: const fut = try fast_new_future
        var var_name: ?[]const u8 = null;
        bk = if (tok_idx > 10) tok_idx - 10 else 0;
        while (bk < tok_idx) : (bk += 1) {
            const t = ast.tokenSlice(@intCast(bk));
            if (std.mem.eql(u8, t, "const") or std.mem.eql(u8, t, "var")) {
                if (bk + 1 < tok_idx and ast.tokens.items(.tag)[@intCast(bk + 1)] == .identifier) {
                    var_name = ast.tokenSlice(@intCast(bk + 1));
                }
                break;
            }
        }
        if (var_name == null) continue;

        // Look forward for errdefer ... py_decref (or release) on var_name
        var found = false;
        var fwd = tok_idx + 1;
        const max_fwd = @min(ast.tokens.len, tok_idx + 40);
        while (fwd < max_fwd) : (fwd += 1) {
            const ft = ast.tokenSlice(@intCast(fwd));
            if (std.mem.eql(u8, ft, "fn")) break; // hit another function
            if (std.mem.eql(u8, ft, "errdefer")) {
                const search_end = @min(ast.tokens.len, fwd + 20);
                var has_decref = false;
                var has_var = false;
                var si = fwd + 1;
                while (si < search_end) : (si += 1) {
                    const st = ast.tokenSlice(@intCast(si));
                    if (std.mem.eql(u8, st, ";")) break;
                    if (std.mem.eql(u8, st, "py_decref") or std.mem.eql(u8, st, "release")) {
                        has_decref = true;
                    }
                    if (std.mem.eql(u8, st, var_name.?)) {
                        has_var = true;
                    }
                }
                if (has_decref and has_var) {
                    found = true;
                    break;
                }
            }
        }

        if (!found) {
            const loc = ast.tokenLocation(0, @intCast(tok_idx));
            try diagnostics.append(gpa, .{
                .file_path = file_path,
                .line = loc.line + 1,
                .column = loc.column + 1,
                .rule_id = "TALYN-009/MISSING_ERRDEFER_AFTER_FAST_NEW_FUTURE",
                .bug_ref = "BUG-187, BUG-203",
                .message = "Missing errdefer py_decref after fast_new_future call.",
                .risk = "If subsequent initialization steps fail, the Python Future object is leaked.",
                .fix = "Add 'errdefer python_c.py_decref(@ptrCast(<var>));' immediately after the fast_new_future call.",
            });
        }
    }
}
