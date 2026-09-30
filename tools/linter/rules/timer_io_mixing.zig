const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

/// TALYN-018/TIMER_IO_MIXING
///
/// Timer IDs and IO task IDs must not share the same pending-ID list.
/// BUG-336 mixed the happy-eyeballs `WaitTimer` ID into `task_ids` alongside
/// `SocketConnect` IDs; the success/deinit cancel rounds then hit the timer
/// slot after it was freed and reused. The fix tracks the timer separately
/// (`happy_timer_id: ?usize`, cleared on fire/cancel) and keeps `task_ids`
/// for still-pending connects only.
///
/// Flags files that append to a `task_ids`-like list while also queueing a
/// `WaitTimer`, without any `happy_timer_id`-style separation in the same
/// file. The fixed create_connection.zig (timer in `happy_timer_id`) is
/// clean; a regression that appends the timer back into `task_ids` fails.
///
/// Opt out with `// TALYN-018-EXEMPT: <reason>`.
pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    const content = ast.source;
    if (std.mem.indexOf(u8, content, "TALYN-018-EXEMPT") != null) return;
    if (std.mem.indexOf(u8, content, "task_ids") == null) return;
    if (std.mem.indexOf(u8, content, ".append(") == null) return;
    if (std.mem.indexOf(u8, content, "WaitTimer") == null) return;
    // Separation present: timer lives outside the shared list.
    if (std.mem.indexOf(u8, content, "happy_timer_id") != null) return;

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        if (std.mem.indexOf(u8, line, "task_ids") != null and std.mem.indexOf(u8, line, ".append(") != null) {
            try diagnostics.append(gpa, .{
                .file_path = file_path,
                .line = line_no + 1,
                .column = 1,
                .rule_id = "TALYN-018/TIMER_IO_MIXING",
                .bug_ref = "BUG-336",
                .message = "task_ids list is appended while the file also queues WaitTimer without happy_timer_id separation.",
                .risk = "A timer ID mixed into an IO cancel list will be cancelled as if it were a connect/read; after slot reuse the cancel kills an unrelated timer and fires it immediately.",
                .fix = "Track the timer in a separate '?usize happy_timer_id' field, clear it when it fires/is cancelled, and keep task_ids for still-pending IO connects only.",
            });
            return;
        }
    }
}
