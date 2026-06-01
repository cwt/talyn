const std = @import("std");

const utils = @import("utils");

const Resolv = @import("resolv.zig");
const CallbackManager = @import("callback_manager");

pub fn timestamp() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec));
}

const RecordState = union(enum) {
    pending: *Resolv.ControlData,
    resolved: []utils.Address,
    ptr: []u8,
    none,
};

pub const Record = struct {
    hostname: []u8,
    state: RecordState,
    expire_at: i64,

    pub inline fn get_address_list(self: *Record) ?[]const utils.Address {
        return switch (self.state) {
            .pending => null,
            .resolved => |d| d,
            .ptr => null,
            .none => null
        };
    }

    pub inline fn append_callback(self: *Record, user_callback: *const CallbackManager.Callback) !void {
        const control_data = self.state.pending;
        try control_data.loop.reserve_slots(1);
        errdefer control_data.loop.reserved_slots -= 1;

        try control_data.user_callbacks.append(control_data.arena.allocator(), user_callback.*);
    }

    pub inline fn set_resolved_data(self: *Record, address_list: []utils.Address, ttl: u32) void {
        var expire_at: i64 = std.math.maxInt(i64);
        if (ttl < std.math.maxInt(u32)) {
            expire_at = timestamp() + ttl;
        }

        self.expire_at = expire_at;
        self.state = .{
            .resolved = address_list
        };
    }

    pub inline fn set_ptr_data(self: *Record, hostname: []u8, ttl: u32) void {
        var expire_at: i64 = std.math.maxInt(i64);
        if (ttl < std.math.maxInt(u32)) {
            expire_at = timestamp() + ttl;
        }

        self.expire_at = expire_at;
        self.state = .{
            .ptr = hostname
        };
    }

    pub inline fn discard(self: *Record) void {
        self.state = .none;
        self.expire_at = 0;
    }
};

const RecordCache = utils.LRUCache([]const u8, *Record);

fn evict_record(ctx: ?*anyopaque, key: []const u8, record: *Record) void {
    const self: *Cache = @alignCast(@ptrCast(ctx.?));
    self.allocator.free(key);
    switch (record.state) {
        .pending => |control_data| {
            control_data.record_evicted = true;
        },
        .resolved => |v| self.allocator.free(v),
        .ptr => |v| self.allocator.free(v),
        .none => {},
    }
    self.allocator.destroy(record);
}

allocator: std.mem.Allocator,
cache: RecordCache,

pub fn init(self: *Cache, allocator: std.mem.Allocator) void {
    self.allocator = allocator;
    self.cache = RecordCache.init(allocator, 1024);
    self.cache.evict_callback = &evict_record;
    self.cache.evict_ctx = self;
}

pub fn deinit(self: *Cache) void {
    // LRUCache.deinit will call evict_record for each entry
    self.cache.deinit();
}

pub fn create_new_record(self: *Cache, hostname: []const u8, control_data: *Resolv.ControlData) !*Record {
    const allocator = self.allocator;
    const new_hostname = try allocator.dupe(u8, hostname);
    errdefer allocator.free(new_hostname);

    const record = try allocator.create(Record);
    errdefer allocator.destroy(record);
    
    record.* = Record{
        .hostname = new_hostname,
        .expire_at = std.math.maxInt(i64),
        .state = .{
            .pending = control_data
        }
    };

    try self.cache.put(new_hostname, record);
    return record;
}

pub fn create_new_record_from_resolved(
    self: *Cache,
    hostname: []const u8,
    address_list: []utils.Address,
    ttl: u32,
) !*Record {
    const allocator = self.allocator;
    const new_hostname = try allocator.dupe(u8, hostname);
    errdefer allocator.free(new_hostname);

    var expire_at: i64 = std.math.maxInt(i64);
    if (ttl < std.math.maxInt(u32)) {
        var ts: std.os.linux.timespec = undefined;
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (@as(i32, @intCast(rc)) >= 0) {
            expire_at = @as(i64, @intCast(ts.sec)) + @as(i64, @intCast(ttl));
        }
    }

    const record = try allocator.create(Record);
    errdefer allocator.destroy(record);

    record.* = Record{
        .hostname = new_hostname,
        .expire_at = expire_at,
        .state = .{
            .resolved = address_list
        }
    };

    try self.cache.put(new_hostname, record);
    return record;
}

pub fn get(self: *Cache, hostname: []const u8) ?*Record {
    const current_time = timestamp();

    if (self.cache.get(hostname)) |record| {
        if (record.expire_at < current_time) {
            // Expired.
            _ = self.cache.remove(hostname);
            return null;
        }
        return record;
    }

    return null;
}

const Cache = @This();

const testing = std.testing;

test "create_new_record" {
    // Create a mock ControlData
    const control_data = try testing.allocator.create(Resolv.ControlData);
    control_data.* = .{
        .allocator = testing.allocator,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .record = undefined,
        .loop = undefined,
        .user_callbacks = .{ .items = &.{}, .capacity = 0 },
        .queries_data = &.{},
        .record_evicted = false,
    };

    var cache: Cache = undefined;
    cache.init(testing.allocator);

    const record = try cache.create_new_record("example.com", control_data);

    try testing.expectEqualStrings("example.com", record.hostname);
    try testing.expect(record.state == .pending);
    try testing.expect(record.expire_at == std.math.maxInt(i64));

    // Cleanup in correct order: cache first (evicts records), then control_data
    cache.deinit();
    control_data.arena.deinit();
    testing.allocator.destroy(control_data);
}

test "set_resolved_data" {
    // Create a mock ControlData
    const control_data = try testing.allocator.create(Resolv.ControlData);
    control_data.* = .{
        .allocator = testing.allocator,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .record = undefined,
        .loop = undefined,
        .user_callbacks = .{ .items = &.{}, .capacity = 0 },
        .queries_data = &.{},
        .record_evicted = false,
    };

    var cache: Cache = undefined;
    cache.init(testing.allocator);

    const record = try cache.create_new_record("example.com", control_data);

    const addresses = try testing.allocator.alloc(utils.Address, 2);
    addresses[0] = utils.Address.initIp4(.{8, 8, 8, 8}, 53);
    addresses[1] = utils.Address.initIp4(.{1, 1, 1, 1}, 53);

    record.set_resolved_data(addresses, 300);

    try testing.expect(record.state == .resolved);
    try testing.expectEqual(@as(usize, 2), record.get_address_list().?.len);
    try testing.expectEqual(std.posix.AF.INET, record.get_address_list().?[0].any.family);
    try testing.expectEqual(std.posix.AF.INET, record.get_address_list().?[1].any.family);
    try testing.expect(record.expire_at > timestamp());

    // Cleanup in correct order
    cache.deinit();
    control_data.arena.deinit();
    testing.allocator.destroy(control_data);
}

test "get record from cache" {
    // Create a mock ControlData
    const control_data = try testing.allocator.create(Resolv.ControlData);
    control_data.* = .{
        .allocator = testing.allocator,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .record = undefined,
        .loop = undefined,
        .user_callbacks = .{ .items = &.{}, .capacity = 0 },
        .queries_data = &.{},
        .record_evicted = false,
    };

    var cache: Cache = undefined;
    cache.init(testing.allocator);

    const record = try cache.create_new_record("example.com", control_data);

    const addresses = try testing.allocator.alloc(utils.Address, 2);
    addresses[0] = utils.Address.initIp4(.{8, 8, 8, 8}, 53);
    addresses[1] = utils.Address.initIp4(.{1, 1, 1, 1}, 53);

    record.set_resolved_data(addresses, 300);

    const retrieved_record = cache.get("example.com").?;
    try testing.expectEqualStrings("example.com", retrieved_record.hostname);
    try testing.expect(retrieved_record.state == .resolved);
    try testing.expectEqual(@as(usize, 2), retrieved_record.get_address_list().?.len);

    // Cleanup in correct order
    cache.deinit();
    control_data.arena.deinit();
    testing.allocator.destroy(control_data);
}

test "get expired record" {
    // Create a mock ControlData
    const control_data = try testing.allocator.create(Resolv.ControlData);
    control_data.* = .{
        .allocator = testing.allocator,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .record = undefined,
        .loop = undefined,
        .user_callbacks = .{ .items = &.{}, .capacity = 0 },
        .queries_data = &.{},
        .record_evicted = false,
    };

    var cache: Cache = undefined;
    cache.init(testing.allocator);

    const record = try cache.create_new_record("example.com", control_data);

    const addresses = try testing.allocator.alloc(utils.Address, 2);
    addresses[0] = utils.Address.initIp4(.{8, 8, 8, 8}, 53);
    addresses[1] = utils.Address.initIp4(.{1, 1, 1, 1}, 53);

    record.set_resolved_data(addresses, 0);  // Immediately expire
    record.expire_at = 0;  // Force expiration

    const retrieved_record = cache.get("example.com");
    try testing.expect(retrieved_record == null);

    // Cleanup in correct order
    cache.deinit();
    control_data.arena.deinit();
    testing.allocator.destroy(control_data);
}

test "evict pending record sets record_evicted flag" {
    // Create a mock ControlData
    const control_data = try testing.allocator.create(Resolv.ControlData);
    control_data.* = .{
        .allocator = testing.allocator,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .record = undefined,
        .loop = undefined,
        .user_callbacks = .{ .items = &.{}, .capacity = 0 },
        .queries_data = &.{},
        .record_evicted = false,
    };

    var cache: Cache = undefined;
    cache.init(testing.allocator);

    const record = try cache.create_new_record("example.com", control_data);
    control_data.record = record;

    try testing.expect(record.state == .pending);
    try testing.expect(!control_data.record_evicted);

    // Force eviction by removing the record
    _ = cache.cache.remove("example.com");

    // The record_evicted flag should now be set
    try testing.expect(control_data.record_evicted);

    // Cleanup in correct order
    cache.deinit();
    control_data.arena.deinit();
    testing.allocator.destroy(control_data);
}
