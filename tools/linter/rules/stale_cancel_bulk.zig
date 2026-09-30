const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

/// TALYN-016/STALE_CANCEL_BULK
///
/// Bulk `CancelIO`/`CancelTimer` over a `task_ids` collection without removing
/// completed IDs first. Cancelling a completed task is not just wasteful: its
/// BlockingTask slot is already freed and may have been reused (task ids are
/// raw slot pointers, no generation), so a stale CancelIO kills the new
/// occupant and its callback fires immediately (BUG-336).
///
/// Flags files that loop `for (...task_ids.items)` and queue
/// `CancelIO`/`CancelTimer` inside, but contain no `swapRemove`,
/// `removeTaskId`, or `fetchRemove` removal helper in the same file.
/// The fixed pattern (create_connection.zig) keeps only still-pending
/// connects in `task_ids` via `removeTaskId` on completion and tracks the
/// happy-eyeballs timer separately in `happy_timer_id`.
///
/// Opt out with `// TALYN-016-EXEMPT: <reason>`.
pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    const content = ast.source;
    if (std.mem.indexOf(u8, content, "task_ids") == null) return;
    if (std.mem.indexOf(u8, content, "CancelIO") == null and std.mem.indexOf(u8, content, "CancelTimer") == null) return;
    if (std.mem.indexOf(u8, content, "TALYN-016-EXEMPT") != null) return;

    const has_removal = std.mem.indexOf(u8, content, "swapRemove") != null or
        std.mem.indexOf(u8, content, "removeTaskId") != null or
        std.mem.indexOf(u8, content, "fetchRemove") != null;
    if (has_removal) return;

    var line_no: usize = 0;
    var bulk_line: ?usize = null;
    var in_bulk_loop = false;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        if (std.mem.indexOf(u8, line, "task_ids.items") != null and std.mem.indexOf(u8, line, "for") != null) {
            in_bulk_loop = true;
            bulk_line = line_no + 1;
        }
        if (in_bulk_loop) {
            if (std.mem.indexOf(u8, line, "CancelIO") != null or std.mem.indexOf(u8, line, "CancelTimer") != null) {
                const loc_line = bulk_line orelse line_no + 1;
                try diagnostics.append(gpa, .{
                    .file_path = file_path,
                    .line = loc_line,
                    .column = 1,
                    .rule_id = "TALYN-016/STALE_CANCEL_BULK",
                    .bug_ref = "BUG-336",
                    .message = "Bulk CancelIO/CancelTimer over task_ids without completed-ID removal.",
                    .risk = "Cancelling an already-completed task hits a freed BlockingTask slot that may have been reused (raw pointer IDs, no generation); the stale cancel kills the new occupant and its callback fires immediately.",
                    .fix = "Remove each ID on completion (swapRemove/removeTaskId/fetchRemove) so cancel rounds only hit still-pending tasks; track timers in a separate happy_timer_id field cleared on fire/cancel (see create_connection.zig).",
                });
                return;
            }
            if (std.mem.indexOf(u8, line, "}") != null) {
                in_bulk_loop = false;
            }
        }
    }
}
