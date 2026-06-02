const std = @import("std");

pub fn LRUCache(comptime K: type, comptime V: type) type {
    const LNode = struct {
        key: K,
        value: V,
        prev: ?*@This() = null,
        next: ?*@This() = null,
    };
    const MapType = if (K == []const u8) std.StringHashMap(*LNode) else std.AutoHashMap(K, *LNode);
    return struct {
        const Self = @This();
        
        pub const Node = LNode;
        pub const EvictCallback = *const fn (ctx: ?*anyopaque, key: K, value: V) void;

        allocator: std.mem.Allocator,
        capacity: usize,
        map: MapType,
        head: ?*Node = null,
        tail: ?*Node = null,
        evict_callback: ?EvictCallback = null,
        evict_ctx: ?*anyopaque = null,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) Self {
            return .{
                .allocator = allocator,
                .capacity = capacity,
                .map = MapType.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.iterator();
            while (it.next()) |entry| {
                const node = entry.value_ptr.*;
                if (self.evict_callback) |cb| {
                    cb(self.evict_ctx, node.key, node.value);
                }
                self.allocator.destroy(node);
            }
            self.map.deinit();
        }

        pub fn get(self: *Self, key: K) ?V {
            if (self.map.get(key)) |node| {
                self.move_to_front(node);
                return node.value;
            }
            return null;
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            // BUG-78: With capacity=0, the cache should never
            // hold any entries. Without this check, the count
            // comparison `0 >= 0` is true, so the first put
            // would skip eviction (nothing to evict) and then
            // add the entry, ending up with 1 entry in a
            // "capacity 0" cache. If the caller passed capacity=0
            // (e.g., disabled cache), we should respect that.
            if (self.capacity == 0) return;

            if (self.map.get(key)) |node| {
                // BUG-40: Fire the evict callback for the old value
                // before overwriting. Without this, callers who
                // register a callback to release resources tied to
                // the cached value (e.g., freeing a buffer) leak
                // the old value when they re-put the same key.
                if (self.evict_callback) |cb| {
                    cb(self.evict_ctx, node.key, node.value);
                }
                node.value = value;
                self.move_to_front(node);
                return;
            }

            if (self.map.count() >= self.capacity) {
                self.evict_last();
            }

            const node = try self.allocator.create(Node);
            node.* = .{
                .key = key,
                .value = value,
            };

            try self.map.put(key, node);
            self.prepend(node);
        }

        pub fn remove(self: *Self, key: K) bool {
            if (self.map.fetchRemove(key)) |entry| {
                const node = entry.value;
                if (self.evict_callback) |cb| {
                    cb(self.evict_ctx, node.key, node.value);
                }
                self.remove_node(node);
                self.allocator.destroy(node);
                return true;
            }
            return false;
        }

        pub fn pop_tail(self: *Self) ?V {
            if (self.tail) |node| {
                const value = node.value;
                if (self.evict_callback) |cb| {
                    cb(self.evict_ctx, node.key, node.value);
                }
                _ = self.map.remove(node.key);
                self.remove_node(node);
                self.allocator.destroy(node);
                return value;
            }
            return null;
        }

        fn move_to_front(self: *Self, node: *Node) void {
            if (node == self.head) return;
            
            self.remove_node(node);
            self.prepend(node);
        }

        fn prepend(self: *Self, node: *Node) void {
            node.next = self.head;
            node.prev = null;
            if (self.head) |h| {
                h.prev = node;
            }
            self.head = node;
            if (self.tail == null) {
                self.tail = node;
            }
        }

        fn remove_node(self: *Self, node: *Node) void {
            if (node.prev) |p| {
                p.next = node.next;
            } else {
                self.head = node.next;
            }
            if (node.next) |n| {
                n.prev = node.prev;
            } else {
                self.tail = node.prev;
            }
        }

        fn evict_last(self: *Self) void {
            if (self.tail) |node| {
                if (self.evict_callback) |cb| {
                    cb(self.evict_ctx, node.key, node.value);
                }
                _ = self.map.remove(node.key);
                self.remove_node(node);
                self.allocator.destroy(node);
            }
        }
    };
}

test "LRUCache basic" {
    const allocator = std.testing.allocator;
    var cache = LRUCache(u32, u32).init(allocator, 2);
    defer cache.deinit();

    try cache.put(1, 100);
    try cache.put(2, 200);
    try std.testing.expectEqual(@as(?u32, 100), cache.get(1));

    try cache.put(3, 300); // Should evict 2 (1 was used recently)
    try std.testing.expectEqual(@as(?u32, null), cache.get(2));
    try std.testing.expectEqual(@as(?u32, 100), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 300), cache.get(3));
}

test "LRUCache put with existing key fires evict callback (BUG-40)" {
    const allocator = std.testing.allocator;
    var cache = LRUCache(u32, []const u8).init(allocator, 4);
    defer cache.deinit();

    const Ctx = struct {
        count: u32 = 0,
        last_value: []const u8 = "",
    };
    var ctx = Ctx{};
    cache.evict_callback = struct {
        fn cb(c: ?*anyopaque, _: u32, v: []const u8) void {
            const c_ptr: *Ctx = @ptrCast(@alignCast(c.?));
            c_ptr.count += 1;
            c_ptr.last_value = v;
        }
    }.cb;
    cache.evict_ctx = @ptrCast(&ctx);

    try cache.put(1, "first");
    try std.testing.expectEqual(@as(u32, 0), ctx.count);

    // Re-putting the same key must fire the callback for the old value
    try cache.put(1, "second");
    try std.testing.expectEqual(@as(u32, 1), ctx.count);
    try std.testing.expectEqualStrings("first", ctx.last_value);
    try std.testing.expectEqualStrings("second", cache.get(1).?);
}

test "LRUCache capacity 0 holds nothing (BUG-78)" {
    const allocator = std.testing.allocator;
    var cache = LRUCache(u32, u32).init(allocator, 0);
    defer cache.deinit();

    // Capacity 0 means the cache should hold nothing.
    try cache.put(1, 100);
    try std.testing.expectEqual(@as(?u32, null), cache.get(1));

    // A second put should also be a no-op
    try cache.put(2, 200);
    try std.testing.expectEqual(@as(?u32, null), cache.get(2));

    // The map should be empty
    try std.testing.expectEqual(@as(usize, 0), cache.map.count());
}
