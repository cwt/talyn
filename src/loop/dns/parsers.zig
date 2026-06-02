const std = @import("std");
const utils = @import("utils");

// Localhost addresses for quick reference
const localhost_address_list: []const utils.Address = &[_]utils.Address{
    utils.Address.initIp4(
        .{ 127, 0, 0, 1 },
        0,
    ),
    utils.Address.initIp6(
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        0,
        0,
        0,
    ),
};

// TODO: Implement resolv options
pub const Configuration = struct {
    servers: []utils.Address,
    search: [][]u8,
};

pub fn validate_hostname(hostname: []const u8) bool {
    var iter = std.mem.splitScalar(u8, hostname, '.');
    while (iter.next()) |label| {
        if (label.len < 1 or label.len > 63) {
            return false;
        }

        if (label[0] == '-' or label[label.len - 1] == '-') {
            return false;
        }

        var has_hyphen = false;
        for (label) |c| {
            const hyphen = (c == '-');
            if (hyphen and has_hyphen) return false;
            has_hyphen = hyphen;

            if (!((c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or
                hyphen))
            {
                return false;
            }
        }
    }

    return true;
}

pub fn build_reverse_name(address: utils.Address, buf: []u8) ![]u8 {
    switch (address.any.family) {
        std.posix.AF.INET => {
            const ip = @as([4]u8, @bitCast(address.in.sa.addr));
            return try std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}.in-addr.arpa", .{ ip[3], ip[2], ip[1], ip[0] });
        },
        std.posix.AF.INET6 => {
            const ip = @as([16]u8, @bitCast(address.in6.sa.addr));
            var offset: usize = 0;
            var i: usize = 16;
            while (i > 0) {
                i -= 1;
                const byte = ip[i];
                const high = (byte >> 4) & 0x0F;
                const low = byte & 0x0F;
                offset += (try std.fmt.bufPrint(buf[offset..], "{x:1}.{x:1}.", .{ low, high })).len;
            }
            return try std.fmt.bufPrint(buf[offset..], "ip6.arpa", .{});
        },
        else => return error.UnsupportedAddressFamily,
    }
}

pub fn parse_name(full_data: []const u8, initial_offset: usize, allocator: std.mem.Allocator) ![]u8 {
    var result = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer result.deinit(allocator);
    
    var offset = initial_offset;
    var jump_offset: ?usize = null;
    var visited_pointers: usize = 0;
    const max_pointers = 10;

    while (offset < full_data.len) {
        const byte = full_data[offset];
        if (byte == 0) {
            offset += 1;
            break;
        }
        if ((byte & 0xC0) == 0xC0) {
            if (visited_pointers >= max_pointers) return error.MalformedDnsResponse;
            if (offset + 1 >= full_data.len) return error.MalformedDnsResponse;
            if (jump_offset == null) jump_offset = offset + 2;
            visited_pointers += 1;
            offset = (@as(usize, byte & 0x3F) << 8) | full_data[offset + 1];
            continue;
        }
        
        if (offset + 1 + byte > full_data.len) return error.MalformedDnsResponse;
        if (result.items.len > 0) try result.append(allocator, '.');
        try result.appendSlice(allocator, full_data[offset + 1 .. offset + 1 + byte]);
        offset += @as(usize, byte) + 1;
    }
    
    return try result.toOwnedSlice(allocator);
}

/// Resolve a hostname to one or more addresses synchronously.
/// Writes results to `out` and returns the number of addresses written.
/// Returns 0 if the hostname needs to be resolved asynchronously (DNS lookup).
///
/// BUG-48: The previous implementation returned a slice into module-level
/// mutable state (`tmp_address`), which was racy: concurrent callers would
/// all see the same memory, with the latest caller clobbering the others.
/// Now the caller owns the output buffer.
pub fn resolve_address(
    hostname: []const u8,
    allow_ipv6: bool,
    out: []utils.Address,
) !usize {
    // 1. Check for localhost
    if (std.mem.eql(u8, hostname, "localhost")) {
        const n = 1 + @as(usize, @intFromBool(allow_ipv6));
        if (out.len < n) return error.OutOfMemory;
        @memcpy(out[0..n], localhost_address_list[0..n]);
        return n;
    }

    // 2. Check for IPv4
    if (utils.Address.resolveIp(hostname, 0)) |res| {
        if (out.len < 1) return error.OutOfMemory;
        out[0] = res;
        return 1;
    } else |_| {}

    // 3. Check for IPv6
    if (allow_ipv6) {
        if (utils.Address.resolveIp6(hostname, 0)) |res| {
            if (out.len < 1) return error.OutOfMemory;
            out[0] = res;
            return 1;
        } else |_| {}
    }

    // 4. Validate hostname
    if (!validate_hostname(hostname)) {
        return error.InvalidHostname;
    }

    // If no match, return 0
    return 0;
}

pub fn parse_resolv_configuration(allocator: std.mem.Allocator, content: []const u8) !Configuration {
    var lines_iter = std.mem.tokenizeScalar(u8, content, '\n');

    const search_tmp_buf = try allocator.alloc(u8, 255);
    defer allocator.free(search_tmp_buf);

    var servers = std.ArrayList(utils.Address){ .items = &.{}, .capacity = 0 };
    defer servers.deinit(allocator);

    var search_hosts = std.ArrayList([]u8){ .items = &.{}, .capacity = 0 };
    defer search_hosts.deinit(allocator);
    errdefer {
        for (search_hosts.items) |host| {
            allocator.free(host);
        }
    }

    loop: while (lines_iter.next()) |line| {
        var words_iter = std.mem.tokenizeScalar(u8, line, ' ');

        const first_word = words_iter.next() orelse continue;

        var chr = first_word[0];
        if (chr == '#' or chr == ';') {
            continue;
        }

        if (std.mem.eql(u8, first_word, "nameserver")) {
            const ip_str = words_iter.next() orelse return error.InvalidConfiguration;
            const address = try utils.Address.parseIp(ip_str, 53);

            switch (address.any.family) {
                std.posix.AF.INET, std.posix.AF.INET6 => {},
                else => unreachable
            }
            
            try servers.append(allocator, address);
        } else if (std.mem.eql(u8, first_word, "search")) {
            while (words_iter.next()) |word| {
                chr = word[0];
                if (chr == '#' or chr == ';') {
                    continue :loop;
                }

                const parsed_hostname = std.ascii.lowerString(search_tmp_buf, word);
                if (!validate_hostname(parsed_hostname)) return error.InvalidConfiguration;

                const host = try allocator.dupe(u8, parsed_hostname);
                errdefer allocator.free(host);

                try search_hosts.append(allocator, host);
            }
        }
    }

    if (servers.items.len == 0) {
        try servers.append(allocator, try utils.Address.parseIp("1.1.1.1", 53));
    }

    const search_hosts_slice = try search_hosts.toOwnedSlice(allocator);
    errdefer {
        for (search_hosts_slice) |host| {
            allocator.free(host);
        }
        allocator.free(search_hosts_slice);
    }

    const servers_slice = try servers.toOwnedSlice(allocator);
    errdefer allocator.free(servers_slice);

    return Configuration{
        .search = search_hosts_slice,
        .servers = servers_slice,
    };
}

test "parse valid resolv.conf with nameservers and search domains" {
    const content =
        \\nameserver 8.8.8.8
        \\nameserver 1.1.1.1
        \\search example.com test.com
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try parse_resolv_configuration(allocator, content);

    try std.testing.expectEqual(@as(usize, 2), config.servers.len);
    try std.testing.expectEqual(@as(usize, 2), config.search.len);
    try std.testing.expectEqualStrings("example.com", config.search[0]);
    try std.testing.expectEqualStrings("test.com", config.search[1]);

    // Verify first nameserver details
    const first_server = config.servers[0];
    try std.testing.expectEqual(std.posix.AF.INET, first_server.any.family);
    const first_ip_bytes: [4]u8 = @bitCast(first_server.in.sa.addr);
    try std.testing.expectEqual(@as(u8, 8), first_ip_bytes[0]);
    try std.testing.expectEqual(@as(u8, 8), first_ip_bytes[1]);
    try std.testing.expectEqual(@as(u8, 8), first_ip_bytes[2]);
    try std.testing.expectEqual(@as(u8, 8), first_ip_bytes[3]);

    // Verify second nameserver details
    const second_server = config.servers[1];
    try std.testing.expectEqual(std.posix.AF.INET, second_server.any.family);
    const second_ip_bytes: [4]u8 = @bitCast(second_server.in.sa.addr);
    try std.testing.expectEqual(@as(u8, 1), second_ip_bytes[0]);
    try std.testing.expectEqual(@as(u8, 1), second_ip_bytes[1]);
    try std.testing.expectEqual(@as(u8, 1), second_ip_bytes[2]);
    try std.testing.expectEqual(@as(u8, 1), second_ip_bytes[3]);
}

test "parse resolv.conf with comments" {
    const content =
        \\# This is a comment
        \\nameserver 8.8.8.8
        \\; Another comment
        \\nameserver 1.1.1.1
        \\search example.com
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try parse_resolv_configuration(allocator, content);

    try std.testing.expectEqual(@as(usize, 2), config.servers.len);
    try std.testing.expectEqual(@as(usize, 1), config.search.len);
    try std.testing.expectEqualStrings("example.com", config.search[0]);

    // Verify first nameserver details
    const first_server = config.servers[0];
    try std.testing.expectEqual(std.posix.AF.INET, first_server.any.family);
    const first_ip_bytes: [4]u8 = @bitCast(first_server.in.sa.addr);
    try std.testing.expectEqual(@as(u8, 8), first_ip_bytes[0]);
    try std.testing.expectEqual(@as(u8, 8), first_ip_bytes[1]);
    try std.testing.expectEqual(@as(u8, 8), first_ip_bytes[2]);
    try std.testing.expectEqual(@as(u8, 8), first_ip_bytes[3]);

    // Verify second nameserver details
    const second_server = config.servers[1];
    try std.testing.expectEqual(std.posix.AF.INET, second_server.any.family);
    const second_ip_bytes: [4]u8 = @bitCast(second_server.in.sa.addr);
    try std.testing.expectEqual(@as(u8, 1), second_ip_bytes[0]);
    try std.testing.expectEqual(@as(u8, 1), second_ip_bytes[1]);
    try std.testing.expectEqual(@as(u8, 1), second_ip_bytes[2]);
    try std.testing.expectEqual(@as(u8, 1), second_ip_bytes[3]);
}

test "parse resolv.conf with invalid nameserver" {
    const content =
        \\nameserver invalid.ip
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(
        error.InvalidCharacter, 
        parse_resolv_configuration(allocator, content),
    );
}

test "parse resolv.conf with invalid search domain" {
    const content =
        \\nameserver 8.8.8.8
        \\search invalid--domain
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(
        error.InvalidConfiguration, 
        parse_resolv_configuration(allocator, content),
    );
}

test "parse empty resolv.conf" {
    const content = "";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try parse_resolv_configuration(allocator, content);
    defer {
        allocator.free(config.search);
        allocator.free(config.servers);
    }

    try std.testing.expectEqual(@as(usize, 1), config.servers.len);
    try std.testing.expectEqual(@as(usize, 0), config.search.len);
    
    // Verify default DNS server
    const default_dns = config.servers[0];
    try std.testing.expectEqual(std.posix.AF.INET, default_dns.any.family);
    
    const ip_bytes: [4]u8 = @bitCast(default_dns.in.sa.addr);
    try std.testing.expectEqual(@as(u8, 1), ip_bytes[0]);
    try std.testing.expectEqual(@as(u8, 1), ip_bytes[1]);
    try std.testing.expectEqual(@as(u8, 1), ip_bytes[2]);
    try std.testing.expectEqual(@as(u8, 1), ip_bytes[3]);
}

test "parse resolv.conf with IPv6 nameservers" {
    const content =
        \\nameserver 2001:4860:4860::8888
        \\nameserver 2606:4700:4700::1111
        \\search ipv6.example.com
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try parse_resolv_configuration(allocator, content);
    defer {
        allocator.free(config.search);
        allocator.free(config.servers);
    }

    try std.testing.expectEqual(@as(usize, 2), config.servers.len);
    try std.testing.expectEqual(@as(usize, 1), config.search.len);
    try std.testing.expectEqualStrings("ipv6.example.com", config.search[0]);

    // Verify first IPv6 nameserver details
    const first_server = config.servers[0];
    try std.testing.expectEqual(std.posix.AF.INET6, first_server.any.family);
    const first_ipv6_bytes: [16]u8 = @bitCast(first_server.in6.sa.addr);
    try std.testing.expectEqual(@as(u8, 0x20), first_ipv6_bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x01), first_ipv6_bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x48), first_ipv6_bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x60), first_ipv6_bytes[3]);
    
    // Verify second IPv6 nameserver details
    const second_server = config.servers[1];
    try std.testing.expectEqual(std.posix.AF.INET6, second_server.any.family);
    const second_ipv6_bytes: [16]u8 = @bitCast(second_server.in6.sa.addr);
    try std.testing.expectEqual(@as(u8, 0x26), second_ipv6_bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x06), second_ipv6_bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x47), second_ipv6_bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x00), second_ipv6_bytes[3]);
}

test "parse resolv.conf with mixed IPv4 and IPv6 nameservers" {
    const content =
        \\nameserver 8.8.8.8
        \\nameserver 2001:4860:4860::8888
        \\nameserver 1.1.1.1
        \\nameserver 2606:4700:4700::1111
        \\search mixed.example.com
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try parse_resolv_configuration(allocator, content);
    defer {
        allocator.free(config.search);
        allocator.free(config.servers);
    }

    try std.testing.expectEqual(@as(usize, 4), config.servers.len);
    try std.testing.expectEqual(@as(usize, 1), config.search.len);
    try std.testing.expectEqualStrings("mixed.example.com", config.search[0]);

    // Verify first IPv4 nameserver details
    const first_server = config.servers[0];
    try std.testing.expectEqual(std.posix.AF.INET, first_server.any.family);
    const first_ipv4_bytes: [4]u8 = @bitCast(first_server.in.sa.addr);
    try std.testing.expectEqual(@as(u8, 8), first_ipv4_bytes[0]);
    try std.testing.expectEqual(@as(u8, 8), first_ipv4_bytes[1]);
    try std.testing.expectEqual(@as(u8, 8), first_ipv4_bytes[2]);
    try std.testing.expectEqual(@as(u8, 8), first_ipv4_bytes[3]);

    // Verify first IPv6 nameserver details
    const second_server = config.servers[1];
    try std.testing.expectEqual(std.posix.AF.INET6, second_server.any.family);
    const first_ipv6_bytes: [16]u8 = @bitCast(second_server.in6.sa.addr);
    try std.testing.expectEqual(@as(u8, 0x20), first_ipv6_bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x01), first_ipv6_bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x48), first_ipv6_bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x60), first_ipv6_bytes[3]);

    // Verify second IPv4 nameserver details
    const third_server = config.servers[2];
    try std.testing.expectEqual(std.posix.AF.INET, third_server.any.family);
    const third_ipv4_bytes: [4]u8 = @bitCast(third_server.in.sa.addr);
    try std.testing.expectEqual(@as(u8, 1), third_ipv4_bytes[0]);
    try std.testing.expectEqual(@as(u8, 1), third_ipv4_bytes[1]);
    try std.testing.expectEqual(@as(u8, 1), third_ipv4_bytes[2]);
    try std.testing.expectEqual(@as(u8, 1), third_ipv4_bytes[3]);

    // Verify second IPv6 nameserver details
    const fourth_server = config.servers[3];
    try std.testing.expectEqual(std.posix.AF.INET6, fourth_server.any.family);
    const second_ipv6_bytes: [16]u8 = @bitCast(fourth_server.in6.sa.addr);
    try std.testing.expectEqual(@as(u8, 0x26), second_ipv6_bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x06), second_ipv6_bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x47), second_ipv6_bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x00), second_ipv6_bytes[3]);
}

test "validate_hostname valid domains" {
    const valid_domains = [_][]const u8{
        "example.com",
        "sub.example.com",
        "test-domain.co.uk",
        "my-domain.org",
        "a.b.c.d",
        "x1.y2.z3",
    };

    for (valid_domains) |domain| {
        try std.testing.expect(validate_hostname(domain));
    }
}

test "validate_hostname invalid domains" {
    const invalid_domains = [_][]const u8{
        "-example.com",     // Starts with hyphen
        "example-.com",     // Ends with hyphen
        "example--test.com", // Consecutive hyphens
        "exam!ple.com",     // Invalid characters
        "exam ple.com",     // Space in domain
        ".example.com",     // Starts with dot
        "example.com.",     // Ends with dot
    };

    for (invalid_domains) |domain| {
        try std.testing.expect(!validate_hostname(domain));
    }
}

test "validate_hostname edge cases" {
    const edge_cases = [_]struct { domain: []const u8, expected: bool }{
        .{ .domain = "a.com", .expected = true },           // Minimum valid length
        .{ .domain = "a-1.com", .expected = true },          // Hyphen with number
        .{ .domain = "a" ** 63 ++ ".com", .expected = true }, // Maximum label length
        .{ .domain = "a" ** 64 ++ ".com", .expected = false }, // Exceeds maximum label length
    };

    for (edge_cases) |case| {
        try std.testing.expectEqual(case.expected, validate_hostname(case.domain));
    }
}

test "resolve_address localhost" {
    // Test IPv4 localhost
    {
        var out: [2]utils.Address = undefined;
        const n = try resolve_address("localhost", false, &out);
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqual(std.posix.AF.INET, out[0].any.family);
    }

    // Test IPv4 and IPv6 localhost
    {
        var out: [2]utils.Address = undefined;
        const n = try resolve_address("localhost", true, &out);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqual(std.posix.AF.INET, out[0].any.family);
        try std.testing.expectEqual(std.posix.AF.INET6, out[1].any.family);
    }
}

test "resolve_address IPv4" {
    var out: [2]utils.Address = undefined;
    const n = try resolve_address("8.8.8.8", false, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(std.posix.AF.INET, out[0].any.family);
}

test "resolve_address IPv6" {
    var out: [2]utils.Address = undefined;
    const n = try resolve_address("2001:4860:4860::8888", true, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(std.posix.AF.INET6, out[0].any.family);
}

test "resolve_address invalid hostname" {
    var out: [2]utils.Address = undefined;
    const result = resolve_address("invalid--domain", false, &out);
    try std.testing.expectError(error.InvalidHostname, result);
}

test "resolve_address concurrent callers (BUG-48)" {
    // The previous implementation returned a slice into module-level
    // mutable state. Two sequential calls would see each other's
    // results. Now each call writes to a caller-owned buffer.
    var out_a: [2]utils.Address = undefined;
    var out_b: [2]utils.Address = undefined;
    const n_a = try resolve_address("8.8.8.8", false, &out_a);
    const n_b = try resolve_address("1.1.1.1", false, &out_b);
    try std.testing.expectEqual(@as(usize, 1), n_a);
    try std.testing.expectEqual(@as(usize, 1), n_b);
    // Both should be IPv4 (8.8.8.8 and 1.1.1.1 respectively),
    // not both pointing to the same memory (which would happen
    // with the bug — they'd both end up as 1.1.1.1).
    try std.testing.expectEqual(std.posix.AF.INET, out_a[0].any.family);
    try std.testing.expectEqual(std.posix.AF.INET, out_b[0].any.family);
    // Compare the IPv4 bytes: 8.8.8.8 vs 1.1.1.1 differ in the
    // first octet, so they should not be bytewise equal.
    const bytes_a: *const [4]u8 = @ptrCast(&out_a[0].in.sa.addr);
    const bytes_b: *const [4]u8 = @ptrCast(&out_b[0].in.sa.addr);
    try std.testing.expect(!std.mem.eql(u8, bytes_a, bytes_b));
}

test "parse_name simple uncompressed name" {
    const data = [_]u8{ 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0 };
    const name = try parse_name(&data, 0, std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("example.com", name);
}

test "parse_name compression pointer" {
    const data = [_]u8{
        3, 'c', 'o', 'm', 0,
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0xC0, 0,
    };
    const name = try parse_name(&data, 5, std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("example.com", name);
}

test "parse_name compression pointer at last byte is out-of-bounds" {
    const data = [_]u8{ 0xC0 };
    try std.testing.expectError(error.MalformedDnsResponse, parse_name(&data, 0, std.testing.allocator));
}

test "parse_name compression pointer second byte missing" {
    const data = [_]u8{ 3, 'f', 'o', 'o', 0xC0 };
    try std.testing.expectError(error.MalformedDnsResponse, parse_name(&data, 4, std.testing.allocator));
}

test "parse_name too many compression pointers" {
    var data: [22]u8 = undefined;
    for (0..11) |i| {
        data[i * 2] = 0xC0;
        data[i * 2 + 1] = @intCast((i + 1) * 2);
    }
    try std.testing.expectError(error.MalformedDnsResponse, parse_name(&data, 0, std.testing.allocator));
}
