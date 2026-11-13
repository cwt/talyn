const std = @import("std");
const utils = @import("utils");
const Loop = @import("../../main.zig");
const types = @import("types.zig");
const ControlData = types.ControlData;
const ServerQueryData = types.ServerQueryData;
const Hostname = types.Hostname;
const HostnamesArray = types.HostnamesArray;
const QuerySlot = types.QuerySlot;
const QuestionType = types.QuestionType;
const DnsTimeout = types.DnsTimeout;
const Parsers = @import("../parsers.zig");
const Cache = @import("../cache.zig");

pub fn skip_name(data: []const u8, initial_offset: usize) ?usize {
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
        if ((byte & 0xC0) != 0) return null;
        if (offset + 1 + byte > data.len) return null;
        offset += @as(usize, byte) + 1;
    }
    return null;
}

pub fn parse_individual_dns_result(full_data: []const u8, initial_offset: usize, result: *utils.Address, ptr_name: *?[]u8, ttl: *u32, allocator: std.mem.Allocator) ?usize {
    result.* = .{ .any = .{ .family = 0, .data = @splat(0) } };
    ptr_name.* = null;
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
            else => return next_rr_offset,
        }
    }

    return next_rr_offset;
}

pub fn build_query(id: u16, payload: []u8, question: QuestionType, hostname: []const u8) usize {
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

pub fn build_queries(
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
    const socket_err = utils.getSyscallErrno(socket_ret);
    if (socket_err != .SUCCESS) return utils.socketSyscallError(socket_err);
    const socket_fd: std.posix.fd_t = @intCast(socket_ret);
    errdefer _ = std.os.linux.close(socket_fd);

    const connect_ret = std.os.linux.connect(socket_fd, @ptrCast(&server_address.any), server_address.getOsSockLen());
    const connect_err = utils.getSyscallErrno(connect_ret);
    if (connect_err != .SUCCESS) return utils.socketSyscallError(connect_err);

    // Compute number of individual queries: one per (hostname × question_type).
    const types_per_host: u32 = if (question_type != null) 1 else if (ipv6_supported) 2 else 1;
    const total_queries: u32 = hostnames_array.len * types_per_host;

    const queries = try allocator.alloc(QuerySlot, total_queries);
    errdefer allocator.free(queries);

    // BUG-433: one response-credit counter per candidate hostname.
    const responses_per_hostname = try allocator.alloc(u16, hostnames_array.len);
    errdefer allocator.free(responses_per_hostname);
    @memset(responses_per_hostname, 0);

    var id_buf_stack: [32]u16 = undefined;
    const id_buf = if (total_queries <= 32)
        id_buf_stack[0..total_queries]
    else
        try allocator.alloc(u16, total_queries);
    defer if (total_queries > 32) allocator.free(id_buf);

    const total_bytes = total_queries * @sizeOf(u16);
    const bytes_read = std.os.linux.getrandom(@ptrCast(id_buf.ptr), total_bytes, 0);
    if (bytes_read != @as(usize, total_bytes)) return error.SystemResources;

    var slot_idx: u32 = 0;
    for (hostnames_array.array[0..hostnames_array.len]) |hostname_info| {
        const hostname = hostname_info.hostname[0..hostname_info.hostname_len];

        const query_id = id_buf[slot_idx];

        if (question_type) |qt| {
            queries[slot_idx].id = query_id;
            queries[slot_idx].len = @intCast(build_query(query_id, &queries[slot_idx].buf, qt, hostname));
            slot_idx += 1;
        } else {
            queries[slot_idx].id = query_id;
            queries[slot_idx].len = @intCast(build_query(query_id, &queries[slot_idx].buf, .ipv4, hostname));
            slot_idx += 1;

            if (ipv6_supported) {
                const query_id2 = id_buf[slot_idx];
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
        .responses_per_hostname = responses_per_hostname,
        .results = .empty,
        .ptr_results = .empty,
        // BUG-358: the struct-literal assignment reset dns_timeout back to
        // its `null` field default, silently discarding the user-configured
        // timeout for every response read (queue_read_package) and every
        // subsequent query send (queue_send_query) — they all fell back to
        // the 5-second default.
        .dns_timeout = dns_timeout,
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

pub fn get_hostname_array(allocator: std.mem.Allocator, hostname: []const u8, suffixes: []const []const u8) !HostnamesArray {
    const total: usize = suffixes.len + 1;
    var hostnames_array = HostnamesArray{ .array = try allocator.alloc(Hostname, total), .len = 0 };
    errdefer allocator.free(hostnames_array.array);

    if (std.mem.indexOfScalar(u8, hostname, '.')) |_| {
        // FQDN: only try the hostname itself, no search suffixes
        if (build_hostname(&hostnames_array.array[hostnames_array.len], hostname, &.{})) {
            hostnames_array.len += 1;
        }
    } else {
        // Non-FQDN: try each search suffix first, then the bare hostname.
        // BUG-405: the bare hostname must also be tried when there are no
        // search domains, otherwise dotless names produce no candidates.
        for (suffixes) |suffix| {
            if (build_hostname(&hostnames_array.array[hostnames_array.len], hostname, suffix)) {
                hostnames_array.len += 1;
            }
        }
        if (build_hostname(&hostnames_array.array[hostnames_array.len], hostname, &.{})) {
            hostnames_array.len += 1;
        }
    }

    return hostnames_array;
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

    // Reserved / extended label bits (01xx_xxxx / 10xx_xxxx)
    var data4 = std.mem.zeroes([70]u8);
    data4[0] = 0x41;
    try std.testing.expectEqual(@as(?usize, null), skip_name(&data4, 0));

    var data5 = std.mem.zeroes([140]u8);
    data5[0] = 0x81;
    try std.testing.expectEqual(@as(?usize, null), skip_name(&data5, 0));
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

test "BUG-358: build_queries preserves the configured dns_timeout" {
    const allocator = std.testing.allocator;
    const loop = try allocator.create(Loop);
    defer allocator.destroy(loop);
    try loop.init(allocator, 64);
    defer loop.release();

    var cache: Cache = undefined;
    cache.init(allocator);
    defer cache.deinit();

    const control_data = try allocator.create(ControlData);
    defer allocator.destroy(control_data);
    control_data.* = ControlData{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .loop = loop,
        .user_callbacks = .empty,
        .record = undefined,
        .queries_data = undefined,
        .tasks_finished = 0,
        .resolved = false,
        .record_evicted = false,
        .node = null,
    };
    defer control_data.arena.deinit();

    var hostname_storage: [1]Hostname = undefined;
    hostname_storage[0] = .{ .hostname = undefined, .hostname_len = 0, .original_hostname_len = 0 };
    const host = "example.com";
    @memcpy(hostname_storage[0].hostname[0..host.len], host);
    hostname_storage[0].hostname_len = @intCast(host.len);
    hostname_storage[0].original_hostname_len = @intCast(host.len);
    const hostnames_array: HostnamesArray = .{ .array = hostname_storage[0..], .len = 1 };

    var server_data: ServerQueryData = undefined;

    // UDP connect() to loopback never sends a packet — safe in tests.
    const server_address = utils.Address.initIp4(.{ 127, 0, 0, 1 }, 5353);
    const timeout: ?DnsTimeout = .{ .sec = 1, .nsec = 500_000_000 };

    try build_queries(allocator, loop, control_data, &server_data, false, hostnames_array, &server_address, null, timeout);

    // BUG-358: the struct-literal assignment clobbered dns_timeout back to
    // null, silently discarding the user-configured timeout for every
    // response read and subsequent query send.
    try std.testing.expectEqual(timeout, server_data.dns_timeout);

    // The test owns the built query state (on success the queue flow owns
    // it): release the query slots, the per-hostname credit counters and
    // the UDP socket.
    allocator.free(server_data.responses_per_hostname);
    allocator.free(server_data.queries);
    _ = std.os.linux.close(server_data.socket_fd);
}
