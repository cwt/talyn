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

    // Collect all node info up front
    var nodes: std.ArrayList(struct {
        tag: std.zig.Ast.Node.Tag,
        main_token: std.zig.Ast.Node.TokenIndex,
        line: usize,
        token_text: []const u8,
    }) = .empty;
    defer nodes.deinit(gpa);

    try nodes.ensureCapacity(gpa, ast.nodes.len);
    var i: usize = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const main_tok = ast.nodes.items(.main_token)[i];
        const loc = ast.tokenLocation(0, main_tok);
        try nodes.append(gpa, .{
            .tag = ast.nodes.items(.tag)[i],
            .main_token = main_tok,
            .line = @intCast(loc.line),
            .token_text = ast.tokenSlice(main_tok),
        });
    }

    // Scan for fast_new_future calls (not definitions)
    var ni: usize = 0;
    while (ni < nodes.items.len) : (ni += 1) {
        const node = nodes.items[ni];
        if (!std.mem.eql(u8, node.token_text, "fast_new_future")) continue;

        // Skip if this is part of a function definition (the inline fn itself)
        var is_definition: bool = false;
        var prev: usize = if (ni > 0) ni - 1 else @as(usize, 0);
        var search_back: usize = 0;
        while (search_back < 15 and prev > 0) : ({
            prev -= 1;
            search_back += 1;
        }) {
            if (std.mem.eql(u8, nodes.items[prev].token_text, "fn")) {
                is_definition = true;
                break;
            }
        }
        if (is_definition) continue;

        // Find the variable name assigned to by this call
        // Look backwards for: const/var <name> = try ...
        var var_name: ?[]const u8 = null;
        prev = if (ni > 5) ni - 5 else 0;
        var search_back2: usize = 0;
        while (prev < ni) : ({
            prev += 1;
            search_back2 += 1;
        }) {
            const n = nodes.items[prev];
            if (std.mem.eql(u8, n.token_text, "const") or std.mem.eql(u8, n.token_text, "var")) {
                // Next non-whitespace token is the var name
                var m: usize = prev + 1;
                while (m < ni) : (m += 1) {
                    const mtext = nodes.items[m].token_text;
                    if (mtext.len > 0 and mtext[0] != ' ' and mtext[0] != '\n' and mtext[0] != '\t') {
                        var_name = mtext;
                        break;
                    }
                }
                break;
            }
        }

        if (var_name == null) continue;

        // Check for errdefer py_decref(var_name) within ~8 nodes forward
        var found_errdefer: bool = false;
        var ej: usize = ni + 1;
        while (ej < nodes.items.len and ej < ni + 12) : (ej += 1) {
            const enode = nodes.items[ej];
            // Check for errdefer keyword
            if (std.mem.eql(u8, enode.token_text, "errdefer")) {
                // Look ahead for py_decref and the var name
                var ek: usize = ej + 1;
                while (ek < nodes.items.len and ek < ej + 15) : (ek += 1) {
                    const etext = nodes.items[ek].token_text;
                    if (std.mem.eql(u8, etext, ";")) break;
                    if (std.mem.eql(u8, etext, "py_decref")) {
                        // Check next non-paren token for var name match
                        var em: usize = ek + 1;
                        while (em < nodes.items.len and em < ek + 10) : (em += 1) {
                            const mtext = nodes.items[em].token_text;
                            if (std.mem.eql(u8, mtext, ")")) break;
                            if (std.mem.eql(u8, mtext, "(")) continue;
                            if (std.mem.eql(u8, mtext, "@")) continue;
                            if (std.mem.eql(u8, mtext, ".")) continue;
                            if (std.mem.eql(u8, mtext, "*")) continue;
                            if (std.mem.eql(u8, mtext, "&")) continue;
                            if (std.mem.eql(u8, mtext, "@")) continue;
                            // Check if it matches our var name or contains it
                            if (std.mem.eql(u8, mtext, var_name.?)) {
                                found_errdefer = true;
                                break;
                            }
                        }
                        break;
                    }
                }
            }
            // Stop searching if we hit another top-level statement boundary
            // (a new const/var decl or a significant statement at same indent)
            if (std.mem.eql(u8, enode.token_text, "const") or std.mem.eql(u8, enode.token_text, "var")) {
                break;
            }
        }

        if (!found_errdefer) {
            const loc = ast.tokenLocation(0, node.main_token);
            try diagnostics.append(gpa, .{
                .file_path = file_path,
                .line = node.line + 1,
                .column = 1,
                .rule_id = "TALYN-009/MISSING_ERRDEFER_AFTER_FAST_NEW_FUTURE",
                .bug_ref = "BUG-187, BUG-203",
                .message = "Missing errdefer py_decref after fast_new_future call.",
                .risk = "If subsequent initialization steps fail, the Python Future object is leaked.",
                .fix = "Add 'errdefer python_c.py_decref(@ptrCast(<var>));' immediately after the fast_new_future call.",
            });
        }
    }
}
