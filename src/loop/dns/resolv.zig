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

const ResponseProcessingState = enum {
    process_header,
    process_body,
};

const ServerQueryData = struct {
    loop: *Loop,

    socket_fd: std.posix.fd_t,

    hostnames_array: HostnamesArray,

    control_data: *ControlData,

    payload: []u8,
    payload_len: usize,
    payload_offset: usize = 0,

    results: std.ArrayList(utils.Address),
    ptr_results: std.ArrayList([]u8),
    results_to_process: u16 = 0,

    min_ttl: u32 = std.math.maxInt(u32),
    finished: bool = false,

    query_ids: []u16 = &.{},

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

        if (self.query_ids.len > 0) {
            control_data.allocator.free(self.query_ids);
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

fn check_send_operation_result(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();

    const server_data: *ServerQueryData = @alignCast(@ptrCast(data.user_data.?));

    const control_data = server_data.control_data;
    if (io_uring_err != .SUCCESS or control_data.resolved or data.cancelled()) {
        return;
    }

    const data_sent = server_data.payload_offset + @as(usize, @intCast(io_uring_res));
    server_data.payload_offset = data_sent;

    var operation_data: Loop.Scheduling.IO.BlockingOperationData = undefined;

    const payload_len = server_data.payload_len;
    if (data_sent == payload_len) {
        server_data.payload_offset = 0;
        server_data.payload_len = 0;

        operation_data = .{
            .PerformRead = .{
                .callback = .{
                    .func = &process_dns_response,
                    .cleanup = &cleanup_server_query_data,
                    .data = .{
                        .user_data = server_data,
                    },
                },
                .data = .{
                    .buffer = server_data.payload,
                },
                .fd = server_data.socket_fd,
                .zero_copy = true,
                .timeout = DEFAULT_TIMEOUT,
            },
        };
    } else if (data_sent < payload_len) {
        operation_data = .{
            .PerformWrite = .{
                .callback = .{
                    .func = &check_send_operation_result,
                    .cleanup = &cleanup_server_query_data,
                    .data = .{
                        .user_data = server_data,
                    },
                },
                .data = server_data.payload[data_sent..payload_len],
                .fd = server_data.socket_fd,
                .zero_copy = true,
                .timeout = DEFAULT_TIMEOUT,
            },
        };
    } else {
        return error.UnexpectedState;
    }

    _ = try server_data.loop.io.queue(operation_data);
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
    if (io_uring_err != .SUCCESS or control_data.resolved or data.cancelled()) {
        server_data.release();
        return;
    }

    const data_received = server_data.payload_len + @as(usize, @intCast(io_uring_res));
    server_data.payload_len = data_received;

    var offset = server_data.payload_offset;

    const hostnames_len = server_data.hostnames_array.len;
    var hostnames_processed = server_data.hostnames_array.processed;

    const response = server_data.payload;

    var results_to_process: u16 = server_data.results_to_process;

    var state: ResponseProcessingState = ResponseProcessingState.process_header;
    if (results_to_process > 0) {
        state = ResponseProcessingState.process_body;
    }

    while (true) {
        switch (state) {
            .process_header => {
                if (data_received - offset >= 12) {
                    const response_id = std.mem.readInt(u16, response[offset .. offset + 2][0..2], .big);
                    const qdcount = std.mem.readInt(u16, response[offset + 4 .. offset + 6][0..2], .big);
                    const ancount = std.mem.readInt(u16, response[offset + 6 .. offset + 8][0..2], .big);

                    var id_valid = false;
                    for (server_data.query_ids) |expected_id| {
                        if (response_id == expected_id) {
                            id_valid = true;
                            break;
                        }
                    }
                    if (!id_valid) {
                        server_data.release();
                        return;
                    }

                    offset += 12;

                    if (ancount == 0) {
                        hostnames_processed = hostnames_len;
                    } else {
                        // Skip all questions
                        var i: u16 = 0;
                        while (i < qdcount) : (i += 1) {
                            offset = skip_name(response[0..data_received], offset) orelse {
                                return;
                            };

                            if (offset + 4 > data_received) {
                                return;
                            }

                            offset += 4; // Skip QTYPE and QCLASS
                        }

                        results_to_process = ancount;
                        state = ResponseProcessingState.process_body;
                        continue;
                    }
                }
            },
            .process_body => while (results_to_process > 0) {
                var result: utils.Address = undefined;
                var ptr_name: ?[]u8 = null;
                var ttl: u32 = std.math.maxInt(u32);

                const new_offset = parse_individual_dns_result(
                    response[0..data_received],
                    offset,
                    &result,
                    &ptr_name,
                    &ttl,
                    server_data.control_data.arena.allocator(),
                ) orelse break;

                offset = new_offset;
                if (ptr_name) |name| {
                    try server_data.ptr_results.append(server_data.control_data.arena.allocator(), name);
                    server_data.min_ttl = @min(server_data.min_ttl, ttl);
                } else if (result.any.family != 0) {
                    try server_data.results.append(server_data.control_data.arena.allocator(), result);
                    server_data.min_ttl = @min(server_data.min_ttl, ttl);
                }

                results_to_process -= 1;
            },
        }
        break;
    }
    server_data.payload_offset = offset;
    server_data.hostnames_array.processed = hostnames_processed;
    server_data.results_to_process = results_to_process;

    if (server_data.results.items.len > 0 or server_data.ptr_results.items.len > 0) {
        try mark_resolved_and_execute_user_callbacks(server_data);
    }
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
) !void {
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

    const payload = try allocator.alloc(u8, (1 + @as(usize, @intFromBool(ipv6_supported))) * 512 * hostnames_array.len);
    errdefer allocator.free(payload);

    const query_ids = try allocator.alloc(u16, hostnames_array.len);
    errdefer allocator.free(query_ids);

    var offset: usize = 0;
    for (hostnames_array.array[0..hostnames_array.len], 0..) |hostname_info, idx| {
        const hostname = hostname_info.hostname[0..hostname_info.hostname_len];
        var id_buf: [2]u8 = undefined;
        const bytes_read = std.os.linux.getrandom(&id_buf, 2, 0);
        if (bytes_read != 2) return error.SystemResources;
        const query_id = std.mem.readInt(u16, &id_buf, .little);
        query_ids[idx] = query_id;
        if (question_type) |qt| {
            offset += build_query(query_id, payload[offset..], qt, hostname);
        } else {
            offset += build_query(query_id, payload[offset..], .ipv4, hostname);
            if (ipv6_supported) {
                offset += build_query(query_id, payload[offset..], .ipv6, hostname);
            }
        }
    }

    server_data.* = .{
        .loop = loop,

        .payload = payload,

        .socket_fd = socket_fd,
        .payload_len = offset,

        .control_data = control_data,
        .hostnames_array = hostnames_array,

        .results = .{ .items = &.{}, .capacity = 0 },
        .ptr_results = .{ .items = &.{}, .capacity = 0 },

        .query_ids = query_ids,
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
) !*ControlData {
    const allocator = cache_slot.allocator;

    const control_data = try allocator.create(ControlData);
    errdefer allocator.destroy(control_data);

    control_data.allocator = allocator;
    control_data.arena = std.heap.ArenaAllocator.init(allocator);
    control_data.loop = loop;
    const arena_allocator = control_data.arena.allocator();

    control_data.user_callbacks = .{ .items = &.{}, .capacity = 0 };
    control_data.record = try cache_slot.create_new_record(hostname, control_data);

    control_data.resolved = false;
    control_data.tasks_finished = 0;
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
        try build_queries(
            arena_allocator,
            loop,
            control_data,
            server_data,
            ipv6_supported,
            hostnames_array,
            server_address,
            question_type,
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
) !void {
    const control_data = try prepare_data(
        cache_slot,
        loop,
        hostname,
        user_callback,
        configuration,
        ipv6_supported,
        question_type,
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
        _ = try loop.io.queue(.{
            .PerformWrite = .{
                .zero_copy = true,
                .fd = server_data.socket_fd,
                .data = server_data.payload[0..server_data.payload_len],
                .callback = .{
                    .func = &check_send_operation_result,
                    .cleanup = &cleanup_server_query_data,
                    .data = .{
                        .user_data = server_data,
                    },
                },
                .timeout = DEFAULT_TIMEOUT,
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

