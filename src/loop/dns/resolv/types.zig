const std = @import("std");
const utils = @import("utils");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const Loop = @import("../../main.zig");
const CallbackManager = @import("callback_manager");
const Cache = @import("../cache.zig");

pub const DEFAULT_TIMEOUT: std.os.linux.kernel_timespec = .{
    .sec = 5,
    .nsec = 0,
};

pub const DnsTimeout = struct {
    sec: u64 = 0,
    nsec: u32 = 0,
};

pub fn timeout_from_secs(timeout_secs: f64) ?DnsTimeout {
    if (!std.math.isFinite(timeout_secs) or timeout_secs < 0.0) return null;
    // BUG-361: clamp to an i64-representable second count — values above
    // maxInt(i64) parsed fine here but panicked later at the kernel
    // timespec conversion (dns_timeout_to_kernel_timespec narrows sec to
    // i64). 2^62 seconds (≈146 Myr) is already "effectively forever",
    // and being exactly representable avoids the f64 ulp rounding that
    // would push the value back out of the i64 range at 2^63.
    const max_secs: f64 = @floatFromInt(std.math.maxInt(i64) / 2);
    const safe_secs = @min(timeout_secs, max_secs);
    const sec_f = @floor(safe_secs);
    const sec: u64 = @intFromFloat(sec_f);
    const frac = safe_secs - sec_f;
    const nsec_f = @floor(frac * 1e9);
    const nsec: u32 = if (nsec_f >= 0.0 and nsec_f < 1e9) @intFromFloat(nsec_f) else 0;
    return .{ .sec = sec, .nsec = nsec };
}

pub fn timeout_to_secs(timeout: DnsTimeout) f64 {
    return @as(f64, @floatFromInt(timeout.sec)) + @as(f64, @floatFromInt(timeout.nsec)) / 1e9;
}

/// Parse a Python `dns_timeout` argument into a `DnsTimeout`.
/// Raises `TypeError` on non-float input (via `PyFloat_AsDouble`) and
/// `ValueError` on negative values. NaN/Inf map to null (default timeout)
/// through `timeout_from_secs`.
pub fn parse_dns_timeout(py_timeout: PyObject) !?DnsTimeout {
    const timeout_val = python_c.PyFloat_AsDouble(py_timeout);
    if (python_c.PyErr_Occurred() != null) return error.PythonError;
    if (timeout_val < 0.0) {
        python_c.raise_python_value_error("DNS timeout must be non-negative\x00");
        return error.PythonError;
    }
    return timeout_from_secs(timeout_val);
}

pub fn dns_timeout_to_kernel_timespec(timeout: DnsTimeout) std.os.linux.kernel_timespec {
    return .{
        .sec = @as(i64, @intCast(timeout.sec)),
        .nsec = @as(i64, @intCast(timeout.nsec)),
    };
}

pub const Header = packed struct {
    id: u16,
    flags: u16,
    qdcount: u16,
    ancount: u16,
    nscount: u16,
    arcount: u16,
};

pub const ResultHeader = packed struct {
    type: u16,
    class: u16,
    ttl: u32,
    data_len: u16,
};

pub const QuestionType = enum(u16) {
    ipv4 = 1,
    ipv6 = 28,
    ptr = 12,
};

pub const QuestionTypeClass = packed struct {
    type: u16,
    class: u16,
};

pub const Hostname = struct {
    hostname: [255]u8,
    hostname_len: u8,
    original_hostname_len: u8,
};

pub const HostnamesArray = struct {
    array: []Hostname,
    len: u32,
    processed: u32 = 0,
};

/// One DNS query payload — header + encoded question.  Maximum 512 bytes per RFC 1035.
pub const QuerySlot = struct {
    buf: [512]u8 = undefined,
    len: u16 = 0,
    id: u16 = 0,
};

pub const ServerQueryData = struct {
    loop: *Loop,

    socket_fd: std.posix.fd_t,

    hostnames_array: HostnamesArray,

    control_data: *ControlData,

    /// One slot per (hostname × question_type) — each sent as its own datagram.
    queries: []QuerySlot,
    /// Index of the query currently being (or about to be) sent.
    send_idx: u32 = 0,
    /// Number of individual DNS responses received so far.
    responses_received: u32 = 0,
    /// Stable 512-byte buffer reused for every response read.
    recv_buf: [512]u8 = undefined,

    results: std.ArrayList(utils.Address),
    ptr_results: std.ArrayList([]u8),

    min_ttl: u32 = std.math.maxInt(u32),
    finished: bool = false,
    dns_timeout: ?DnsTimeout = null,

    pub inline fn cancel(self: *ServerQueryData) void {
        const socket_fd = self.socket_fd;
        if (socket_fd >= 0) {
            // BUG-332: during loop teardown `io.deinit()`'s cancel_all already
            // cancels every in-flight op; queueing another CancelByFd after the
            // ring is gone would only log LoopDeinitialized.
            if (self.control_data.loop.initialized) {
                _ = self.control_data.loop.io.queue(.{ .CancelByFd = @intCast(socket_fd) }) catch |err| std.log.warn("queue cancel failed: {s}", .{@errorName(err)});
            }
            _ = std.os.linux.close(socket_fd);
            self.socket_fd = -1;
        }
    }

    pub fn release(self: *ServerQueryData) void {
        if (self.finished) return;
        self.finished = true;

        self.cancel();

        const control_data = self.control_data;
        control_data.tasks_finished += 1;

        const finalized = (control_data.tasks_finished == control_data.queries_data.len);
        if (finalized) {
            self.control_data.release();
        }
    }
};

pub const ControlData = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    record: *Cache.Record,
    loop: *Loop,

    user_callbacks: std.ArrayList(CallbackManager.Callback),

    queries_data: []ServerQueryData,
    tasks_finished: usize = 0,
    resolved: bool = false,
    record_evicted: bool = false,
    /// BUG-332: single-shot guard. `dns.deinit()` releases the control data
    /// directly, and the query's in-flight io_uring completions run later
    /// (during `io.deinit()`) - without this guard a lost `finished` flag on
    /// freed memory re-entered `release()` and re-dispatched every user
    /// callback (double free of GetNameInfoData -> SIGABRT).
    released: bool = false,
    /// Intrusive list of control data whose destruction was deferred until
    /// `Loop.release()` has drained the cancel completions (see DNS.defer_release).
    next_deferred: ?*ControlData = null,

    node: ?Loop.DNS.PendingList.Node = null,

    comptime {
        python_c.verify_gc_coverage(@This(), &.{ "record", "loop", "queries_data", "node", "next_deferred" });
    }

    pub fn destroy(self: *ControlData) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn release(self: *ControlData) void {
        if (self.released) return;
        self.released = true;

        const loop = self.loop;
        if (!self.resolved) {
            if (!self.record_evicted) {
                self.record.discard();
            }

            for (self.user_callbacks.items) |*v| {
                v.data.set_cancelled(true);
                if (!loop.initialized) {
                    Loop.Scheduling.Soon.dispatch_nonthreadsafe(loop, v) catch |err| std.log.warn("dispatch cancelled DNS callback failed: {s}", .{@errorName(err)});
                } else {
                    Loop.Scheduling.Soon.dispatch(loop, v) catch |err| std.log.warn("dispatch cancelled DNS callback failed: {s}", .{@errorName(err)});
                }
            }
        }

        if (self.node) |node| {
            self.loop.dns.pending_queries.unlink_node(node) catch |err| std.log.warn("unlink_node failed: {s}", .{@errorName(err)});
            self.loop.dns.pending_queries.release_node(node);
            self.node = null;
        }

        // BUG-332: while the loop is tearing down, io_uring cancel completions
        // for this query still dereference `self` and the arena-owned
        // ServerQueryData. Defer destruction until the loop has drained them.
        if (loop.initialized) {
            self.destroy();
        } else {
            loop.dns.defer_release(self);
        }
    }

    pub fn traverse(self: *const ControlData, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
        for (self.user_callbacks.items) |*v| {
            if (v.data.traverse()) |t| {
                const vret = t(v.data.user_data, @ptrCast(@constCast(visit)), arg);
                if (vret != 0) return vret;
            }
            if (v.data.module_ptr()) |mod| {
                const vret = visit.?(@ptrCast(mod), arg);
                if (vret != 0) return vret;
            }
            if (v.data.callback_ptr()) |cp| {
                const vret = visit.?(@ptrCast(cp), arg);
                if (vret != 0) return vret;
            }
        }
        return 0;
    }
};

pub fn should_fail_resolution_on_server_finish(control_data: *const ControlData) bool {
    return control_data.tasks_finished + 1 == control_data.queries_data.len and !control_data.resolved;
}

test "ControlData.record_evicted is false after struct-literal init (regression: e1db5b9)" {
    // This test guards against the bug where prepare_data used field-by-field
    // assignment and forgot to set record_evicted, leaving it as undefined
    // garbage bytes in ReleaseSafe/Release builds.  The struct-literal
    // initialisation in prepare_data must cover every field; the compiler
    // enforces this at compile time, but we also verify the runtime value to
    // make the intent unmistakable.
    const control_data = try std.testing.allocator.create(ControlData);
    defer std.testing.allocator.destroy(control_data);

    // Mimic exactly what prepare_data now does: struct-literal assignment.
    control_data.* = ControlData{
        .allocator = std.testing.allocator,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .loop = undefined,
        .user_callbacks = .empty,
        .record = undefined,
        .queries_data = undefined,
        .tasks_finished = 0,
        .resolved = false,
        .record_evicted = false,
        .node = undefined,
    };
    defer control_data.arena.deinit();

    try std.testing.expect(!control_data.record_evicted);
    try std.testing.expect(!control_data.resolved);
    try std.testing.expectEqual(@as(usize, 0), control_data.tasks_finished);
}

test "should_fail_resolution_on_server_finish decision table (BUG-317)" {
    const control_data = try std.testing.allocator.create(ControlData);
    defer std.testing.allocator.destroy(control_data);
    control_data.* = ControlData{
        .allocator = std.testing.allocator,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .loop = undefined,
        .user_callbacks = .empty,
        .record = undefined,
        .queries_data = undefined,
        .tasks_finished = 0,
        .resolved = false,
        .record_evicted = false,
        .node = null,
    };
    defer control_data.arena.deinit();

    // Two nameservers outstanding: the first one failing must NOT end the
    // lookup (the second may still answer).
    var servers: [2]ServerQueryData = undefined;
    control_data.queries_data = servers[0..];
    try std.testing.expect(!should_fail_resolution_on_server_finish(control_data));

    // After the first server finished, the second one failing IS the end.
    control_data.tasks_finished = 1;
    try std.testing.expect(should_fail_resolution_on_server_finish(control_data));

    // Single-nameserver setups keep the old immediate-failure behavior.
    control_data.tasks_finished = 0;
    control_data.queries_data = servers[0..1];
    try std.testing.expect(should_fail_resolution_on_server_finish(control_data));

    // Never fail "again" once the lookup is already resolved.
    control_data.queries_data = servers[0..];
    control_data.resolved = true;
    try std.testing.expect(!should_fail_resolution_on_server_finish(control_data));
}

pub fn cleanup_server_query_data(ptr: ?*anyopaque) void {
    const server_data: *ServerQueryData = @ptrCast(@alignCast(ptr.?));
    server_data.release();
}
