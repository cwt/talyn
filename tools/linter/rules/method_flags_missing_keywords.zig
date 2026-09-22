const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

/// TALYN-014/FASTCALL_MISSING_KEYWORDS
///
/// Flags every `PyMethodDef` entry whose `.ml_flags` expression contains
/// `METH_FASTCALL` but not `METH_KEYWORDS`.  Without `METH_KEYWORDS` CPython
/// dispatches to the 3-argument `(self, args, nargs)` entry-point form and
/// rejects every keyword call with:
///
///   TypeError: <name>() takes no keyword arguments
///
/// CPython asyncio (and uvloop) declare these parameters as
/// positional-or-keyword, so third-party libraries such as python-socks
/// (aiohttp-socks) that call e.g. `loop.sock_connect(sock=..., address=...)`
/// fail on talyn.  This is the registration half of BUG-331.
///
/// Deliberately positional-only methods must opt out with a marker comment on
/// the flags line or the line immediately above it:
///
///   // TALYN-014-EXEMPT: internal API, no CPython counterpart
pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    const content = ast.source;
    if (std.mem.indexOf(u8, content, "PyMethodDef") == null) return;

    var current_name: []const u8 = "<unknown>";
    var prev_line_exempt = false;

    var it = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 0;
    while (it.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const line_exempt = std.mem.indexOf(u8, line, "TALYN-014-EXEMPT") != null;

        if (std.mem.indexOf(u8, line, ".ml_name = \"")) |name_idx| {
            const start = name_idx + ".ml_name = \"".len;
            const rest = line[start..];
            if (std.mem.indexOfScalar(u8, rest, '"')) |end| {
                const raw = rest[0..end];
                const name = if (std.mem.endsWith(u8, raw, "\\x00")) raw[0 .. raw.len - 4] else raw;
                if (name.len > 0) current_name = name;
            }
        }

        if (!std.mem.startsWith(u8, trimmed, "//")) {
            if (std.mem.indexOf(u8, line, ".ml_flags")) |flags_idx| {
                const expr = line[flags_idx..];
                const has_fastcall = std.mem.indexOf(u8, expr, "METH_FASTCALL") != null;
                const has_keywords = std.mem.indexOf(u8, expr, "METH_KEYWORDS") != null;
                if (has_fastcall and !has_keywords and !line_exempt and !prev_line_exempt) {
                    try diagnostics.append(gpa, .{
                        .file_path = file_path,
                        .line = line_no + 1,
                        .column = flags_idx + 1,
                        .rule_id = "TALYN-014/FASTCALL_MISSING_KEYWORDS",
                        .bug_ref = "BUG-331",
                        .message = try std.fmt.allocPrint(
                            gpa,
                            "'{s}' is registered METH_FASTCALL without METH_KEYWORDS.",
                            .{current_name},
                        ),
                        .risk = "Every keyword call raises 'TypeError: takes no keyword arguments' - CPython asyncio and uvloop accept keywords here, so drop-in consumers (python-socks / aiohttp-socks) break.",
                        .fix = "Add '| python_c.METH_KEYWORDS' and accept 'knames' in the 4-argument entry point (see create_connection.zig:262). If positional-only is intentional, add a '// TALYN-014-EXEMPT: <reason>' comment.",
                    });
                }
            }
        }

        prev_line_exempt = line_exempt;
    }
}
