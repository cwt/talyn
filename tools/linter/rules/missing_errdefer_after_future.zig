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

    // Build a flat list of (node_index, line, token_text)
    var nodes: std.ArrayList(struct {
        node_idx: usize,
        line: usize,
        text: []const u8,
    }) = .empty;
    defer nodes.deinit(gpa);
    _ = nodes.appendNTimes(gpa, .{ .node_idx = 0, .line = 0, .text = "" }, ast.nodes.len) catch {};
    nodes.items.len = 0;

    var ni: usize = 0;
    while (ni < ast.nodes.len) : (ni += 1) {
        const mtok = ast.nodes.items(.main_token)[ni];
        const loc = ast.tokenLocation(0, mtok);
        try nodes.append(gpa, .{
            .node_idx = ni,
            .line = @intCast(loc.line),
            .text = ast.tokenSlice(mtok),
        });
    }

    // Scan for fast_new_future calls (not the function definition itself)
    var scan: usize = 0;
    while (scan < nodes.items.len) : (scan += 1) {
        const node = nodes.items[scan];
        if (!std.mem.eql(u8, node.text, "fast_new_future")) continue;

        // Skip if this is part of a function definition
        var prev: usize = if (scan > 15) scan - 15 else 0;
        var is_def: bool = false;
        while (prev < scan) : (prev += 1) {
            if (std.mem.eql(u8, nodes.items[prev].text, "fn")) {
                is_def = true;
                break;
            }
        }
        if (is_def) continue;

        // Find the variable name from the preceding const/var declaration
        var var_name: ?[]const u8 = null;
        prev = if (scan > 8) scan - 8 else 0;
        while (prev < scan) : (prev += 1) {
            const t = nodes.items[prev].text;
            if (std.mem.eql(u8, t, "const") or std.mem.eql(u8, t, "var")) {
                var m: usize = prev + 1;
                while (m < scan) : (m += 1) {
                    const mt = nodes.items[m].text;
                    if (mt.len > 0 and mt[0] != ' ' and mt[0] != '\n') {
                        var_name = mt;
                        break;
                    }
                }
                break;
            }
        }
        if (var_name == null) continue;

        // Look forward for errdefer py_decref(var_name)
        var found: bool = false;
        var ej: usize = scan + 1;
        while (ej < nodes.items.len and ej < scan + 12) : (ej += 1) {
            const en = nodes.items[ej];
            if (std.mem.eql(u8, en.text, "errdefer")) {
                var ek: usize = ej + 1;
                while (ek < nodes.items.len and ek < ej + 15) : (ek += 1) {
                    const et = nodes.items[ek].text;
                    if (std.mem.eql(u8, et, ";")) break;
                    if (std.mem.eql(u8, et, "py_decref")) {
                        var em: usize = ek + 1;
                        while (em < nodes.items.len and em < ek + 10) : (em += 1) {
                            const mt2 = nodes.items[em].text;
                            if (std.mem.eql(u8, mt2, ")")) break;
                            if (std.mem.eql(u8, mt2, var_name.?)) {
                                found = true;
                                break;
                            }
                        }
                        break;
                    }
                }
            }
            // Stop at next top-level const/var declaration
            if (std.mem.eql(u8, en.text, "const") or std.mem.eql(u8, en.text, "var")) {
                break;
            }
        }

        if (!found) {
            const loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[node.node_idx]);
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
