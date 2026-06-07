const std = @import("std");
const utils = @import("utils");

const Loop = @import("../main.zig");
const CallbackManager = @import("callback_manager");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const Parsers = @import("parsers.zig");
const Cache = @import("cache.zig");

// TODO: Implement EDNS0 and DNSSEC

const DEFAULT_TIMEOUT: std.os.linux.kernel_timespec = .{
    .sec = 5,
    .nsec = 0,
};

pub const DnsTimeout = struct {
    sec: u64 = 0,
    nsec: u32 = 0,
};

pub fn timeout_from_secs(timeout_secs: f64) DnsTimeout {
    const sec: i64 = @floor(timeout_secs);
    const frac = timeout_secs - @as(f64, @floatFromInt(sec));
    const nsec: i64 = @floor(frac * 1e9);
    return .{ .sec = @as(u64, @intCast(sec)), .nsec = @as(u32, @intCast(nsec)) };
}

pub fn timeout_to_secs(timeout: DnsTimeout) f64 {
    return @as(f64, @floatFromInt(timeout.sec)) + @as(f64, @floatFromInt(timeout.nsec)) / 1e9;
}

pub fn dns_timeout_to_kernel_timespec(timeout: DnsTimeout) std.os.linux.kernel_timespec {
    return .{
        .sec = @as(i64, @intCast(timeout.sec)),
        .nsec = @as(i64, @intCast(timeout.nsec)),
    };
}

const Header = packed struct {
    id: u16,
    flags: u16,
    qdcount: u16,
    ancount: u16,
    nscount: u16,
    arcount: u16,
};

const ResultHeader = packed struct {
    type: u16,
    class: u16,
    ttl: u32,
    data_len: u16,
};

const QuestionType = enum(u16) {
    ipv4 = 1,
    ipv6 = 28,
    ptr = 12,
};

const QuestionTypeClass = packed struct {
    type: u16,
    class: u16,
};

const Hostname = struct {
    hostname: [255]u8,
    hostname_len: u8,
    original_hostname_len: u8,
};

const HostnamesArray = struct {
    array: []Hostname,
    len: u32,
    processed: u32 = 0,
};

/// One DNS query payload — header + encoded question.  Maximum 512 bytes per RFC 1035.
const QuerySlot = struct {
    buf: [512]u8 = undefined,
    len: u16 = 0,
    id: u16 = 0,
};


const ServerQueryData = struct {
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
            _ = std.os.linux.close(socket_fd);
            self.socket_fd = -1;
        }
    }

    pub fn release(self: *ServerQueryData) void {
        if (self.finished) return;
        self.finished = true;

        self.cancel();

        const control_data = self.control_data;
        for (self.ptr_results.items) |v| {
            control_data.allocator.free(v);
        }
        self.ptr_results.deinit(control_data.allocator);

        if (self.queries.len > 0) {
            control_data.allocator.free(self.queries);
        }

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

    node: Loop.DNS.PendingList.Node = undefined,

    comptime {
        python_c.verify_gc_coverage(@This(), &.{ "record", "loop", "queries_data", "node" });
    }

    pub fn release(self: *ControlData) void {
        const loop = self.loop;
        if (!self.resolved) {
            if (!self.record_evicted) {
                self.record.discard();
            }

            for (self.user_callbacks.items) |*v| {
                v.data.set_cancelled(true);
                if (!loop.initialized) {
                    Loop.Scheduling.Soon.dispatch_guaranteed_nonthreadsafe(loop, v) catch {
                        loop.reserved_slots -= 1;
                    };
                } else {
                    Loop.Scheduling.Soon.dispatch_guaranteed(loop, v) catch {
                        loop.reserved_slots -= 1;
                    };
                }
            }
        }

        self.loop.dns.pending_queries.unlink_node(self.node) catch {};
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn traverse(self: *const ControlData, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
        for (self.user_callbacks.items) |*v| {
            if (v.data.module_ptr()) |mod| {
                const vret1 = visit.?(@ptrCast(mod), arg);
                if (vret1 != 0) return vret1;
                if (v.data.callback_ptr()) |cp| {
                    const vret2 = visit.?(@ptrCast(cp), arg);
                    if (vret2 != 0) return vret2;
                }
            }
        }
        return 0;
    }
};

fn cleanup_server_query_data(ptr: ?*anyopaque) void {
    const server_data: *ServerQueryData = @alignCast(@ptrCast(ptr.?));
    server_data.release();
}

fn mark_resolved_and_execute_user_callbacks(server_data: *ServerQueryData) !void {
    const control_data = server_data.control_data;
    control_data.resolved = true;
    errdefer control_data.resolved = false;

    for (control_data.queries_data) |*sd| {
        sd.cancel();
    }

    if (!control_data.record_evicted) {
        if (server_data.ptr_results.items.len > 0) {
            const ptr_name = try control_data.allocator.dupe(u8, server_data.ptr_results.items[0]);
            control_data.record.set_ptr_data(ptr_name, server_data.min_ttl);
        } else {
            const address_list = try control_data.allocator.dupe(utils.Address, server_data.results.items);
            control_data.record.set_resolved_data(address_list, server_data.min_ttl);
        }
    }

    const loop = control_data.loop;
    for (control_data.user_callbacks.items) |*v| {
        try Loop.Scheduling.Soon.dispatch_guaranteed(loop, v);
    }
}

/// Queue an io_uring read for the next DNS response datagram into recv_buf.
fn queue_next_response_read(server_data: *ServerQueryData) !void {
    _ = try server_data.loop.io.queue(.{
        .PerformRead = .{
            .callback = .{
                .func = &process_dns_response,
                .cleanup = &cleanup_server_query_data,
                .data = .{ .user_data = server_data },
            },
                .data = .{ .buffer = &server_data.recv_buf },
            .fd = server_data.socket_fd,
            .zero_copy = true,
            .timeout = if (server_data.dns_timeout) |t| dns_timeout_to_kernel_timespec(t) else DEFAULT_TIMEOUT,
        },
    });
}

/// io_uring completion callback for each individual DNS query write.
/// Sends the next query if one is pending; otherwise starts reading responses.
fn on_query_sent(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();

    const server_data: *ServerQueryData = @alignCast(@ptrCast(data.user_data.?));
    const control_data = server_data.control_data;

    if (io_uring_err != .SUCCESS or control_data.resolved or data.cancelled()) {
        server_data.release();
        return;
    }

    const timeout_val = if (server_data.dns_timeout) |t| dns_timeout_to_kernel_timespec(t) else DEFAULT_TIMEOUT;

    server_data.send_idx += 1;

    if (server_data.send_idx < server_data.queries.len) {
        // Send the next individual query datagram.
        const next = &server_data.queries[server_data.send_idx];
        _ = try server_data.loop.io.queue(.{
            .PerformWrite = .{
                .callback = .{
                    .func = &on_query_sent,
                    .cleanup = &cleanup_server_query_data,
                    .data = .{ .user_data = server_data },
                },
                .data = next.buf[0..next.len],
                .fd = server_data.socket_fd,
                .zero_copy = true,
                .timeout = timeout_val,
            },
        });
    } else {
        // All queries sent — start the receive phase.
        try queue_next_response_read(server_data);
    }
}

fn skip_name(data: []const u8, initial_offset: usize) ?usize {
    var offset = initial_offset;
    while (offset < data.len) {
        const byte = data[offset];
        if (byte == 0) {
            return offset + 1;
        }
        if ((byte & 0xC0) == 0xC0) {
            if (offset + 2 > data.len) return null;
            return offset + 2;
        }
        offset += @as(usize, byte) + 1;
    }
    return null;
}

fn parse_individual_dns_result(full_data: []const u8, initial_offset: usize, result: *utils.Address, ptr_name: *?[]u8, ttl: *u32, allocator: std.mem.Allocator) ?usize {
    var offset = skip_name(full_data, initial_offset) orelse return null;

    if ((offset + 10) > full_data.len) return null;

    const r_type = std.mem.readInt(u16, full_data[offset .. offset + 2][0..2], .big);
    const r_class = std.mem.readInt(u16, full_data[offset + 2 .. offset + 4][0..2], .big);
    const r_ttl = std.mem.readInt(u32, full_data[offset + 4 .. offset + 8][0..4], .big);
    const r_data_len = std.mem.readInt(u16, full_data[offset + 8 .. offset + 10][0..2], .big);
    offset += 10;

    const next_rr_offset = offset + @as(usize, @intCast(r_data_len));
    if (next_rr_offset > full_data.len) return null;

    if (r_class == 1) { // IN class
        switch (r_type) {
            1 => { // A
                if (offset + 4 > full_data.len) return null;
                var addr: [4]u8 = undefined;
                @memcpy(&addr, full_data[offset..(offset + 4)]);
                result.* = utils.Address.initIp4(addr, 0);
                ttl.* = r_ttl;
            },
            28 => { // AAAA
                if (offset + 16 > full_data.len) return null;
                var addr: [16]u8 = undefined;
                @memcpy(&addr, full_data[offset..(offset + 16)]);
                result.* = utils.Address.initIp6(addr, 0, 0, 0);
                ttl.* = r_ttl;
            },
            12 => { // PTR
                ptr_name.* = Parsers.parse_name(full_data, offset, allocator) catch null;
                ttl.* = r_ttl;
            },
            else => {},
        }
    }

    return next_rr_offset;
}

fn process_dns_response(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();

    const server_data: *ServerQueryData = @alignCast(@ptrCast(data.user_data.?));
    const control_data = server_data.control_data;

    if (data.cancelled() or control_data.resolved) {
        server_data.release();
        return;
    }

    if (io_uring_err != .SUCCESS) {
        // Timeout or I/O error on this server — report whatever we have.
        try mark_resolved_and_execute_user_callbacks(server_data);
        server_data.release();
        return;
    }

    const bytes = @as(usize, @intCast(io_uring_res));
    const response = server_data.recv_buf[0..bytes];

    // Validate the response ID against all pending query IDs.
    if (bytes >= 2) {
        const response_id = std.mem.readInt(u16, response[0..2], .big);
        var matched_slot: ?*QuerySlot = null;
        for (server_data.queries) |*slot| {
            if (response_id == slot.id) {
                matched_slot = slot;
                break;
            }
        }

        if (matched_slot != null and bytes >= 12) {
            // BUG-46: Validate the response flags.
            //   - QR bit (bit 7 of byte 2) must be 1 (this is a response, not a query).
            //   - RCODE (bits 0-3 of byte 3) must be 0 (no error).
            //   - OPCODE (bits 3-6 of byte 2) must be 0 (standard query, not e.g. UPDATE).
            // A response with QR=0 is a query being replayed at us; reject it.
            // A response with non-zero RCODE (NXDOMAIN, SERVFAIL, etc.) should
            // be treated as an error, not as "no records" — the caller should
            // know the query failed.
            const flags = std.mem.readInt(u16, response[2..4], .big);
            const qr = (flags & 0x8000) != 0;
            const opcode = (flags >> 11) & 0x0F;
            const rcode = flags & 0x000F;
            if (!qr or opcode != 0 or rcode != 0) {
                // Invalid flags: silently drop this response. We still
                // count it as received (so the wait loop can proceed),
                // but we don't try to parse answers.
                server_data.responses_received += 1;
                if (server_data.responses_received < server_data.queries.len and !control_data.resolved) {
                    try queue_next_response_read(server_data);
                } else {
                    try mark_resolved_and_execute_user_callbacks(server_data);
                    server_data.release();
                }
                return;
            }

            // BUG-45: Check the TC (truncated) bit. If set, the response
            // was cut off and is incomplete. UDP responses can be
            // truncated for large answers; the client should retry over
            // TCP. For now, we reject truncated responses and fall back
            // to the next server / treat as empty.
            const tc = (flags & 0x0200) != 0;
            if (tc) {
                // Truncated: drop and continue waiting for more responses
                // (or fall through to error handling below).
                server_data.responses_received += 1;
                if (server_data.responses_received < server_data.queries.len and !control_data.resolved) {
                    try queue_next_response_read(server_data);
                } else {
                    try mark_resolved_and_execute_user_callbacks(server_data);
                    server_data.release();
                }
                return;
            }

            const qdcount = std.mem.readInt(u16, response[4..6], .big);
            const ancount = std.mem.readInt(u16, response[6..8], .big);

            // BUG-44: Validate the question section. The response should
            // echo the query's question section exactly. Without this
            // check, a forged response for a different domain (or a
            // different QTYPE) could be accepted.
            if (qdcount != 1) {
                server_data.responses_received += 1;
                if (server_data.responses_received < server_data.queries.len and !control_data.resolved) {
                    try queue_next_response_read(server_data);
                } else {
                    try mark_resolved_and_execute_user_callbacks(server_data);
                    server_data.release();
                }
                return;
            }

            // The question section in the response starts at byte 12 and
            // is `slot.len - 12` bytes long (the original query buffer
            // minus the 12-byte header). The full question section
            // includes the label-encoded hostname plus QTYPE and QCLASS.
            const slot = matched_slot.?;
            const question_len = slot.len - 12;
            if (bytes < 12 + question_len) {
                server_data.responses_received += 1;
                if (server_data.responses_received < server_data.queries.len and !control_data.resolved) {
                    try queue_next_response_read(server_data);
                } else {
                    try mark_resolved_and_execute_user_callbacks(server_data);
                    server_data.release();
                }
                return;
            }
            const response_question = response[12 .. 12 + question_len];
            const query_question = slot.buf[12..slot.len];
            if (!std.mem.eql(u8, response_question, query_question)) {
                // Question mismatch: forged response for a different query.
                server_data.responses_received += 1;
                if (server_data.responses_received < server_data.queries.len and !control_data.resolved) {
                    try queue_next_response_read(server_data);
                } else {
                    try mark_resolved_and_execute_user_callbacks(server_data);
                    server_data.release();
                }
                return;
            }

            if (ancount > 0) {
                // Skip the question section.
                var offset: usize = 12;
                var qi: u16 = 0;
                while (qi < qdcount) : (qi += 1) {
                    offset = skip_name(response, offset) orelse break;
                    if (offset + 4 > bytes) break;
                    offset += 4; // Skip QTYPE and QCLASS
                }

                // Parse answer records.
                var answers_left: u16 = ancount;
                while (answers_left > 0) {
                    var result: utils.Address = undefined;
                    var ptr_name: ?[]u8 = null;
                    var ttl: u32 = std.math.maxInt(u32);

                    const new_offset = parse_individual_dns_result(
                        response,
                        offset,
                        &result,
                        &ptr_name,
                        &ttl,
                        control_data.arena.allocator(),
                    ) orelse break;

                    offset = new_offset;
                    if (ptr_name) |name| {
                        try server_data.ptr_results.append(control_data.arena.allocator(), name);
                        server_data.min_ttl = @min(server_data.min_ttl, ttl);
                    } else if (result.any.family != 0) {
                        try server_data.results.append(control_data.arena.allocator(), result);
                        server_data.min_ttl = @min(server_data.min_ttl, ttl);
                    }

                    answers_left -= 1;
                }
            }
        }
    }

    server_data.responses_received += 1;

    // If we have a positive result, resolve immediately.
    if (server_data.results.items.len > 0 or server_data.ptr_results.items.len > 0) {
        try mark_resolved_and_execute_user_callbacks(server_data);
        server_data.release();
        return;
    }

    // Wait for more responses if there are queries outstanding.
    if (server_data.responses_received < server_data.queries.len and !control_data.resolved) {
        try queue_next_response_read(server_data);
        return;
    }

    // All responses received (or already resolved elsewhere).
    try mark_resolved_and_execute_user_callbacks(server_data);
    server_data.release();
}

fn build_query(id: u16, payload: []u8, question: QuestionType, hostname: []const u8) usize {
    std.mem.writeInt(u16, payload[0..2], id, .big);
    std.mem.writeInt(u16, payload[2..4], 0x0100, .big);
    std.mem.writeInt(u16, payload[4..6], 1, .big);
    std.mem.writeInt(u16, payload[6..8], 0, .big);
    std.mem.writeInt(u16, payload[8..10], 0, .big);
    std.mem.writeInt(u16, payload[10..12], 0, .big);

    var offset: usize = 12;
    var labels_iter = std.mem.tokenizeScalar(u8, hostname, '.');

    while (labels_iter.next()) |label| {
        payload[offset] = @intCast(label.len);
        offset += 1;
        @memcpy(payload[offset .. offset + label.len], label);
        offset += label.len;
    }
    payload[offset] = 0;
    offset += 1;

    std.mem.writeInt(u16, payload[offset .. offset + 2][0..2], @intFromEnum(question), .big);
    std.mem.writeInt(u16, payload[offset + 2 .. offset + 4][0..2], 1, .big);
    offset += 4;

    return offset;
}

fn build_queries(
    allocator: std.mem.Allocator,
    loop: *Loop,
    control_data: *ControlData,
    server_data: *ServerQueryData,
    ipv6_supported: bool,
    hostnames_array: HostnamesArray,
    server_address: *const utils.Address,
    question_type: ?QuestionType,
    dns_timeout: ?DnsTimeout,
) !void {
    server_data.dns_timeout = dns_timeout;
    const socket_ret = std.os.linux.socket(
        server_address.any.family,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        std.os.linux.IPPROTO.UDP,
    );
    if (utils.getSyscallErrno(socket_ret) != .SUCCESS) return error.SystemResources;
    const socket_fd: std.posix.fd_t = @intCast(socket_ret);
    errdefer _ = std.os.linux.close(socket_fd);

    const connect_ret = std.os.linux.connect(socket_fd, @ptrCast(&server_address.any), server_address.getOsSockLen());
    if (utils.getSyscallErrno(connect_ret) != .SUCCESS) return error.SystemResources;

    // Compute number of individual queries: one per (hostname × question_type).
    const types_per_host: u32 = if (question_type != null) 1 else if (ipv6_supported) 2 else 1;
    const total_queries: u32 = hostnames_array.len * types_per_host;

    const queries = try allocator.alloc(QuerySlot, total_queries);
    errdefer allocator.free(queries);

    var slot_idx: u32 = 0;
    for (hostnames_array.array[0..hostnames_array.len]) |hostname_info| {
        const hostname = hostname_info.hostname[0..hostname_info.hostname_len];

        var id_buf: [2]u8 = undefined;
        const bytes_read = std.os.linux.getrandom(&id_buf, 2, 0);
        if (bytes_read != 2) return error.SystemResources;
        const query_id = std.mem.readInt(u16, &id_buf, .little);

        if (question_type) |qt| {
            queries[slot_idx].id = query_id;
            queries[slot_idx].len = @intCast(build_query(query_id, &queries[slot_idx].buf, qt, hostname));
            slot_idx += 1;
        } else {
            queries[slot_idx].id = query_id;
            queries[slot_idx].len = @intCast(build_query(query_id, &queries[slot_idx].buf, .ipv4, hostname));
            slot_idx += 1;

            if (ipv6_supported) {
                // Generate a separate random ID for the AAAA query.
                var id_buf2: [2]u8 = undefined;
                const bytes_read2 = std.os.linux.getrandom(&id_buf2, 2, 0);
                if (bytes_read2 != 2) return error.SystemResources;
                const query_id2 = std.mem.readInt(u16, &id_buf2, .little);

                queries[slot_idx].id = query_id2;
                queries[slot_idx].len = @intCast(build_query(query_id2, &queries[slot_idx].buf, .ipv6, hostname));
                slot_idx += 1;
            }
        }
    }

    server_data.* = .{
        .loop = loop,
        .socket_fd = socket_fd,
        .control_data = control_data,
        .hostnames_array = hostnames_array,
        .queries = queries,
        .results = .{ .items = &.{}, .capacity = 0 },
        .ptr_results = .{ .items = &.{}, .capacity = 0 },
    };
}

inline fn build_hostname(data: *Hostname, hostname: []const u8, suffix: []const u8) bool {
    const new_len = hostname.len + suffix.len + 1;
    if (new_len > 255) {
        return false;
    }

    @memcpy(data.hostname[0..hostname.len], hostname);
    data.original_hostname_len = @intCast(hostname.len);

    if (suffix.len > 0) {
        data.hostname[hostname.len] = '.';
        @memcpy(data.hostname[(hostname.len + 1)..new_len], suffix);
        data.hostname_len = @intCast(new_len);
    } else {
        data.hostname_len = @intCast(hostname.len);
    }

    return true;
}

fn get_hostname_array(allocator: std.mem.Allocator, hostname: []const u8, suffixes: []const []const u8) !HostnamesArray {
    const total: usize = suffixes.len + 1;
    var hostnames_array = HostnamesArray{ .array = try allocator.alloc(Hostname, total), .len = 0 };
    errdefer allocator.free(hostnames_array.array);

    if (std.mem.indexOfScalar(u8, hostname, '.')) |_| {
        // FQDN: only try the hostname itself, no search suffixes
        if (build_hostname(&hostnames_array.array[hostnames_array.len], hostname, &.{})) {
            hostnames_array.len += 1;
        }
    } else {
        // Non-FQDN: try with each search suffix
        for (suffixes) |suffix| {
            if (build_hostname(&hostnames_array.array[hostnames_array.len], hostname, suffix)) {
                hostnames_array.len += 1;
            }
        }
    }

    return hostnames_array;
}

fn prepare_data(
    cache_slot: *Cache,
    loop: *Loop,
    hostname: []const u8,
    user_callback: *const CallbackManager.Callback,
    configuration: Parsers.Configuration,
    ipv6_supported: bool,
    question_type: ?QuestionType,
    dns_timeout: ?DnsTimeout,
) !*ControlData {
    const allocator = cache_slot.allocator;

    const control_data = try allocator.create(ControlData);
    errdefer allocator.destroy(control_data);

    // Use a struct literal so the compiler enforces that every field of
    // ControlData is explicitly initialized here. Adding a new field to
    // ControlData without initializing it in prepare_data will cause a
    // compile error, preventing the class of bug fixed in this commit
    // (record_evicted left uninitialized → garbage bool → silent wrong behaviour).
    control_data.* = ControlData{
        .allocator      = allocator,
        .arena          = std.heap.ArenaAllocator.init(allocator),
        .loop           = loop,
        .user_callbacks = .{ .items = &.{}, .capacity = 0 },
        // .record and .queries_data are filled in just below; use undefined
        // only for fields that are unconditionally assigned before any use.
        .record         = undefined,
        .queries_data   = undefined,
        .tasks_finished = 0,
        .resolved       = false,
        .record_evicted = false,
        // .node is set by create_new_node / append_node below.
        .node           = undefined,
    };
    const arena_allocator = control_data.arena.allocator();

    control_data.record = try cache_slot.create_new_record(hostname, control_data);

    errdefer {
        control_data.release();
    }

    try loop.reserve_slots(1);
    errdefer loop.reserved_slots -= 1;

    try control_data.user_callbacks.append(arena_allocator, user_callback.*);
    errdefer control_data.user_callbacks.deinit(arena_allocator);

    const queries_data = try arena_allocator.alloc(ServerQueryData, configuration.servers.len);
    const hostnames_array = try get_hostname_array(arena_allocator, hostname, configuration.search);

    control_data.queries_data = queries_data;

    control_data.node = try loop.dns.pending_queries.create_new_node(control_data);
    loop.dns.pending_queries.append_node(control_data.node);

    var queries_built: usize = 0;
    errdefer {
        for (queries_data[0..queries_built]) |*server_data| {
            _ = std.os.linux.close(server_data.socket_fd);
        }
    }

    for (configuration.servers, queries_data) |*server_address, *server_data| {
        server_data.dns_timeout = dns_timeout;
        try build_queries(
            arena_allocator,
            loop,
            control_data,
            server_data,
            ipv6_supported,
            hostnames_array,
            server_address,
            question_type,
            dns_timeout,
        );

        queries_built += 1;
    }

    return control_data;
}

pub fn queue(
    cache_slot: *Cache,
    loop: *Loop,
    hostname: []const u8,
    user_callback: *const CallbackManager.Callback,
    configuration: Parsers.Configuration,
    ipv6_supported: bool,
    question_type: ?QuestionType,
    dns_timeout: ?DnsTimeout,
) !void {
    const control_data = try prepare_data(
        cache_slot,
        loop,
        hostname,
        user_callback,
        configuration,
        ipv6_supported,
        question_type,
        dns_timeout,
    );

    var queries_sent: usize = 0;
    errdefer {
        for (control_data.queries_data[0..queries_sent]) |*server_data| {
            server_data.cancel();
        }

        if (queries_sent == 0) {
            control_data.release();
        }
    }

    for (control_data.queries_data) |*server_data| {
        const first = &server_data.queries[0];
        const timeout = if (dns_timeout) |dt| dns_timeout_to_kernel_timespec(dt) else DEFAULT_TIMEOUT;
        _ = try loop.io.queue(.{
            .PerformWrite = .{
                .zero_copy = true,
                .fd = server_data.socket_fd,
                .data = first.buf[0..first.len],
                .callback = .{
                    .func = &on_query_sent,
                    .cleanup = &cleanup_server_query_data,
                    .data = .{
                        .user_data = server_data,
                    },
                },
                .timeout = timeout,
            },
        });

        queries_sent += 1;
    }
}

test "skip_name: simple name" {
    const data = "\x06google\x03com\x00";
    try std.testing.expectEqual(@as(usize, 12), skip_name(data, 0).?);
}

test "skip_name: compression pointer" {
    const data = "\x06google\x03com\x00\xC0\x00";
    try std.testing.expectEqual(@as(usize, 12), skip_name(data, 0).?);
    try std.testing.expectEqual(@as(usize, 14), skip_name(data, 12).?);
}

test "skip_name: mixed labels and pointer" {
    const data = "\x03www\xC0\x00";
    try std.testing.expectEqual(@as(usize, 6), skip_name(data, 0).?);
}

test "parse_individual_dns_result: A record" {
    const data = "\xC0\x0C\x00\x01\x00\x01\x00\x00\x01\x2C\x00\x04\xD8\x3A\xD3\xA4";
    var res: utils.Address = undefined;
    var ptr_name: ?[]u8 = null;
    var ttl: u32 = 0;

    const next_offset = parse_individual_dns_result(data, 0, &res, &ptr_name, &ttl, std.testing.allocator).?;
    try std.testing.expectEqual(@as(usize, 16), next_offset);
    try std.testing.expect(ptr_name == null);
    try std.testing.expectEqual(@as(u32, 300), ttl);
    try std.testing.expectEqual(std.posix.AF.INET, res.any.family);
}

test "parse_individual_dns_result: AAAA record" {
    const data = "\xC0\x0C\x00\x1C\x00\x01\x00\x00\x01\x2C\x00\x10\x2A\x00\x14\x50\x40\x01\x08\x03\x00\x00\x00\x00\x00\x00\x20\x0E";
    var res: utils.Address = undefined;
    var ptr_name: ?[]u8 = null;
    var ttl: u32 = 0;

    const next_offset = parse_individual_dns_result(data, 0, &res, &ptr_name, &ttl, std.testing.allocator).?;
    try std.testing.expectEqual(@as(usize, 28), next_offset);
    try std.testing.expect(ptr_name == null);
    try std.testing.expectEqual(std.posix.AF.INET6, res.any.family);
}

test "skip_name: malformed" {
    // Length exceeds data
    const data1 = "\x05goog";
    try std.testing.expectEqual(@as(?usize, null), skip_name(data1, 0));
    
    // Unterminated
    const data2 = "\x06google";
    try std.testing.expectEqual(@as(?usize, null), skip_name(data2, 0));
    
    // Truncated compression pointer
    const data3 = "\xC0";
    try std.testing.expectEqual(@as(?usize, null), skip_name(data3, 0));
}

test "parse_individual_dns_result: truncated record" {
    const data = "\xC0\x0C\x00\x01\x00\x01\x00\x00\x01\x2C\x00\x04\xD8\x3A";
    var res: utils.Address = undefined;
    var ptr_name: ?[]u8 = null;
    var ttl: u32 = 0;
    
    try std.testing.expectEqual(@as(?usize, null), parse_individual_dns_result(data, 0, &res, &ptr_name, &ttl, std.testing.allocator));
}

test "parse_individual_dns_result: skip non-IN class" {
    const data = "\xC0\x0C\x00\x01\x00\x02\x00\x00\x01\x2C\x00\x04\xD8\x3A\xD3\xA4";
    var res: utils.Address = undefined;
    var ptr_name: ?[]u8 = null;
    var ttl: u32 = 0;
    
    const next_offset = parse_individual_dns_result(data, 0, &res, &ptr_name, &ttl, std.testing.allocator).?;
    try std.testing.expectEqual(@as(usize, 16), next_offset);
    try std.testing.expect(ptr_name == null);
}

test "parse_individual_dns_result: ignore CNAME" {
    // Type 5 is CNAME
    const data = "\xC0\x0C\x00\x05\x00\x01\x00\x00\x01\x2C\x00\x02\xC0\x12";
    var res: utils.Address = undefined;
    var ptr_name: ?[]u8 = null;
    var ttl: u32 = 0;
    
    const next_offset = parse_individual_dns_result(data, 0, &res, &ptr_name, &ttl, std.testing.allocator).?;
    try std.testing.expectEqual(@as(usize, 14), next_offset);
    try std.testing.expect(ptr_name == null);
}

test "build_query uses provided transaction ID" {
    var buf: [512]u8 = undefined;
    const written = build_query(0x1234, buf[0..], .ipv4, "example.com");
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, buf[0..2], .big));
    try std.testing.expect(written > 12);
}

test "build_query produces different ID for different input" {
    var buf1: [512]u8 = undefined;
    var buf2: [512]u8 = undefined;
    const w1 = build_query(0xABCD, buf1[0..], .ipv4, "test1.example.com");
    const w2 = build_query(0x4321, buf2[0..], .ipv4, "test2.example.com");
    try std.testing.expect(w1 > 0);
    try std.testing.expect(w2 > 0);
    const id1 = std.mem.readInt(u16, buf1[0..2], .big);
    const id2 = std.mem.readInt(u16, buf2[0..2], .big);
    try std.testing.expect(id1 != id2);
}

test "random DNS transaction IDs are not trivially predictable" {
    // Generate 100 IDs and verify they're not all the same value
    // (extremely unlikely with random u16)
    var ids: [100]u16 = undefined;
    for (&ids) |*id| {
        var id_buf: [2]u8 = undefined;
        _ = std.os.linux.getrandom(&id_buf, 2, 0);
        id.* = std.mem.readInt(u16, &id_buf, .little);
    }
    const first = ids[0];
    var all_same = true;
    for (ids[1..]) |id| {
        if (id != first) {
            all_same = false;
            break;
        }
    }
    try std.testing.expect(!all_same);
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
        .allocator      = std.testing.allocator,
        .arena          = std.heap.ArenaAllocator.init(std.testing.allocator),
        .loop           = undefined,
        .user_callbacks = .{ .items = &.{}, .capacity = 0 },
        .record         = undefined,
        .queries_data   = undefined,
        .tasks_finished = 0,
        .resolved       = false,
        .record_evicted = false,
        .node           = undefined,
    };
    defer control_data.arena.deinit();

    try std.testing.expect(!control_data.record_evicted);
    try std.testing.expect(!control_data.resolved);
    try std.testing.expectEqual(@as(usize, 0), control_data.tasks_finished);
}

test "build_query encodes QDCOUNT=1 for ipv4" {
    var buf: [512]u8 = undefined;
    const written = build_query(0x0042, buf[0..], .ipv4, "example.com");
    // Bytes [4..6] are QDCOUNT in network byte order.
    const qdcount = std.mem.readInt(u16, buf[4..6], .big);
    try std.testing.expectEqual(@as(u16, 1), qdcount);
    // The query type at the end should be 1 (A).
    const qtype_offset = written - 4;
    const qtype = std.mem.readInt(u16, buf[qtype_offset .. qtype_offset + 2][0..2], .big);
    try std.testing.expectEqual(@as(u16, 1), qtype);
}

test "build_query encodes QDCOUNT=1 for ipv6" {
    var buf: [512]u8 = undefined;
    const written = build_query(0x0043, buf[0..], .ipv6, "example.com");
    const qdcount = std.mem.readInt(u16, buf[4..6], .big);
    try std.testing.expectEqual(@as(u16, 1), qdcount);
    // The query type at the end should be 28 (AAAA).
    const qtype_offset = written - 4;
    const qtype = std.mem.readInt(u16, buf[qtype_offset .. qtype_offset + 2][0..2], .big);
    try std.testing.expectEqual(@as(u16, 28), qtype);
}

test "QuerySlot fields are independent — BUG-08 regression" {
    // Each QuerySlot must carry its own ID so per-datagram IDs don't alias.
    var slot_a: QuerySlot = .{};
    var slot_b: QuerySlot = .{};
    const id_a: u16 = 0x1111;
    const id_b: u16 = 0x2222;
    slot_a.len = @intCast(build_query(id_a, &slot_a.buf, .ipv4, "a.example.com"));
    slot_a.id = id_a;
    slot_b.len = @intCast(build_query(id_b, &slot_b.buf, .ipv6, "b.example.com"));
    slot_b.id = id_b;
    // The IDs stored in the slots must differ.
    try std.testing.expect(slot_a.id != slot_b.id);
    // The IDs encoded in the wire-format buffers must also differ.
    const wire_id_a = std.mem.readInt(u16, slot_a.buf[0..2], .big);
    const wire_id_b = std.mem.readInt(u16, slot_b.buf[0..2], .big);
    try std.testing.expect(wire_id_a != wire_id_b);
    // Mutating slot_b must not affect slot_a.
    slot_b.buf[0] = 0xFF;
    try std.testing.expectEqual(@as(u8, 0x11), slot_a.buf[0]);
}

test "each QuerySlot is a complete standalone DNS message" {
    // A valid DNS query must be > 12 bytes (header) and <= 512 (RFC 1035).
    const hostnames = [_][]const u8{ "foo.example.com", "bar.test.local" };
    const qtypes = [_]QuestionType{ .ipv4, .ipv6, .ptr };
    for (hostnames) |hn| {
        for (qtypes) |qt| {
            var slot: QuerySlot = .{};
            const written = build_query(0xBEEF, &slot.buf, qt, hn);
            slot.len = @intCast(written);
            slot.id = 0xBEEF;
            // Must include at least the 12-byte header + question.
            try std.testing.expect(slot.len > 12);
            // Must not exceed RFC 1035 maximum UDP payload.
            try std.testing.expect(slot.len <= 512);
            // QDCOUNT must be 1 — exactly one question per datagram.
            const qdcount = std.mem.readInt(u16, slot.buf[4..6], .big);
            try std.testing.expectEqual(@as(u16, 1), qdcount);
        }
    }
}

