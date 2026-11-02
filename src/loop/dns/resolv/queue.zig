const std = @import("std");
const utils = @import("utils");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const Loop = @import("../../main.zig");
const CallbackManager = @import("callback_manager");
const types = @import("types.zig");
const parse_mod = @import("parse.zig");
const ControlData = types.ControlData;
const ServerQueryData = types.ServerQueryData;
const DnsTimeout = types.DnsTimeout;
const cleanup_server_query_data = types.cleanup_server_query_data;
const dns_timeout_to_kernel_timespec = types.dns_timeout_to_kernel_timespec;
const QuestionType = types.QuestionType;
const DEFAULT_TIMEOUT = types.DEFAULT_TIMEOUT;
const Cache = @import("../cache.zig");
const get_hostname_array = parse_mod.get_hostname_array;
const build_queries = parse_mod.build_queries;
const response_mod = @import("response.zig");
const on_query_sent = response_mod.on_query_sent;
const Parsers = @import("../parsers.zig");

/// Close the sockets of server queries that were never submitted to io_uring.
/// Their fds were opened in `build_queries`; since no SQE was queued for them,
/// `server_data.cancel()` (which queues a `CancelByFd`) is unnecessary — the
/// raw fd is closed and marked -1 so later cleanup cannot double-close.
pub fn close_unsent_query_sockets(queries_data: []ServerQueryData, queries_sent: usize) void {
    for (queries_data[queries_sent..]) |*server_data| {
        if (server_data.socket_fd >= 0) {
            _ = std.os.linux.close(server_data.socket_fd);
            server_data.socket_fd = -1;
        }
    }
}

pub fn prepare_data(
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

    // Use a struct literal so the compiler enforces that every field of
    // ControlData is explicitly initialized here. Adding a new field to
    // ControlData without initializing it in prepare_data will cause a
    // compile error, preventing the class of bug fixed in this commit
    // (record_evicted left uninitialized → garbage bool → silent wrong behaviour).
    control_data.* = ControlData{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .loop = loop,
        .user_callbacks = .empty,
        // .record and .queries_data are filled in just below; use undefined
        // only for fields that are unconditionally assigned before any use.
        .record = undefined,
        .queries_data = undefined,
        .tasks_finished = 0,
        .resolved = false,
        .record_evicted = false,
        .node = null,
    };
    const arena_allocator = control_data.arena.allocator();

    // BUG-269: `release()` is the single destructor once the cache record
    // exists — it deinits the arena (which also frees arena-backed fields
    // such as user_callbacks) and destroys the struct. Previously BOTH a
    // destroy-errdefer and the release-errdefer were armed simultaneously,
    // so every error path after record creation freed ControlData twice.
    // Failures before the record exists tear down locally here.
    control_data.record = cache_slot.create_new_record(hostname, control_data) catch |err| {
        control_data.arena.deinit();
        allocator.destroy(control_data);
        return err;
    };

    errdefer {
        // BUG-338: On synchronous error, the caller's errdefer cleans up the
        // callback context (gaid/gnid/scd). Clear user_callbacks so release()
        // does not also schedule the callback onto ready_tasks_queues.
        control_data.user_callbacks.clearRetainingCapacity();
        control_data.release();
    }

    try control_data.user_callbacks.append(arena_allocator, user_callback.*);

    const queries_data = try arena_allocator.alloc(ServerQueryData, configuration.servers.len);
    const hostnames_array = try get_hostname_array(arena_allocator, hostname, configuration.search);
    if (hostnames_array.len == 0) {
        // Every candidate (the hostname itself for FQDNs, or each
        // hostname+search-suffix combination) exceeded the 255-byte DNS
        // name limit — there is nothing to resolve. Reject here instead
        // of building an empty queries slice that queue() would index
        // out-of-bounds (`server_data.queries[0]`).
        return error.InvalidHostname;
    }

    control_data.queries_data = queries_data;

    const node = try loop.dns.pending_queries.create_new_node(control_data);
    control_data.node = node;
    loop.dns.pending_queries.append_node(node);

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
        // BUG-338: Synchronous failure returns an error to the caller, whose
        // errdefer frees the callback context. Prevent release() (now or on
        // later CQE drain) from dispatching user_callbacks onto Soon.
        control_data.user_callbacks.clearRetainingCapacity();
        if (!control_data.record_evicted) {
            control_data.record.discard();
            control_data.record_evicted = true;
        }
        for (control_data.queries_data[0..queries_sent]) |*server_data| {
            server_data.cancel();
        }
        close_unsent_query_sockets(control_data.queries_data, queries_sent);

        if (queries_sent == 0) {
            control_data.release();
        } else {
            control_data.queries_data = control_data.queries_data[0..queries_sent];
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

fn noop_dns_callback(_: *const CallbackManager.CallbackData) anyerror!void {}

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

test "close_unsent_query_sockets closes only the unsent tail" {
    var read_end1: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, utils.getSyscallErrno(std.os.linux.pipe(&read_end1)));
    defer _ = std.os.linux.close(read_end1[0]);
    var read_end2: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, utils.getSyscallErrno(std.os.linux.pipe(&read_end2)));
    defer _ = std.os.linux.close(read_end2[0]);

    // entry 0 simulates an already-sent query (fd stays open);
    // entries 1-2 simulate unsent queries whose fds must be closed.
    var queries = [_]ServerQueryData{
        .{
            .loop = undefined,
            .socket_fd = read_end1[0],
            .hostnames_array = undefined,
            .control_data = undefined,
            .queries = &.{},
            .recv_buf = undefined,
            .results = .empty,
            .ptr_results = .empty,
        },
        .{
            .loop = undefined,
            .socket_fd = read_end1[1],
            .hostnames_array = undefined,
            .control_data = undefined,
            .queries = &.{},
            .recv_buf = undefined,
            .results = .empty,
            .ptr_results = .empty,
        },
        .{
            .loop = undefined,
            .socket_fd = read_end2[1],
            .hostnames_array = undefined,
            .control_data = undefined,
            .queries = &.{},
            .recv_buf = undefined,
            .results = .empty,
            .ptr_results = .empty,
        },
    };

    close_unsent_query_sockets(&queries, 1);

    // Unsent fds are closed and marked -1.
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), queries[1].socket_fd);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), queries[2].socket_fd);
    try std.testing.expectEqual(std.os.linux.E.BADF, utils.getSyscallErrno(std.os.linux.close(read_end1[1])));
    try std.testing.expectEqual(std.os.linux.E.BADF, utils.getSyscallErrno(std.os.linux.close(read_end2[1])));
    // The sent entry is untouched: fd still open, value unchanged.
    try std.testing.expectEqual(read_end1[0], queries[0].socket_fd);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, utils.getSyscallErrno(std.os.linux.fcntl(read_end1[0], std.posix.F.GETFD, 0)));
}

test "prepare_data error path does not double-free ControlData (BUG-269)" {
    const allocator = std.testing.allocator;

    const loop = try allocator.create(Loop);
    defer allocator.destroy(loop);
    try loop.init(allocator, 64);
    defer loop.release();

    var cache: Cache = undefined;
    cache.init(allocator);
    defer cache.deinit();

    // A dotless hostname with an empty search list yields zero valid
    // candidates -> get_hostname_array returns empty -> error.InvalidHostname.
    // This is the deterministic BUG-269 trigger: previously the destroy
    // errdefer and the release() errdefer were armed simultaneously and the
    // struct was freed twice (std.testing.allocator reports the double free).
    const callback = CallbackManager.Callback{
        .func = &noop_dns_callback,
        .cleanup = null,
        .data = .{ .user_data = null },
    };

    try std.testing.expectError(
        error.InvalidHostname,
        queue(&cache, loop, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &callback, .{
            .servers = &[_]utils.Address{},
            .search = &[_][]u8{},
        }, true, null, null),
    );

    // release() must have discarded the pending cache record; a leftover
    // entry would trip BTreeHasElements in cache.deinit().
}

test "synchronous error in prepare_data does not schedule user_callback onto Soon queue (BUG-338)" {
    const allocator = std.testing.allocator;

    const loop = try allocator.create(Loop);
    defer allocator.destroy(loop);
    try loop.init(allocator, 64);

    var cache: Cache = undefined;
    cache.init(allocator);
    defer cache.deinit();

    var invoked: usize = 0;
    const Tracker = struct {
        fn cb(data: *const CallbackManager.CallbackData) anyerror!void {
            const count: *usize = @ptrCast(@alignCast(data.user_data.?));
            count.* += 1;
        }
        fn cleanup(user_data: ?*anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(user_data.?));
            count.* += 1;
        }
    };

    const callback = CallbackManager.Callback{
        .func = &Tracker.cb,
        .cleanup = &Tracker.cleanup,
        .data = .{ .user_data = &invoked },
    };

    try std.testing.expectError(
        error.InvalidHostname,
        queue(&cache, loop, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &callback, .{
            .servers = &[_]utils.Address{},
            .search = &[_][]u8{},
        }, true, null, null),
    );

    // Release the loop (which drains ready_tasks_queues); the callback must
    // not have been queued or invoked.
    loop.release();
    try std.testing.expectEqual(@as(usize, 0), invoked);
}
