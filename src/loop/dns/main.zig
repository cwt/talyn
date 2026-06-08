const std = @import("std");
const builtin = @import("builtin");

const Loop = @import("../main.zig");
const utils = @import("utils");
const python_c = @import("python_c");

const Cache = @import("cache.zig");
const Parsers = @import("parsers.zig");
const Resolv = @import("resolv.zig");
const CallbackManager = @import("callback_manager");

const DNSCacheEntries = switch (builtin.mode) {
    .Debug => 4,
    else => 1024,
};

const CACHE_MASK = DNSCacheEntries - 1;

pub const PendingList = utils.LinkedList(*Resolv.ControlData);

loop: *Loop = undefined,
arena: std.heap.ArenaAllocator = undefined,
allocator: std.mem.Allocator = undefined,

configuration: Parsers.Configuration = undefined,

cache_entries: [DNSCacheEntries]Cache = undefined,
parsed_hostname_buf: [255]u8 = undefined,

ipv6_supported: bool = false,

pending_queries: PendingList = undefined,

pub fn init(self: *DNS, loop: *Loop) !void {
    self.loop = loop;
    self.arena = std.heap.ArenaAllocator.init(loop.allocator);
    self.allocator = self.arena.allocator();

    for (&self.cache_entries) |*entry| {
        entry.init(self.allocator);
    }

    try self.load_configuration(self.allocator);

    // TODO: Figure out if there is a better way
    const ret = std.os.linux.socket(std.posix.AF.INET6, @as(u32, @intCast(std.posix.SOCK.STREAM)), 0);
    if (@as(i32, @intCast(ret)) >= 0) {
        self.ipv6_supported = true;
        _ = std.os.linux.close(@intCast(ret));
    } else {
        self.ipv6_supported = false;
    }

    self.pending_queries = PendingList.init(loop.allocator);
}

fn load_configuration(self: *DNS, allocator: std.mem.Allocator) !void {
    const fd_ret = std.os.linux.open("/etc/resolv.conf", .{}, 0);
    if (@as(i32, @intCast(fd_ret)) < 0) return error.Unexpected;
    const fd: std.posix.fd_t = @intCast(fd_ret);
    defer _ = std.os.linux.close(fd);

    var statx_buf: std.os.linux.Statx = undefined;
    const statx_ret = std.os.linux.statx(fd, "", @as(u32, @intCast(std.os.linux.AT.EMPTY_PATH)), std.os.linux.STATX{ .SIZE = true }, &statx_buf);
    if (@as(i32, @intCast(statx_ret)) < 0) return error.Unexpected;
    const size: usize = @intCast(statx_buf.size);

    const content = try allocator.alloc(u8, size);
    defer allocator.free(content);

    const read_ret = std.os.linux.read(fd, content.ptr, content.len);
    if (@as(i32, @intCast(read_ret)) < 0) return error.Unexpected;

    self.configuration = try Parsers.parse_resolv_configuration(allocator, content);
}

pub fn get_cache_slot(self: *DNS, hostname: []const u8) *Cache {
    var h = std.hash.XxHash3.init(0);
    h.update(hostname);
    const index = h.final();

    return &self.cache_entries[index & CACHE_MASK];
}

pub fn lookup(
    self: *DNS,
    hostname: []const u8,
    callback: ?*const CallbackManager.Callback,
    timeout: ?Resolv.DnsTimeout,
) !?[]const utils.Address {
    const parsed_hostname = std.ascii.lowerString(&self.parsed_hostname_buf, hostname);

    const cache_slot = self.get_cache_slot(parsed_hostname);
    const record = cache_slot.get(parsed_hostname) orelse {
        if (callback == null) return null;

        const ipv6_supported: bool = self.ipv6_supported;

        // BUG-48: Allocate a 2-element buffer for the synchronous
        // resolve result. The previous API returned a slice into
        // module-level mutable state (`tmp_address`), which was
        // racy: concurrent callers would see each other's results.
        // Caller copies the result via `allocator.dupe` before
        // storing it, so we can return an aliased slice here.
        var resolved_buf: [2]utils.Address = undefined;
        const n = try Parsers.resolve_address(parsed_hostname, ipv6_supported, &resolved_buf);
        if (n > 0) {
            const slice = self.loop.allocator.dupe(utils.Address, resolved_buf[0..n]) catch return null;
            return slice;
        }

        // Use native asynchronous resolver
        try Resolv.queue(cache_slot, self.loop, parsed_hostname, callback.?, self.configuration, ipv6_supported, null, timeout);
        return null;
    };

    const address_list = record.get_address_list() orelse {
        if (callback == null) return null;

        try self.loop.reserve_slots(1);
        errdefer self.loop.reserved_slots -= 1;

        try record.append_callback(callback.?);
        return null;
    };

    return address_list;
}

pub fn reverse_lookup(
    self: *DNS,
    address: utils.Address,
    callback: *const CallbackManager.Callback,
    timeout: ?Resolv.DnsTimeout,
) !void {
    var buf: [128]u8 = undefined;
    const name = try Parsers.build_reverse_name(address, &buf);

    const cache_slot = self.get_cache_slot(name);
    if (cache_slot.get(name)) |record| {
        if (record.state == .ptr) {
            // Already resolved
            try self.loop.reserve_slots(1);
            errdefer self.loop.reserved_slots -= 1;
            try Loop.Scheduling.Soon.dispatch(self.loop, callback);
            return;
        }

        // BUG-59: Record exists in pending state — attach the
        // callback to the in-flight query instead of creating a
        // duplicate. Previously we fell through to Resolv.queue
        // which dispatched a new DNS request for every caller.
        try self.loop.reserve_slots(1);
        errdefer self.loop.reserved_slots -= 1;
        try record.append_callback(callback);
        return;
    }

    try Resolv.queue(cache_slot, self.loop, name, callback, self.configuration, false, .ptr, timeout);
}

pub fn deinit(self: *DNS) void {
    var node = self.pending_queries.first;
    while (node) |n| {
        node = n.next;
        n.data.release();
    }
    self.arena.deinit();
}

pub fn traverse(self: *const DNS, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
    var node = self.pending_queries.first;
    while (node) |n| {
        const vret = n.data.traverse(visit, arg);
        if (vret != 0) return vret;
        node = n.next;
    }
    return 0;
}

const DNS = @This();

test "get_cache_slot returns consistent slot for same hostname" {
    var dns = DNS{
        .loop = undefined,
        .arena = undefined,
        .allocator = std.testing.allocator,
        .configuration = undefined,
        .cache_entries = undefined,
        .parsed_hostname_buf = undefined,
        .ipv6_supported = false,
        .pending_queries = PendingList.init(std.testing.allocator),
    };

    const hostname1 = "example.com";
    const hostname2 = "example.com";

    const slot1 = dns.get_cache_slot(hostname1);
    const slot2 = dns.get_cache_slot(hostname2);

    try std.testing.expectEqual(slot1, slot2);
}

test "get_cache_slot distributes hostnames across slots" {
    var dns = DNS{
        .loop = undefined,
        .arena = undefined,
        .allocator = std.testing.allocator,
        .configuration = undefined,
        .cache_entries = undefined,
        .parsed_hostname_buf = undefined,
        .ipv6_supported = false,
        .pending_queries = PendingList.init(std.testing.allocator),
    };

    const hostnames = [_][]const u8{
        "example1.com",
        "example2.com",
        "example3.com",
        "example4.com",
        "example5.com",
    };

    var slots = [_]*Cache{undefined} ** hostnames.len;

    for (hostnames, 0..) |hostname, i| {
        slots[i] = dns.get_cache_slot(hostname);
    }

    // Check that not all slots are the same
    var unique_slots = std.ArrayList(*Cache){ .items = &.{}, .capacity = 0 };
    defer unique_slots.deinit(std.testing.allocator);

    loop: for (slots) |slot| {
        for (unique_slots.items) |existing_slot| {
            if (slot == existing_slot) {
                continue :loop;
            }
        }
        try unique_slots.append(std.testing.allocator, slot);
    }

    try std.testing.expect(unique_slots.items.len > 1);
}

test "get_cache_slot handles different hostname lengths" {
    var dns = DNS{
        .loop = undefined,
        .arena = undefined,
        .allocator = std.testing.allocator,
        .configuration = undefined,
        .cache_entries = undefined,
        .parsed_hostname_buf = undefined,
        .ipv6_supported = false,
        .pending_queries = PendingList.init(std.testing.allocator),
    };

    const hostnames = [_][]const u8{
        "a",
        "ab",
        "abc",
        "abcd",
        "abcde",
        "a" ** 63,
        "a" ** 255,
    };

    var slots = [_]*Cache{undefined} ** hostnames.len;

    for (hostnames, 0..) |hostname, i| {
        slots[i] = dns.get_cache_slot(hostname);
    }

    // Check that different length hostnames can map to different slots
    var unique_slots = std.ArrayList(*Cache){ .items = &.{}, .capacity = 0 };
    defer unique_slots.deinit(std.testing.allocator);

    loop: for (slots) |slot| {
        for (unique_slots.items) |existing_slot| {
            if (slot == existing_slot) {
                continue :loop;
            }
        }
        try unique_slots.append(std.testing.allocator, slot);
    }

    try std.testing.expect(unique_slots.items.len > 1);
}

test "DNS deinit cleanup" {
    const allocator = std.testing.allocator;
    const loop = try allocator.create(Loop);
    defer allocator.destroy(loop);

    try loop.init(allocator, 1024);
    defer loop.release();
}

test {
    std.testing.refAllDecls(Parsers);
    std.testing.refAllDecls(Cache);
    std.testing.refAllDecls(Resolv);
}
