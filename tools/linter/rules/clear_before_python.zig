const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

/// TALYN-017/CLEAR_BEFORE_PYTHON
///
/// A completion callback that runs synchronous Python while holding a stale
/// io_uring task ID. The BlockingTask slot is freed before the callback runs
/// (runner frees on CQE, dispatches via the ready queue later), so any
/// `call_later`/IO queued from Python synchronously reuses the freed slot.
/// A later `CancelIO(stale_id)` then kills the new occupant (BUG-336).
///
/// Per-function check: if a function touches an ID slot — references an ID
/// field (`.blocking_task_id`, `.read_task_id`, `.pidfd_task_id`,
/// `.inotify_task_id`, `.happy_timer_id`, `.task_id`) or re-arms
/// (`enqueue_*`, `queue_read(`, `ensure_inotify(`, `schedule_*`) — and
/// invokes Python (`PyObject_Call*`, `Soon.dispatch`, `dispatch_event(`,
/// `dispatch_subprocess_exit_callbacks`), the ID must be released BEFORE the
/// first Python call in the same function: cleared (`= 0` / `= null`) or
/// removed from its pending list (`removeTaskId` / `swapRemove` /
/// `fetchRemove`). Clears on a `defer` line run last, so they do not count.
///
/// Safe (not flagged): `watcher.blocking_task_id = 0;` before
/// `Soon.dispatch` (watchers.zig), `removeTaskId(mcs, completed_id)` before
/// Python (fixed create_connection.zig). Vulnerable: factory running while
/// `blocking_task_id` still holds the completed ID (streamserver
/// accept_callback via deferred `enqueue_accept`), `pidfd_task_id = 0`
/// after dispatch (subprocess), deferred `cleanup_read` after
/// `datagram_received` (datagram/read.zig), never-cleared `task_id`
/// (child_watcher), re-arm after `dispatch_event` (fs_watcher).
///
/// Opt out per function with `// TALYN-017-EXEMPT: <reason>` inside it.
const id_fields = [_][]const u8{
    ".blocking_task_id",
    ".read_task_id",
    ".pidfd_task_id",
    ".inotify_task_id",
    ".happy_timer_id",
    ".task_id",
};

const rearm_markers = [_][]const u8{
    "enqueue_",
    "queue_read(",
    "ensure_inotify(",
    "schedule_",
};

fn isFnStart(trimmed: []const u8) bool {
    if (std.mem.startsWith(u8, trimmed, "fn ")) return true;
    if (std.mem.startsWith(u8, trimmed, "pub fn ")) return true;
    if (std.mem.startsWith(u8, trimmed, "inline fn ")) return true;
    if (std.mem.startsWith(u8, trimmed, "export fn ")) return true;
    if (std.mem.startsWith(u8, trimmed, "pub inline fn ")) return true;
    return false;
}

fn isTestStart(trimmed: []const u8) bool {
    if (std.mem.startsWith(u8, trimmed, "test ")) return true;
    if (std.mem.startsWith(u8, trimmed, "pub test ")) return true;
    return false;
}

fn fnNameOf(trimmed: []const u8) []const u8 {
    const fn_kw = std.mem.indexOf(u8, trimmed, "fn ") orelse return "fn";
    const after = trimmed[fn_kw + 3 ..];
    const end = std.mem.indexOfScalar(u8, after, '(') orelse after.len;
    return std.mem.trim(u8, after[0..end], " \t");
}

fn isPythonCall(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "PyObject_Call") != null) return true;
    if (std.mem.indexOf(u8, line, "Soon.dispatch") != null) return true;
    if (std.mem.indexOf(u8, line, "dispatch_event(") != null) return true;
    if (std.mem.indexOf(u8, line, "dispatch_subprocess_exit_callbacks") != null) return true;
    return false;
}

fn touchesIdSlot(line: []const u8) ?[]const u8 {
    for (id_fields) |field| {
        if (std.mem.indexOf(u8, line, field) != null) return field;
    }
    for (rearm_markers) |marker| {
        if (std.mem.indexOf(u8, line, marker) != null) return marker;
    }
    return null;
}

fn isIdRelease(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "removeTaskId") != null) return true;
    if (std.mem.indexOf(u8, line, "swapRemove") != null) return true;
    if (std.mem.indexOf(u8, line, "fetchRemove") != null) return true;
    for (id_fields) |field| {
        if (std.mem.indexOf(u8, line, field) == null) continue;
        if (std.mem.indexOf(u8, line, "= 0") != null) return true;
        if (std.mem.indexOf(u8, line, "=0") != null) return true;
        if (std.mem.indexOf(u8, line, "= null") != null) return true;
        if (std.mem.indexOf(u8, line, "=null") != null) return true;
    }
    return false;
}

const FnChunk = struct {
    name: []const u8,
    start_line: usize,
    is_completion_cb: bool = false,
    first_python_line: ?usize = null,
    slot_marker: ?[]const u8 = null,
    first_release_line: ?usize = null,
    exempt: bool = false,
};

pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    const is_io_path = std.mem.indexOf(u8, file_path, "src/transports/") != null or
        std.mem.indexOf(u8, file_path, "src/loop/") != null;
    if (!is_io_path) return;

    const content = ast.source;

    var chunks: std.ArrayList(FnChunk) = .empty;
    defer chunks.deinit(gpa);

    var line_no: usize = 0;
    var current: ?usize = null;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (isFnStart(trimmed)) {
            // BUG-336 fires in completion callbacks: the kernel slot was
            // freed just before they run. Setup helpers (z_create_*,
            // link, enqueue_*) never hold a completed ID, so only
            // `CallbackData` callbacks are in scope.
            const is_cb = std.mem.indexOf(u8, trimmed, "CallbackData") != null;
            try chunks.append(gpa, .{ .name = fnNameOf(trimmed), .start_line = line_no + 1, .is_completion_cb = is_cb });
            current = chunks.items.len - 1;
            continue;
        }
        if (isTestStart(trimmed)) {
            current = null;
            continue;
        }
        const idx = current orelse continue;
        if (std.mem.indexOf(u8, line, "TALYN-017-EXEMPT") != null) {
            chunks.items[idx].exempt = true;
        }
        if (touchesIdSlot(line)) |marker| {
            if (chunks.items[idx].slot_marker == null) {
                chunks.items[idx].slot_marker = marker;
            }
        }
        // A release on a `defer` line runs last, so it cannot protect an
        // earlier Python call — ignore it as a pre-Python release.
        const is_deferred = std.mem.indexOf(u8, line, "defer") != null;
        if (!is_deferred and isIdRelease(line) and chunks.items[idx].first_release_line == null) {
            chunks.items[idx].first_release_line = line_no + 1;
        }
        if (chunks.items[idx].first_python_line == null and isPythonCall(line)) {
            if (!std.mem.startsWith(u8, trimmed, "//")) {
                chunks.items[idx].first_python_line = line_no + 1;
            }
        }
    }

    for (chunks.items) |chunk| {
        if (chunk.exempt) continue;
        if (!chunk.is_completion_cb) continue;
        const marker = chunk.slot_marker orelse continue;
        const py_line = chunk.first_python_line orelse continue;
        // Struct initializers and constructors name no hazard: they build
        // state rather than completing a kernel op.
        if (std.mem.indexOf(u8, chunk.name, "init") != null) continue;
        if (chunk.first_release_line) |release_line| {
            if (release_line < py_line) continue;
        }
        try diagnostics.append(gpa, .{
            .file_path = file_path,
            .line = py_line,
            .column = 1,
            .rule_id = "TALYN-017/CLEAR_BEFORE_PYTHON",
            .bug_ref = "BUG-336",
            .message = try std.fmt.allocPrint(
                gpa,
                "Function '{s}' runs Python while '{s}' may still hold a completed task ID (release missing or after first Python call).",
                .{ chunk.name, marker },
            ),
            .risk = "The freed BlockingTask slot can be synchronously reused by a factory-scheduled call_later/timer; a later CancelIO(stale_id) kills the new occupant and its callback fires immediately.",
            .fix = "Release the ID before any PyObject_Call/Soon.dispatch: clear to 0/null first or removeTaskId/swapRemove it from the pending list (see watchers.zig:121, fixed create_connection.zig:removeTaskId).",
        });
    }
}
