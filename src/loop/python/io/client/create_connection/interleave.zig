const std = @import("std");

const utils = @import("utils");

pub fn interleave_address_list(allocator: std.mem.Allocator, address_list: []utils.Address, interleave: usize) !void {
    const tmp_list = try allocator.alloc(utils.Address, address_list.len * 2);
    defer allocator.free(tmp_list);

    var ipv4_addresses: usize = 0;
    var ipv6_addresses: usize = 0;

    for (address_list) |*address| {
        switch (address.any.family) {
            std.posix.AF.INET => {
                tmp_list[ipv4_addresses] = address.*;
                ipv4_addresses += 1;
            },
            std.posix.AF.INET6 => {
                tmp_list[address_list.len + ipv6_addresses] = address.*;
                ipv6_addresses += 1;
            },
            else => return error.InvalidOperation,
        }
    }

    if (ipv6_addresses == 0 or ipv4_addresses == 0) {
        return;
    }

    var interleave_count: usize = interleave;
    var ipv4_index: usize = 0;
    var ipv6_index: usize = 0;
    for (address_list) |*v| {
        if ((interleave_count == 0 or ipv6_index >= ipv6_addresses) and ipv4_index < ipv4_addresses) {
            v.* = tmp_list[ipv4_index];
            ipv4_index += 1;
            interleave_count = interleave;
        } else if (ipv6_index < ipv6_addresses) {
            v.* = tmp_list[address_list.len + ipv6_index];
            ipv6_index += 1;
            // BUG-423: once IPv4 is exhausted the first branch stops
            // resetting the counter, and this decrement ran at 0 —
            // integer-overflow panic in Debug/ReleaseSafe, silent wrap +
            // wrong ordering in ReleaseFast (residual of BUG-212's guard).
            // Reached from create_connection(..., interleave=N) and the
            // happy_eyeballs path (interleave == 0 → interleave(..., 1)).
            if (interleave_count > 0) interleave_count -= 1;
        } else if (ipv4_index < ipv4_addresses) {
            // Defensive bounds guard: should be unreachable when counts are
            // correct, but protect against off-by-one in future refactors.
            v.* = tmp_list[ipv4_index];
            ipv4_index += 1;
        } else {
            // All addresses exhausted — should not happen.
            break;
        }
    }
}

test "interleave_address_list with mixed IPv4 and IPv6" {
    const allocator = std.testing.allocator;
    const addresses = try allocator.alloc(utils.Address, 5);
    defer allocator.free(addresses);

    addresses[0] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[1] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[2] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[3] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[4] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };

    try interleave_address_list(allocator, addresses, 1);

    try std.testing.expectEqual(std.posix.AF.INET6, addresses[0].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[1].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[2].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[3].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[4].any.family);
}

test "interleave_address_list with only IPv4" {
    const allocator = std.testing.allocator;
    const addresses = try allocator.alloc(utils.Address, 3);
    defer allocator.free(addresses);

    addresses[0] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[1] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[2] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };

    try interleave_address_list(allocator, addresses, 1);

    // Should remain unchanged
    try std.testing.expectEqual(std.posix.AF.INET, addresses[0].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[1].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[2].any.family);
}

test "interleave_address_list with only IPv6" {
    const allocator = std.testing.allocator;
    const addresses = try allocator.alloc(utils.Address, 3);
    defer allocator.free(addresses);

    addresses[0] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[1] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[2] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };

    try interleave_address_list(allocator, addresses, 1);

    // Should remain unchanged
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[0].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[1].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[2].any.family);
}

test "interleave_address_list with different interleave values" {
    const allocator = std.testing.allocator;
    const addresses = try allocator.alloc(utils.Address, 5);
    defer allocator.free(addresses);

    addresses[0] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[1] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[2] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[3] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[4] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };

    try interleave_address_list(allocator, addresses, 2);

    try std.testing.expectEqual(std.posix.AF.INET6, addresses[0].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[1].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[2].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[3].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[4].any.family);
}

test "interleave_address_list with multiple IPv6 addresses and interleave value 2" {
    const allocator = std.testing.allocator;
    const addresses = try allocator.alloc(utils.Address, 7);
    defer allocator.free(addresses);

    addresses[0] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[1] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[2] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[3] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[4] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[5] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[6] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };

    try interleave_address_list(allocator, addresses, 2);

    try std.testing.expectEqual(std.posix.AF.INET6, addresses[0].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[1].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[2].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[3].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[4].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[5].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[6].any.family);
}

test "interleave_address_list with many IPv6 and few IPv4 (BUG-212)" {
    const allocator = std.testing.allocator;
    const addresses = try allocator.alloc(utils.Address, 5);
    defer allocator.free(addresses);

    // 4 IPv6, 1 IPv4
    addresses[0] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    addresses[1] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[2] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[3] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    addresses[4] = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };

    try interleave_address_list(allocator, addresses, 1);

    // Order: IPv6, IPv4, IPv6, IPv6, IPv6 — after the IPv4 slot is used
    // up, the remaining IPv6 addresses append without touching the
    // counter (BUG-423: the decrement used to underflow at 0 here).
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[0].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, addresses[1].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[2].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[3].any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, addresses[4].any.family);
}

test "interleave_address_list underflow guard when IPv4 exhausted mid-run (BUG-423)" {
    // 1 IPv4 + 6 IPv6, interleave = 2: the counter hits 0 right after the
    // IPv4 slot is consumed and then must NOT be decremented again. Pre-fix
    // this panicked with an integer overflow in Debug/ReleaseSafe.
    const allocator = std.testing.allocator;
    const addresses = try allocator.alloc(utils.Address, 7);
    defer allocator.free(addresses);

    addresses[0] = utils.Address{ .any = .{ .family = std.posix.AF.INET, .data = undefined } };
    for (addresses[1..]) |*a| {
        a.* = utils.Address{ .any = .{ .family = std.posix.AF.INET6, .data = undefined } };
    }

    try interleave_address_list(allocator, addresses, 2);

    // Order: IPv6, IPv6, IPv4, IPv6, IPv6, IPv6, IPv6
    const expect_v6 = [_]bool{ true, true, false, true, true, true, true };
    for (addresses, 0..) |*a, i| {
        if (expect_v6[i]) {
            try std.testing.expectEqual(std.posix.AF.INET6, a.any.family);
        } else {
            try std.testing.expectEqual(std.posix.AF.INET, a.any.family);
        }
    }
}
