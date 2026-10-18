const std = @import("std");

pub fn BTree(comptime Key: type, comptime Value: type, comptime Degree: usize) type {
    if (Degree == 1) {
        @compileError("Degree must be greater than 1");
    } else if (Degree & @as(usize, 1) == 0) {
        @compileError("Degree must be a odd number");
    }

    return struct {
        pub const Node = struct {
            parent: ?*Node,

            keys: [Degree]Key,
            values: [Degree]Value,
            childs: [Degree + 1]?*Node,

            nkeys: @Int(.unsigned, 1 + std.math.log2(Degree)),
        };

        allocator: std.mem.Allocator,
        parent: *Node,

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return .{ .allocator = allocator, .parent = try create_node(allocator) };
        }

        pub fn deinit(self: *@This()) !void {
            if (self.parent.nkeys > 0) return error.BTreeHasElements;

            const allocator = self.allocator;
            allocator.destroy(self.parent);
        }

        fn create_node(allocator: std.mem.Allocator) !*Node {
            const new_node = try allocator.create(Node);
            new_node.* = .{
                .parent = null,
                .keys = undefined,
                .values = undefined,
                .childs = @splat(null),
                .nkeys = 0,
            };
            return new_node;
        }

        pub fn get_value_ptr(self: *@This(), key: Key, node: ?**Node) ?*Value {
            var current_node: *Node = self.parent;
            var value: ?*Value = null;
            loop: while (true) {
                const nkeys = current_node.nkeys;
                if (nkeys == 0) break;

                if (@typeInfo(Key) == .float) {
                    const eps = std.math.floatEps(Key);
                    for (current_node.keys[0..nkeys], current_node.values[0..nkeys], current_node.childs[0..nkeys]) |k, *v, ch| {
                        const diff = k - key;
                        if (@abs(diff) <= eps) {
                            value = v;
                            break :loop;
                        } else if (diff > eps) {
                            current_node = ch orelse break :loop;
                            continue :loop;
                        }
                    }
                } else {
                    for (current_node.keys[0..nkeys], current_node.values[0..nkeys], current_node.childs[0..nkeys]) |k, *v, ch| {
                        if (k == key) {
                            value = v;
                            break :loop;
                        } else if (k > key) {
                            current_node = ch orelse break :loop;
                            continue :loop;
                        }
                    }
                }

                current_node = current_node.childs[nkeys] orelse break;
            }

            if (node) |v| {
                v.* = current_node;
            }
            return value;
        }

        pub inline fn get_value(self: *@This(), key: Key, node: ?**Node) ?Value {
            const value_ptr = self.get_value_ptr(key, node) orelse return null;
            return value_ptr.*;
        }

        inline fn find_max_from_node(node: *Node, key: ?*Key, ret_node: ?**Node) ?*Value {
            var current_node: *Node = node;
            while (true) {
                const nkeys = current_node.nkeys;
                if (nkeys == 0) break;
                current_node = current_node.childs[nkeys] orelse break;
            }

            if (ret_node) |v| {
                v.* = current_node;
            }

            const nkeys = current_node.nkeys;
            if (nkeys == 0) return null;

            if (key) |k| k.* = current_node.keys[nkeys - 1];
            return &current_node.values[nkeys - 1];
        }

        pub fn get_max_value_ptr(self: *@This(), key: ?*Key, node: ?**Node) ?*Value {
            return find_max_from_node(self.parent, key, node);
        }

        pub inline fn get_max_value(self: *@This(), key: ?*Key, node: ?**Node) ?Value {
            const value_ptr = self.get_max_value_ptr(key, node) orelse return null;
            return value_ptr.*;
        }

        inline fn find_min_from_node(node: *Node, key: ?*Key, ret_node: ?**Node) ?*Value {
            var current_node: *Node = node;
            while (true) {
                if (current_node.nkeys == 0) break;
                current_node = current_node.childs[0] orelse break;
            }

            if (ret_node) |v| {
                v.* = current_node;
            }
            if (current_node.nkeys == 0) return null;
            if (key) |k| k.* = current_node.keys[0];
            return &current_node.values[0];
        }

        pub fn get_min_value_ptr(self: *@This(), key: ?*Key, node: ?**Node) ?*Value {
            return find_min_from_node(self.parent, key, node);
        }

        pub inline fn get_min_value(self: *@This(), key: ?*Key, node: ?**Node) ?Value {
            const value_ptr = self.get_min_value_ptr(key, node) orelse return null;
            return value_ptr.*;
        }

        inline fn insert_in_empty_node(node: *Node, keys: []const Key, values: []const Value) !void {
            if (keys.len != values.len) return error.InconsistentBTreeState;

            @memcpy(node.keys[0..keys.len], keys);
            @memcpy(node.values[0..values.len], values);
            node.nkeys = @intCast(keys.len);
        }

        fn do_insertion(node: *Node, key: Key, value: Value, new_child: ?*Node) !void {
            if (new_child) |ch| {
                ch.parent = node;
            }

            const nkeys = node.nkeys;
            if (nkeys == 0) {
                try insert_in_empty_node(node, &.{key}, &.{value});
                node.childs[1] = new_child;
                return;
            }

            defer node.nkeys += 1;

            const keys = &node.keys;
            const values = &node.values;
            const childs = &node.childs;

            if (@typeInfo(Key) == .float) {
                const eps = std.math.floatEps(Key);
                for (0..nkeys) |index| {
                    const diff = key - keys[index];
                    if (diff < -eps) {
                        var i: usize = nkeys;
                        while (i > index) : (i -= 1) {
                            keys[i] = keys[i - 1];
                            values[i] = values[i - 1];
                            childs[i + 1] = childs[i];
                        }

                        keys[index] = key;
                        values[index] = value;
                        childs[index + 1] = new_child;
                        return;
                    }
                }
            } else {
                for (0..nkeys) |index| {
                    if (key < keys[index]) {
                        var i: usize = nkeys;
                        while (i > index) : (i -= 1) {
                            keys[i] = keys[i - 1];
                            values[i] = values[i - 1];
                            childs[i + 1] = childs[i];
                        }

                        keys[index] = key;
                        values[index] = value;
                        childs[index + 1] = new_child;
                        return;
                    }
                }
            }

            keys[nkeys] = key;
            values[nkeys] = value;
            childs[nkeys + 1] = new_child;
        }

        inline fn change_parent(new_parent: *Node) void {
            for (new_parent.childs) |node| {
                if (node) |v| {
                    v.parent = new_parent;
                }
            }
        }

        inline fn split_root_node(keys: []Key, values: []Value, childs: []?*Node, child_node1: *Node, child_node2: *Node) !void {
            const middle_index = (Degree - 1) / 2;
            const middle_index_plus_one = middle_index + 1;

            try insert_in_empty_node(child_node1, keys[0..middle_index], values[0..middle_index]);
            try insert_in_empty_node(child_node2, keys[middle_index_plus_one..], values[middle_index_plus_one..]);

            @memcpy(child_node1.childs[0..middle_index_plus_one], childs[0..middle_index_plus_one]);
            @memcpy(child_node2.childs[0..middle_index_plus_one], childs[middle_index_plus_one..]);

            change_parent(child_node1);
            change_parent(child_node2);

            keys[0] = keys[middle_index];
            values[0] = values[middle_index];
            childs[0] = child_node1;
            childs[1] = child_node2;

            @memset(childs[2..], null);
        }

        inline fn split_node(keys: []Key, values: []Value, childs: []?*Node, parent: *Node, new_child: *Node) !void {
            const middle_index = (Degree - 1) / 2;
            const middle_index_plus_one = middle_index + 1;

            try insert_in_empty_node(new_child, keys[middle_index_plus_one..], values[middle_index_plus_one..]);
            @memcpy(new_child.childs[0..middle_index_plus_one], childs[middle_index_plus_one..]);

            change_parent(new_child);

            @memset(childs[middle_index_plus_one..], null);
            try do_insertion(parent, keys[middle_index], values[middle_index], new_child);
        }

        fn split_nodes(allocator: std.mem.Allocator, node: *Node) !void {
            var current_node = node;
            while (current_node.nkeys == Degree) {
                const keys = &current_node.keys;
                const values = &current_node.values;
                const childs = &current_node.childs;

                const new_node1 = try create_node(allocator);
                const parent = current_node.parent;
                if (parent) |p_node| {
                    // BUG-368: the split helpers can fail after new_node1
                    // was allocated — without this errdefer it leaked on
                    // OOM. (The statements after the try are infallible,
                    // so the errdefer is exactly scoped to the failure
                    // window.)
                    errdefer allocator.destroy(new_node1);
                    try split_node(keys, values, childs, p_node, new_node1);
                    change_parent(current_node);
                    new_node1.parent = p_node;
                    current_node.nkeys = (Degree - 1) / 2;
                } else {
                    // BUG-368: failing the new_node2 allocation or the
                    // split_root_node body leaked new_node1 (and its own
                    // node).
                    errdefer allocator.destroy(new_node1);
                    const new_node2 = try create_node(allocator);
                    errdefer allocator.destroy(new_node2);
                    try split_root_node(keys, values, childs, new_node1, new_node2);
                    new_node1.parent = current_node;
                    new_node2.parent = current_node;
                    current_node.nkeys = 1;
                }

                current_node = parent orelse break;
            }
        }

        inline fn insert_in_node(allocator: std.mem.Allocator, node: *Node, key: Key, value: Value) !void {
            try do_insertion(node, key, value, null);
            try split_nodes(allocator, node);
        }

        pub fn insert(self: *@This(), key: Key, value: Value) bool {
            const allocator = self.allocator;

            var node: *Node = self.parent;
            if (node.nkeys > 0) {
                const previous_value_ptr = get_value_ptr(self, key, &node);
                if (previous_value_ptr != null) {
                    return false;
                }
            }

            insert_in_node(allocator, node, key, value) catch return false;
            return true;
        }

        pub fn replace(self: *@This(), key: Key, value: Value) ?Value {
            const allocator = self.allocator;

            var node: *Node = self.parent;
            if (node.nkeys > 0) {
                const previous_value_ptr = get_value_ptr(self, key, &node);
                if (previous_value_ptr) |ptr| {
                    const prev_value = ptr.*;
                    ptr.* = value;
                    return prev_value;
                }
            }

            insert_in_node(allocator, node, key, value) catch return null;
            return null;
        }

        inline fn delete_from_left(allocator: std.mem.Allocator, node: *?*Node, key: *Key, value: *Value) void {
            var node_with_bigger_value: *Node = undefined;
            value.* = find_max_from_node(node.*.?, key, &node_with_bigger_value).?.*;

            node_with_bigger_value.nkeys -= 1;
            if (node_with_bigger_value.nkeys == 0) {
                const p_node = node_with_bigger_value.parent.?;
                const p_last_node = &p_node.childs[p_node.nkeys];
                const rem_child = node_with_bigger_value.childs[0];
                if (p_last_node.* == node_with_bigger_value) {
                    p_last_node.* = rem_child;
                } else {
                    node.* = rem_child;
                }
                if (rem_child) |child| child.parent = p_node;

                allocator.destroy(node_with_bigger_value);
            }
        }

        inline fn delete_from_right(allocator: std.mem.Allocator, node: *?*Node, key: *Key, value: *Value) void {
            var node_with_smaller_value: *Node = undefined;
            value.* = find_min_from_node(node.*.?, key, &node_with_smaller_value).?.*;

            const nkeys = node_with_smaller_value.nkeys - 1;
            node_with_smaller_value.nkeys = nkeys;

            if (nkeys == 0) {
                const p_node = node_with_smaller_value.parent.?;
                const p_first_node = &p_node.childs[0];
                const rem_child = node_with_smaller_value.childs[1];
                if (p_first_node.* == node_with_smaller_value) {
                    p_first_node.* = rem_child;
                } else {
                    node.* = rem_child;
                }
                if (rem_child) |child| child.parent = p_node;

                allocator.destroy(node_with_smaller_value);
            } else {
                const keys = &node_with_smaller_value.keys;
                const values = &node_with_smaller_value.values;
                const childs = &node_with_smaller_value.childs;
                for (0..nkeys) |i| {
                    keys[i] = keys[i + 1];
                    values[i] = values[i + 1];
                    childs[i] = childs[i + 1];
                }
                childs[nkeys] = childs[nkeys + 1];
                // BUG-368: the copy duplicated the pointer into slot
                // nkeys + 1, which is now beyond the valid child range
                // (a node with nkeys keys owns childs[0..nkeys + 1]) —
                // clear it or the later destroy of that child nulls only
                // the first match and leaves this dangling alias for
                // change_parent to write into.
                childs[nkeys + 1] = null;
            }
        }

        inline fn perform_delete(allocator: std.mem.Allocator, node: *?*Node, func: anytype, keys: []Key, values: []Value, index: usize) void {
            var key: Key = undefined;
            var value: Value = undefined;
            func(allocator, node, &key, &value);

            keys[index] = key;
            values[index] = value;
        }

        inline fn delete_key_from_node(allocator: std.mem.Allocator, node: *Node, keys: []Key, values: []Value, childs: []?*Node, index: usize) void {
            const left_child = &childs[index];
            const right_child = &childs[index + 1];
            if (left_child.* != null) {
                perform_delete(allocator, left_child, delete_from_left, keys, values, index);
                return;
            } else if (right_child.* != null) {
                perform_delete(allocator, right_child, delete_from_right, keys, values, index);
                return;
            }

            const nkeys = node.nkeys - 1;
            node.nkeys = nkeys;

            if (nkeys == 0) {
                const p_node = node.parent orelse return;

                for (p_node.childs[0..(@as(usize, p_node.nkeys) + 1)]) |*child| {
                    if (child.* == node) {
                        allocator.destroy(node);
                        child.* = null;
                        break;
                    }
                }
            } else {
                for (index..nkeys) |i| {
                    keys[i] = keys[i + 1];
                    values[i] = values[i + 1];
                    childs[i] = childs[i + 1];
                }
                childs[nkeys] = childs[nkeys + 1];
                // BUG-368: clear the now-invalid duplicate (see the
                // delete_from_right twin comment) — otherwise the destroy
                // of a later-emptied child nulls only the first match and
                // leaves this dangling alias for change_parent.
                childs[nkeys + 1] = null;
            }
        }

        pub fn delete(self: *@This(), key: Key) ?Value {
            var node: *Node = undefined;
            const value = get_value(self, key, &node) orelse return null;

            const keys = &node.keys;
            const values = &node.values;
            const childs = &node.childs;

            const nkeys = node.nkeys;
            if (@typeInfo(Key) == .float) {
                const eps = std.math.floatEps(Key);
                for (0..nkeys) |i| {
                    const diff = key - keys[i];
                    if (@abs(diff) <= eps) {
                        delete_key_from_node(self.allocator, node, keys, values, childs, i);
                        break;
                    }
                }
            } else {
                for (0..nkeys) |i| {
                    if (key == keys[i]) {
                        delete_key_from_node(self.allocator, node, keys, values, childs, i);
                        break;
                    }
                }
            }

            return value;
        }

        pub fn pop(self: *@This(), key: ?*Key) ?Value {
            var node: *Node = undefined;
            const value = get_max_value(self, key, &node) orelse return null;

            const keys = &node.keys;
            const values = &node.values;
            const childs = &node.childs;
            delete_key_from_node(self.allocator, node, keys, values, childs, node.nkeys - 1);

            return value;
        }
    };
}

test "BTree: Initialization creates empty tree" {
    var new_btree = try BTree(usize, usize, 3).init(std.testing.allocator);
    defer new_btree.deinit() catch unreachable;

    try std.testing.expectEqual(@as(usize, 0), new_btree.parent.nkeys);
    try std.testing.expectEqual(null, new_btree.parent.parent);
    for (new_btree.parent.childs) |v| try std.testing.expectEqual(null, v);
}

test "BTree: Insert and delete sequential usize elements" {
    var new_btree = try BTree(usize, usize, 3).init(std.testing.allocator);
    defer new_btree.deinit() catch unreachable;

    const element_count = 20;
    for (0..element_count) |v| {
        const value = (v + 1) * 23;
        const inserted = new_btree.insert(v, value);
        try std.testing.expect(inserted);
    }

    for (0..element_count) |v| {
        const value = new_btree.get_value(v, null);
        try std.testing.expectEqual((v + 1) * 23, value);
    }

    for (0..element_count) |v| {
        const value = new_btree.delete(v);
        try std.testing.expectEqual((v + 1) * 23, value);
    }
}

test "BTree: Complex insertion, partial deletion, and reinsertion" {
    var new_btree = try BTree(usize, usize, 3).init(std.testing.allocator);
    defer new_btree.deinit() catch unreachable;

    const element_count = 15;
    // Initial insertion of elements
    for (0..element_count) |v| {
        const value = v * 100 + 50;
        const inserted = new_btree.insert(v, value);
        try std.testing.expect(inserted);
    }

    // Verify all elements are present
    for (0..element_count) |v| {
        const value = new_btree.get_value(v, null);
        try std.testing.expectEqual(v * 100 + 50, value);
    }

    // Delete even-indexed elements
    for (0..element_count) |v| {
        if (v % 2 == 0) {
            const value = new_btree.delete(v);
            try std.testing.expectEqual(v * 100 + 50, value);
        }
    }

    // Verify odd-indexed elements remain, even-indexed are removed
    for (0..element_count) |v| {
        const value = new_btree.get_value(v, null);
        if (v % 2 == 0) {
            try std.testing.expectEqual(null, value);
        } else {
            try std.testing.expectEqual(v * 100 + 50, value);
        }
    }

    // Reinsert even-indexed elements with new values
    for (0..element_count) |v| {
        if (v % 2 == 0) {
            const value = v * 200 + 25;
            const inserted = new_btree.insert(v, value);
            try std.testing.expect(inserted);
        }
    }

    // Verify all elements with updated values
    for (0..element_count) |v| {
        const value = new_btree.get_value(v, null);
        if (v % 2 == 0) {
            try std.testing.expectEqual(v * 200 + 25, value);
        } else {
            try std.testing.expectEqual(v * 100 + 50, value);
        }
    }

    // Delete all elements
    for (0..element_count) |v| {
        const value = new_btree.delete(v);
        if (v % 2 == 0) {
            try std.testing.expectEqual(v * 200 + 25, value);
        } else {
            try std.testing.expectEqual(v * 100 + 50, value);
        }
    }

    // Verify tree is empty
    for (0..element_count) |v| {
        const value = new_btree.get_value(v, null);
        try std.testing.expectEqual(null, value);
    }
}

test "BTree: Random order insertion and deletion with usize" {
    var new_btree = try BTree(usize, usize, 3).init(std.testing.allocator);
    defer new_btree.deinit() catch unreachable;

    const element_count = 30;
    var values: [element_count]usize = undefined;
    for (&values, 0..) |*v, i| v.* = i * 3;

    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();
    rand.shuffle(usize, &values);

    for (values) |v| {
        const value = (v + 1) * 23;
        const inserted = new_btree.insert(v, value);
        try std.testing.expect(inserted);
    }

    rand.shuffle(usize, &values);

    for (values) |v| {
        const value = new_btree.get_value(v, null);
        try std.testing.expectEqual((v + 1) * 23, value);
    }

    rand.shuffle(usize, &values);
    for (values) |v| {
        const value = new_btree.delete(v);
        try std.testing.expectEqual((v + 1) * 23, value);
    }
}

test "BTree: Random order insertion and deletion with floating point" {
    var new_btree = try BTree(f64, f64, 3).init(std.testing.allocator);
    defer new_btree.deinit() catch unreachable;

    const element_count = 100;
    var prng2 = std.Random.DefaultPrng.init(1);
    const rand2 = prng2.random();
    var values: [element_count]f64 = undefined;
    for (&values) |*v| v.* = -10.0 + rand2.float(f64) * 20.0;

    rand2.shuffle(f64, &values);

    for (values) |v| {
        const value = v * 33.0 + 10.0;
        const inserted = new_btree.insert(v, value);
        try std.testing.expect(inserted);
    }

    rand2.shuffle(f64, &values);

    for (values) |v| {
        const value = new_btree.get_value(v, null);
        const value_expected = v * 33.0 + 10.0;
        const diff = @abs(value.? - value_expected);
        try std.testing.expect(diff <= std.math.floatEps(f64));
    }

    rand2.shuffle(f64, &values);
    for (values) |v| {
        const value = new_btree.delete(v);
        const value_expected = v * 33.0 + 10.0;

        const diff = @abs(value.? - value_expected);
        try std.testing.expect(diff <= std.math.floatEps(f64));
    }
}

test "BTree: Random order insertion and deletion with Degree 11" {
    var new_btree = try BTree(usize, usize, 11).init(std.testing.allocator);
    defer new_btree.deinit() catch unreachable;

    const element_count = 200;
    var values: [element_count]usize = undefined;
    for (&values, 0..) |*v, i| v.* = i * 3;

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    rand.shuffle(usize, &values);

    for (values) |v| {
        const value = (v + 1) * 23;
        const inserted = new_btree.insert(v, value);
        try std.testing.expect(inserted);
    }

    rand.shuffle(usize, &values);

    for (values) |v| {
        const value = new_btree.get_value(v, null);
        try std.testing.expectEqual((v + 1) * 23, value);
    }

    rand.shuffle(usize, &values);
    for (values) |v| {
        const value = new_btree.delete(v);
        try std.testing.expectEqual((v + 1) * 23, value);
    }
}

test "BTree: get_min_value_ptr and get_max_value_ptr with non-pointer values" {
    var tree = try BTree(i32, [4]u8, 3).init(std.testing.allocator);
    defer tree.deinit() catch unreachable;

    _ = tree.insert(10, [4]u8{ 1, 0, 0, 0 });
    _ = tree.insert(5, [4]u8{ 2, 0, 0, 0 });
    _ = tree.insert(20, [4]u8{ 3, 0, 0, 0 });

    var min_key: i32 = 0;
    const min_ptr = tree.get_min_value_ptr(&min_key, null);
    try std.testing.expect(min_ptr != null);
    try std.testing.expectEqual(@as(i32, 5), min_key);
    try std.testing.expectEqual([4]u8{ 2, 0, 0, 0 }, min_ptr.?.*);

    var max_key: i32 = 0;
    const max_ptr = tree.get_max_value_ptr(&max_key, null);
    try std.testing.expect(max_ptr != null);
    try std.testing.expectEqual(@as(i32, 20), max_key);
    try std.testing.expectEqual([4]u8{ 3, 0, 0, 0 }, max_ptr.?.*);

    _ = tree.delete(5);
    _ = tree.delete(10);
    _ = tree.delete(20);
}

test "BUG-368: child shifting never leaves a pointer beyond the valid range" {
    const Tree = BTree(i32, i32, 3);

    const S = struct {
        fn check(counted_node: *Tree.Node, node_count: *usize) anyerror!void {
            node_count.* += 1;
            // A node with nkeys keys owns childs[0 .. nkeys + 1]; every
            // slot beyond that must be null. A non-null one is either a
            // dangling alias left by a child-array shift (deleted later —
            // change_parent then wrote into freed memory) or a stale
            // structure leak.
            for (counted_node.childs[@as(usize, counted_node.nkeys) + 1 ..]) |child| {
                if (child != null) return error.DanglingChildSlot;
            }
            for (counted_node.childs[0 .. @as(usize, counted_node.nkeys) + 1]) |child| {
                if (child) |c| {
                    if (c.parent != counted_node) return error.StaleParent;
                    try check(c, node_count);
                }
            }
        }
    };

    var tree = try Tree.init(std.testing.allocator);
    // Best-effort teardown: on a pre-fix buggy tree the drain may strand
    // keys, and deinit then fails — the invariant failure itself is the
    // test outcome, so only warn here instead of masking it with
    // unreachable.
    defer tree.deinit() catch |err| std.log.warn(
        "BUG-368 test teardown: deinit failed: {s}",
        .{@errorName(err)},
    );

    var outer_prng = std.Random.DefaultPrng.init(20241018);
    const rand = outer_prng.random();

    var keys: [64]i32 = undefined;
    for (&keys, 0..) |*k, i| k.* = @intCast(i);

    rand.shuffle(i32, &keys);
    for (keys) |k| {
        _ = tree.insert(k, k * 2);
    }

    var node_count: usize = 0;
    try S.check(tree.parent, &node_count);

    // Churn across several seeds and shapes: delete half of the keys,
    // checking the invariant after every delete — the shifted child
    // arrays are exactly where the pre-fix duplicate/dangling pointer
    // appeared.
    var seed: u64 = 20241018;
    for (0..12) |_| {
        var prng = std.Random.DefaultPrng.init(seed);
        const loop_rand = prng.random();
        seed += 1;

        var keys2: [128]i32 = undefined;
        for (&keys2, 0..) |*k, i| k.* = @intCast(i);
        loop_rand.shuffle(i32, &keys2);
        for (keys2) |k| {
            _ = tree.insert(k, k * 2);
        }

        loop_rand.shuffle(i32, &keys2);
        for (keys2[0 .. keys2.len / 2]) |k| {
            _ = tree.delete(k);
            node_count = 0;
            try S.check(tree.parent, &node_count);
        }

        for (keys2[keys2.len / 2 ..]) |k| {
            _ = tree.delete(k);
        }
        node_count = 0;
        try S.check(tree.parent, &node_count);

        loop_rand.shuffle(i32, &keys2);
        for (keys2[0 .. keys2.len / 3]) |k| {
            _ = tree.insert(k, k * 2 + 1);
        }
        node_count = 0;
        try S.check(tree.parent, &node_count);

        var drain_key: i32 = 0;
        while (tree.get_min_value_ptr(&drain_key, null) != null) {
            _ = tree.delete(drain_key);
        }
    }
}

test "BUG-368: OOM while splitting does not leak nodes" {
    // Deterministic split allocation sequence with Degree 3: allocation,
    // root creation; the 4th insert triggers split_nodes (new_node1,
    // then — for a root split — new_node2). Failing each allocation in
    // turn must leave the tree fully retrievable on teardown.
    for (1..6) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();

        var tree = try BTree(u32, u32, 3).init(allocator);

        var loaded: u32 = 0;
        while (loaded < 40) : (loaded += 1) {
            // insert() swallows internal OOM and returns false.
            if (!tree.insert(loaded, loaded)) break;
        }

        var key: u32 = 0;
        while (tree.get_min_value_ptr(&key, null) != null) {
            _ = tree.delete(key);
        }
        tree.deinit() catch unreachable;
    }
}
