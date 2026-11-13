const std = @import("std");
const utils = @import("utils");
const Loop = @import("../../main.zig");
const CallbackManager = @import("callback_manager");
const types = @import("types.zig");
const parse_mod = @import("parse.zig");
const ControlData = types.ControlData;
const ServerQueryData = types.ServerQueryData;
const DEFAULT_TIMEOUT = types.DEFAULT_TIMEOUT;
const parse_individual_dns_result = parse_mod.parse_individual_dns_result;
const skip_name = parse_mod.skip_name;
const dns_timeout_to_kernel_timespec = types.dns_timeout_to_kernel_timespec;
const QuerySlot = types.QuerySlot;
const should_fail_resolution_on_server_finish = types.should_fail_resolution_on_server_finish;
const cleanup_server_query_data = types.cleanup_server_query_data;

pub fn mark_resolved_and_execute_user_callbacks(server_data: *ServerQueryData) !void {
    const control_data = server_data.control_data;

    // BUG-316: idempotency guard. The caller-side `control_data.resolved`
    // checks (process_dns_response, on_query_sent) already keep the normal
    // path single-shot; this guard makes the entry point itself safe for
    // any future caller, so a second invocation can never evict the cached
    // record and re-dispatch user callbacks whose futures already carry a
    // result (asyncio.InvalidStateError).
    if (control_data.resolved) return;
    control_data.resolved = true;
    // The errdefer covers only the RECORD-SETUP phase below: nothing has
    // been dispatched yet there, so letting a later server event retry the
    // whole resolution is clean. The dispatch phase (end of the function)
    // must NEVER reset `resolved` - see the BUG-316 residual comment there.
    errdefer control_data.resolved = false;

    for (control_data.queries_data) |*sd| {
        // Cancel only live servers (finished ones already closed their
        // fd to -1, so cancel() would no-op — same BUG-336 discipline as
        // the connect task_ids: never target completed work).
        if (sd.finished) continue;
        sd.cancel();
    }

    // FD-number variant of BUG-336: the cancels above sit in the deferred
    // submission queue while their fds are already closed, and the user
    // callbacks dispatched below run synchronously before the next flush.
    // A callback opening a socket can reuse a just-closed fd number, and
    // the kernel would then cancel the NEW occupant's ops (CancelByFd
    // matches by number at execution time). Submit the cancels now so
    // they are consumed before any Python can reuse fd numbers. Cheap:
    // no-op when the submission queue is empty.
    _ = control_data.loop.io.flush_pending_sqes() catch |err| std.log.warn("DNS cancel flush failed: {s}", .{@errorName(err)});

    if (!control_data.record_evicted) {
        if (server_data.ptr_results.items.len > 0) {
            const ptr_name = try control_data.allocator.dupe(u8, server_data.ptr_results.items[0]);
            control_data.record.set_ptr_data(ptr_name, server_data.min_ttl);
        } else if (server_data.results.items.len > 0) {
            const address_list = try control_data.allocator.dupe(utils.Address, server_data.results.items);
            control_data.record.set_resolved_data(address_list, server_data.min_ttl);
        } else {
            control_data.record.discard();
        }
    }

    // BUG-316 (residual window): the dispatch phase must never reset
    // `resolved`. The old errdefer ran on a mid-dispatch Soon.dispatch
    // failure too - a later server event then re-ran this function, evicted
    // the freshly cached record and re-dispatched ALL user callbacks
    // (including the ones whose futures already completed ->
    // asyncio.InvalidStateError). From here the resolution stands: on a
    // dispatch failure the remaining callbacks are failed as cancelled
    // (best effort, mirroring ControlData.release's unresolved path) so no
    // future hangs, and `resolved` stays true so nothing re-enters.
    const loop = control_data.loop;
    var dispatched: usize = 0;
    for (control_data.user_callbacks.items) |*v| {
        if (Loop.Scheduling.Soon.dispatch(loop, v)) |_| {
            dispatched += 1;
        } else |err| {
            std.log.warn("DNS user callback dispatch failed ({s}); failing the remaining callbacks as cancelled", .{@errorName(err)});
            for (control_data.user_callbacks.items[dispatched..]) |*rest| {
                rest.data.set_cancelled(true);
                Loop.Scheduling.Soon.dispatch_nonthreadsafe(loop, rest) catch |err2| {
                    std.log.warn("dispatch cancelled DNS callback failed: {s}", .{@errorName(err2)});
                };
            }
            return;
        }
    }
}

/// Queue an io_uring read for the next DNS response datagram into recv_buf.
/// BUG-317 decision helper: true when THIS server is the last outstanding
/// one and nobody has resolved yet - i.e. its failure ends the lookup.
pub fn queue_next_response_read(server_data: *ServerQueryData) !void {
    _ = try server_data.loop.io.queue(.{
        .PerformRead = .{
            .callback = .{
                .func = &process_dns_response,
                .cleanup = &cleanup_server_query_data,
                .data = .{ .user_data = server_data },
            },
            .data = .{ .buffer = &server_data.recv_buf },
            .fd = server_data.socket_fd,
            .timeout = if (server_data.dns_timeout) |t| dns_timeout_to_kernel_timespec(t) else DEFAULT_TIMEOUT,
        },
    });
}

/// io_uring completion callback for each individual DNS query write.
/// Sends the next query if one is pending; otherwise starts reading responses.
pub fn on_query_sent(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();

    const server_data: *ServerQueryData = @ptrCast(@alignCast(data.user_data.?));
    const control_data = server_data.control_data;

    if (io_uring_err != .SUCCESS or control_data.resolved or data.cancelled()) {
        // BUG-357: mirror the BUG-317 pattern from the response-read error
        // path — when the send fails on the LAST outstanding nameserver
        // (e.g. ENETUNREACH while offline), release() below would dispatch
        // the user callbacks as cancelled, leaving getaddrinfo/getnameinfo
        // futures pending forever. Mark the record resolved first so the
        // callbacks run (and fail the futures cleanly with the empty
        // record).
        if (should_fail_resolution_on_server_finish(control_data)) {
            try mark_resolved_and_execute_user_callbacks(server_data);
        }
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

/// Continue reading responses for `server_data`, or finish resolution once
/// all queries on this nameserver are accounted for (only marking the lookup
/// resolved when this server has answers or is the last outstanding server).
fn finish_or_continue_response_read(server_data: *ServerQueryData) !void {
    const control_data = server_data.control_data;
    if (server_data.responses_received < server_data.queries.len and !control_data.resolved) {
        try queue_next_response_read(server_data);
    } else {
        if (server_data.results.items.len > 0 or server_data.ptr_results.items.len > 0 or should_fail_resolution_on_server_finish(control_data)) {
            try mark_resolved_and_execute_user_callbacks(server_data);
        }
        server_data.release();
    }
}

/// Consume at most one response credit for an error/malformed packet on
/// `matched_slot` and either wait for the remaining queries or finalize.
fn reject_slot_response_and_continue(server_data: *ServerQueryData, matched_slot: ?*QuerySlot) !void {
    if (matched_slot) |slot| slot.answered = true;
    server_data.responses_received += 1;
    try finish_or_continue_response_read(server_data);
}

pub fn process_dns_response(data: *const CallbackManager.CallbackData) !void {
    const io_uring_err = data.io_uring_err();
    const io_uring_res = data.io_uring_res();

    const server_data: *ServerQueryData = @ptrCast(@alignCast(data.user_data.?));
    const control_data = server_data.control_data;

    if (data.cancelled() or control_data.resolved) {
        server_data.release();
        return;
    }

    if (io_uring_err != .SUCCESS) {
        // BUG-317: a timeout/io error on ONE nameserver must not abort the
        // whole multi-server resolution - the remaining nameservers may
        // still answer. Release this server only; the lookup is failed
        // through the record machinery (empty results -> discard, giving
        // the callbacks the established error semantics) only when the
        // LAST outstanding nameserver finishes without anyone having
        // resolved.
        if (server_data.results.items.len > 0 or server_data.ptr_results.items.len > 0 or should_fail_resolution_on_server_finish(control_data)) {
            try mark_resolved_and_execute_user_callbacks(server_data);
        }
        server_data.release();
        return;
    }

    const bytes = @as(usize, @intCast(io_uring_res));
    const response = server_data.recv_buf[0..bytes];

    // Validate the response ID against all pending query IDs.
    // BUG-433: hoisted to function scope — the per-candidate completion
    // check below needs the matched slot even after the parse block.
    var matched_slot: ?*QuerySlot = null;
    if (bytes >= 2) {
        const response_id = std.mem.readInt(u16, response[0..2], .big);
        for (server_data.queries) |*slot| {
            if (response_id == slot.id) {
                matched_slot = slot;
                break;
            }
        }

        if (matched_slot) |slot| {
            if (slot.answered) {
                // BUG-433: ignore duplicate/retransmitted UDP replies for an
                // already-answered QuerySlot so they cannot append duplicate
                // records, credit the candidate twice, or prematurely advance
                // `responses_received` to `queries.len`.
                try finish_or_continue_response_read(server_data);
                return;
            }
        }

        if (matched_slot != null and bytes < 12) {
            try reject_slot_response_and_continue(server_data, matched_slot);
            return;
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
                // Invalid flags: consume this slot once without parsing answers.
                try reject_slot_response_and_continue(server_data, matched_slot);
                return;
            }

            // BUG-45: Check the TC (truncated) bit. If set, the response
            // was cut off and is incomplete. UDP responses can be
            // truncated for large answers; the client should retry over
            // TCP. For now, we reject truncated responses and fall back
            // to the next server / treat as empty.
            const tc = (flags & 0x0200) != 0;
            if (tc) {
                try reject_slot_response_and_continue(server_data, matched_slot);
                return;
            }

            const qdcount = std.mem.readInt(u16, response[4..6], .big);
            const ancount = std.mem.readInt(u16, response[6..8], .big);

            // BUG-44: Validate the question section. The response should
            // echo the query's question section exactly. Without this
            // check, a forged response for a different domain (or a
            // different QTYPE) could be accepted.
            if (qdcount != 1) {
                try reject_slot_response_and_continue(server_data, matched_slot);
                return;
            }

            // The question section in the response starts at byte 12 and
            // is `slot.len - 12` bytes long (the original query buffer
            // minus the 12-byte header). The full question section
            // includes the label-encoded hostname plus QTYPE and QCLASS.
            const slot = matched_slot.?;
            const question_len = slot.len - 12;
            if (bytes < 12 + question_len) {
                try reject_slot_response_and_continue(server_data, matched_slot);
                return;
            }
            const response_question = response[12 .. 12 + question_len];
            const query_question = slot.buf[12..slot.len];
            if (!std.mem.eql(u8, response_question, query_question)) {
                // Question mismatch: forged response for a different query.
                try reject_slot_response_and_continue(server_data, matched_slot);
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
                    var result: utils.Address = .{ .any = .{ .family = 0, .data = @splat(0) } };
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

    // BUG-433: per-hostname completion tracking instead of a global modulo
    // counter. The old `responses_received % types_per_host == 0` assumed
    // responses arrive in send order; with interleaved replies
    // (a.A, b.A, a.AAAA, b.AAAA) it declared a candidate done after any
    // two responses and resolved with a partial/mixed result set (dropping
    // AAAA addresses). A candidate is done when all of its own query
    // types have been answered, matched per QuerySlot.
    const current_candidate_done = if (matched_slot) |slot|
        server_data.credit_response_and_check_candidate_done(slot)
    else
        false;

    if (server_data.results.items.len > 0 or server_data.ptr_results.items.len > 0) {
        if (current_candidate_done or server_data.responses_received >= server_data.queries.len) {
            try mark_resolved_and_execute_user_callbacks(server_data);
            server_data.release();
            return;
        }
    }

    // Wait for more responses if queries remain outstanding; otherwise
    // resolve if answers are present or this was the last outstanding server
    // (BUG-384 / BUG-317), then release.
    try finish_or_continue_response_read(server_data);
}

test "mark_resolved_and_execute_user_callbacks is idempotent (BUG-316)" {
    // With `resolved` already set, the function must return immediately
    // WITHOUT touching the record, the queries, or the loop - a second
    // invocation used to evict the cached record and re-dispatch user
    // callbacks whose futures already carried a result
    // (asyncio.InvalidStateError). The stub fields are `undefined`
    // on purpose: reaching them would crash the test.
    const control_data = try std.testing.allocator.create(ControlData);
    defer std.testing.allocator.destroy(control_data);
    control_data.* = ControlData{
        .allocator = std.testing.allocator,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .loop = undefined,
        .user_callbacks = .empty,
        .record = undefined,
        .queries_data = undefined,
        .tasks_finished = 0,
        .resolved = true,
        .record_evicted = false,
        .node = null,
    };
    defer control_data.arena.deinit();

    var server_data: ServerQueryData = .{
        .loop = undefined,
        .socket_fd = -1,
        .hostnames_array = undefined,
        .control_data = control_data,
        .queries = &.{},
        .results = .empty,
        .ptr_results = .empty,
    };

    try mark_resolved_and_execute_user_callbacks(&server_data);
    try std.testing.expect(control_data.resolved);
}

test "BUG-433 / BUG-317: finish_or_continue_response_read with empty results defers failure while another server is pending" {
    var stub_loop: Loop = undefined;
    stub_loop.initialized = false;

    const control_data = try std.testing.allocator.create(ControlData);
    defer std.testing.allocator.destroy(control_data);
    control_data.* = ControlData{
        .allocator = std.testing.allocator,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .loop = &stub_loop,
        .user_callbacks = .empty,
        .record = undefined,
        .queries_data = undefined,
        .tasks_finished = 0,
        .resolved = false,
        .record_evicted = false,
        .node = null,
    };
    defer control_data.arena.deinit();

    var slots: [1]QuerySlot = .{.{ .id = 7, .len = 17 }};
    const server0: ServerQueryData = .{
        .loop = &stub_loop,
        .socket_fd = -1,
        .hostnames_array = undefined,
        .control_data = control_data,
        .queries = &slots,
        .results = .empty,
        .ptr_results = .empty,
        .responses_received = 0,
    };
    var servers: [2]ServerQueryData = .{ server0, server0 };
    control_data.queries_data = servers[0..];

    // Server 0 receives a rejected (e.g. TC=1 / qdcount!=1) response matching
    // its only query slot while server 1 is still active: slot must be marked
    // answered, server 0 released, and `control_data.resolved` must stay
    // false so server 1 can still resolve the lookup.
    try reject_slot_response_and_continue(&servers[0], &slots[0]);
    try std.testing.expect(slots[0].answered);
    try std.testing.expectEqual(@as(u32, 1), servers[0].responses_received);
    try std.testing.expect(servers[0].finished);
    try std.testing.expectEqual(@as(usize, 1), control_data.tasks_finished);
    try std.testing.expect(!control_data.resolved);
}

test "BUG-433: process_dns_response ignores duplicate reply for already-answered QuerySlot" {
    var stub_loop: Loop = undefined;
    stub_loop.initialized = false;

    const control_data = try std.testing.allocator.create(ControlData);
    defer std.testing.allocator.destroy(control_data);
    control_data.* = ControlData{
        .allocator = std.testing.allocator,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .loop = &stub_loop,
        .user_callbacks = .empty,
        .record = undefined,
        .queries_data = undefined,
        .tasks_finished = 0,
        .resolved = false,
        .record_evicted = false,
        .node = null,
    };
    defer control_data.arena.deinit();

    // Build one already-answered QuerySlot matching a minimal response packet
    // (id=0x1234, QR=1, qdcount=1, ancount=1, QNAME="a.", QTYPE=A, QCLASS=IN, A=127.0.0.1).
    var slots: [1]QuerySlot = .{.{ .id = 0x1234, .len = 19, .answered = true }};
    const question = [_]u8{ 0x01, 'a', 0x00, 0x00, 0x01, 0x00, 0x01 };
    @memcpy(slots[0].buf[12..19], &question);

    const server0: ServerQueryData = .{
        .loop = &stub_loop,
        .socket_fd = -1,
        .hostnames_array = undefined,
        .control_data = control_data,
        .queries = &slots,
        .results = .empty,
        .ptr_results = .empty,
        .responses_received = 1,
    };
    var servers: [2]ServerQueryData = .{ server0, server0 };
    control_data.queries_data = servers[0..];

    const pkt = [_]u8{
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x01, 'a',  0x00, 0x00, 0x01, 0x00, 0x01, // question
        0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x00, 0x3C, 0x00, 0x04,
        127, 0, 0, 1, // A record answer
    };
    @memcpy(servers[0].recv_buf[0..pkt.len], &pkt);

    var cb_data: CallbackManager.CallbackData = .{ .user_data = &servers[0] };
    cb_data.set_io(@intCast(pkt.len), .SUCCESS);
    try process_dns_response(&cb_data);

    // Must NOT parse the duplicate A record or bump responses_received past 1.
    try std.testing.expectEqual(@as(usize, 0), servers[0].results.items.len);
    try std.testing.expectEqual(@as(u32, 1), servers[0].responses_received);
    try std.testing.expect(!control_data.resolved);
}
