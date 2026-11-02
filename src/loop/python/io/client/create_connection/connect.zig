const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const CallbackManager = @import("callback_manager");

const Loop = @import("../../../../main.zig");

const Future = @import("../../../../../future/main.zig");

const types = @import("types.zig");
const transport_mod = @import("transport.zig");
const interleave_mod = @import("interleave.zig");
const TransportCreationData = types.TransportCreationData;
const SocketConnectionData = types.SocketConnectionData;
const MultiConnectState = types.MultiConnectState;
const set_future_exception = Future.Python.Result.set_future_exception;
const interleave_address_list = interleave_mod.interleave_address_list;
const SocketData = types.SocketData;
const z_create_transport_and_set_future_result = transport_mod.z_create_transport_and_set_future_result;

fn create_socket_and_submit_connect_req(address: *const utils.Address, data: *SocketData, loop: *Loop) !usize {
    const flags = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;
    const socket_ret = std.os.linux.socket(address.any.family, flags, std.os.linux.IPPROTO.TCP);
    const socket_err = utils.getSyscallErrno(socket_ret);
    if (socket_err != .SUCCESS) return utils.socketSyscallError(socket_err);
    const socket_fd: std.posix.fd_t = @intCast(socket_ret);
    errdefer _ = std.os.linux.close(socket_fd);

    data.socket_fd = socket_fd;
    errdefer data.socket_fd = -1;

    const task_id = try Loop.Scheduling.IO.queue(&loop.io, .{
        .SocketConnect = .{
            .addr = &address.any,
            .len = address.getOsSockLen(),
            .socket_fd = socket_fd,
            .callback = .{
                .func = &socket_connected_callback,
                .cleanup = null,
                .data = CallbackManager.CallbackData.init_python(data, &data.python_payload),
            },
        },
    });

    return task_id;
}

fn submit_connect_for_address(mcs: *MultiConnectState, address: *const utils.Address, allocator: std.mem.Allocator, loop: *Loop) !void {
    const socket_data = try allocator.create(SocketData);
    // Single owner of socket_data on the error path. errdefer frees it exactly
    // once on any error return (including the later task_ids.append failure).
    // The success path transfers ownership to the io_uring callback chain, so
    // it must NOT be freed here.
    errdefer allocator.destroy(socket_data);
    socket_data.* = .{ .multi_state = mcs, .socket_fd = -1, .python_payload = .{
        .module_ptr = @ptrCast(mcs.connection_data.creation_data.loop.?),
        .callback_ptr = @ptrCast(mcs.connection_data.creation_data.future.?),
        .traverse = &SocketData.traverse,
    } };

    // BUG-412: reserve the bookkeeping slot BEFORE queueing the SQE. If this
    // fails, no kernel operation references socket_data yet, so the errdefer
    // can safely destroy it. appendAssumeCapacity below is infallible.
    try mcs.task_ids.ensureUnusedCapacity(allocator, 1);

    const task_id = create_socket_and_submit_connect_req(address, socket_data, loop) catch |err| {
        // Do NOT free socket_data here: the errdefer at the top of this
        // function already runs on every error return (including this one),
        // so freeing here would double-free. See BUG-04 class of defects.
        return err;
    };
    socket_data.task_id = task_id;
    mcs.task_ids.appendAssumeCapacity(task_id);
    mcs.pending += 1;
}

fn schedule_remaining_connects_callback(data: *const CallbackManager.CallbackData) !void {
    const mcs: *MultiConnectState = @ptrCast(@alignCast(data.user_data.?));
    // When a happy-eyeballs timer is scheduled, this callback owns `mcs`
    // teardown (BUG-120). The connect callbacks defer to us while
    // `timer_scheduled and !timer_fired`, because cancelling the timer still
    // enqueues this callback (it runs on fire OR on cancel). Freeing `mcs`
    // here — while it is still alive — avoids the use-after-free where the
    // success path freed `mcs` (when the first connect won) and this callback
    // then ran on the freed `mcs`.
    // BUG-336: the timer slot is freed before we run, so drop its id first.
    // A later factory-scheduled timer may already reuse that slot; leaving
    // the stale id behind would cancel the new occupant (deinit) or match
    // it spuriously.
    mcs.happy_timer_id = null;
    if (data.cancelled() or mcs.succeeded) {
        if (mcs.pending == 0) mcs.deinit();
        return;
    }

    mcs.timer_fired = true;
    // S4a: liveness is happy_timer_id != null (cleared above); retire the
    // historical scheduled flag with it so later `timer_scheduled and
    // !timer_fired` checks cannot desync. All evaluate identically.
    mcs.timer_scheduled = false;

    const connection_data = mcs.connection_data;
    const creation_data = connection_data.creation_data;
    const loop = creation_data.loop.?;
    const loop_data = utils.get_data_ptr(Loop, loop);
    const allocator = loop_data.allocator;

    const address_list = connection_data.address_list.?;
    for (address_list[1..]) |*addr| {
        submit_connect_for_address(mcs, addr, allocator, loop_data) catch |err| {
            // S4c: fail fast, then abort the round. The first connect is
            // still in flight and owns mcs until it completes — deinit here
            // would leave its SocketData dangling (UAF in removeTaskId).
            // Mark aborted (completions only close + count down, never
            // touch the resolved future) and cancel the pending connects;
            // the last completion tears mcs down.
            set_future_exception(err, creation_data.future.?) catch |e| {
                std.log.warn("abort set_future_exception failed: {s}", .{@errorName(e)});
            };
            mcs.aborted = true;
            for (mcs.task_ids.items) |task_id| {
                _ = Loop.Scheduling.IO.queue(&loop_data.io, .{ .CancelIO = task_id }) catch |e| std.log.warn("queue cancel failed: {s}", .{@errorName(e)});
            }
            if (mcs.pending == 0) mcs.deinit();
            return;
        };
    }
}

fn z_create_socket_connection(data: *SocketConnectionData) !void {
    const creation_data = data.creation_data;
    const address_list = data.address_list orelse {
        python_c.raise_python_runtime_error("No addresses to connect to");
        return error.PythonError;
    };

    const interleave: usize = blk: {
        const py_interleave = creation_data.py_interleave orelse break :blk 0;
        const value = python_c.PyLong_AsUnsignedLongLong(py_interleave);
        if (@as(c_longlong, @bitCast(value)) == -1) {
            if (python_c.PyErr_Occurred()) |_| {
                return error.PythonError;
            }
        }
        break :blk @intCast(value);
    };

    const loop = creation_data.loop.?;
    const loop_data = utils.get_data_ptr(Loop, loop);
    const allocator = loop_data.allocator;

    if (interleave > 0) {
        try interleave_address_list(allocator, address_list, interleave);
    }

    const all_errors: bool = blk: {
        const py_all_errors = creation_data.py_all_errors orelse break :blk false;
        const rc = python_c.PyObject_IsTrue(py_all_errors);
        if (rc < 0) return error.PythonError;
        break :blk rc == 1;
    };

    // `connection_data` (== `data`) is owned by `create_socket_connection` until we
    // successfully build `mcs` below. The guard frees it on any error that occurs
    // *before* that handoff; once `mcs` exists it owns `connection_data` and frees it
    // in `MultiConnectState.deinit`. This prevents a double-free: an error after `mcs`
    // creation used to be freed both by `mcs.deinit` and again by the caller's cleanup
    // (BUG-118 exposed this by making the submit-error path propagate instead of
    // swallowing it and returning null).
    var mcs_owns_connection_data = false;
    errdefer {
        if (!mcs_owns_connection_data) {
            data.deinit();
        }
    }

    const mcs = try MultiConnectState.init(allocator, data, all_errors);
    errdefer {
        if (mcs.pending == 0) {
            mcs.deinit();
        } else {
            // S4d: connects are in flight — their SocketData borrows mcs,
            // so deinit here would UAF in removeTaskId. Abort instead: the
            // caller fails the future on this error path, completions only
            // close + count down (see aborted), and the last one tears
            // mcs down. Cancel the pending connects; they are live.
            mcs.aborted = true;
            for (mcs.task_ids.items) |task_id| {
                _ = Loop.Scheduling.IO.queue(&loop_data.io, .{ .CancelIO = task_id }) catch |e| std.log.warn("queue cancel failed: {s}", .{@errorName(e)});
            }
        }
    }
    mcs_owns_connection_data = true;

    var delay: f64 = 0.25;
    if (creation_data.py_happy_eyeballs_delay) |py_delay| {
        if (interleave == 0) {
            try interleave_address_list(allocator, address_list, 1);
        }
        delay = python_c.PyFloat_AsDouble(py_delay);
        if (python_c.PyErr_Occurred() != null) return error.PythonError;
        if (!std.math.isFinite(delay) or delay < 0.0) {
            delay = 0;
        } else {
            const eps = comptime std.math.floatEps(f64);
            // BUG-51: Use `@abs(delay + 1.0) < eps` (symmetric)
            // instead of `(delay + 1.0) < eps` (asymmetric). The
            // previous check only caught values where delay+1.0 was
            // very slightly above 0; values like -0.9999 (delay+1.0
            // = 0.0001, > eps) would not be caught.
            if (@abs(delay + 1.0) < eps) {
                delay = 0;
            }
        }
    }

    if (address_list.len == 0) {
        // S4b: nothing was ever submitted (pending == 0), so resolve the
        // future first — exactly like the all-connects-failed path below —
        // and then tear mcs down explicitly. A bare return would skip the
        // errdefer (success path) and leak mcs + connection_data.
        python_c.raise_python_runtime_error("No addresses resolved");
        try set_future_exception(error.PythonError, creation_data.future.?);
        mcs.deinit();
        return;
    }

    const port: u16 = blk: {
        const py_port = creation_data.py_port orelse break :blk 0;
        const value = python_c.PyLong_AsInt(py_port);
        if (value == -1) {
            if (python_c.PyErr_Occurred()) |_| return error.PythonError;
        }
        // BUG-361: negative/huge ports panicked the u16 narrowing.
        if (value < 0 or value > 65535) {
            python_c.raise_python_value_error("port must be 0-65535\x00");
            return error.PythonError;
        }
        break :blk @intCast(value);
    };
    for (address_list) |*addr| {
        addr.setPort(port);
    }

    // Submit first address immediately
    try submit_connect_for_address(mcs, &address_list[0], allocator, loop_data);

    // Schedule remaining addresses after happy eyeballs delay
    if (address_list.len > 1 and delay > 0) {
        const callback = CallbackManager.Callback{
            .func = &schedule_remaining_connects_callback,
            .cleanup = null,
            .data = CallbackManager.CallbackData.init_python(mcs, &mcs.python_payload),
        };
        const max_delay_secs: f64 = @floatFromInt(std.math.maxInt(std.posix.time_t) - 1_000_000_000);
        const safe_delay = @min(delay, max_delay_secs);
        const sec_f = @floor(safe_delay);
        const seconds: u64 = @intFromFloat(sec_f);
        const frac = @max(0.0, safe_delay - sec_f);
        const nanoseconds: u64 = @intFromFloat(@min(999_999_999.0, frac * 1e9));
        const duration: std.os.linux.timespec = .{
            .sec = @intCast(seconds),
            .nsec = @intCast(nanoseconds),
        };
        const timer_task_id = try Loop.Scheduling.IO.queue(&loop_data.io, .{
            .WaitTimer = .{
                .duration = duration,
                .delay_type = .Relative,
                .callback = callback,
            },
        });
        // BUG-336: tracked separately from task_ids (see happy_timer_id).
        mcs.happy_timer_id = timer_task_id;
        mcs.timer_scheduled = true;
    } else {
        // Submit all remaining immediately (no delay)
        for (address_list[1..]) |*addr| {
            try submit_connect_for_address(mcs, addr, allocator, loop_data);
        }
    }
}

pub fn create_socket_connection(data: *const CallbackManager.CallbackData) !void {
    const socket_creation_data: *SocketConnectionData = @ptrCast(@alignCast(data.user_data.?));
    // Capture the future handle up front: any failure path below may free
    // `connection_data` (and the `creation_data` it embeds), so we must not read
    // `socket_creation_data.creation_data.future` after such a free.
    const fut = socket_creation_data.creation_data.future.?;

    // `connection_data` is owned by this callback until `z_create_socket_connection`
    // succeeds in creating the `MultiConnectState` (which then owns it and frees it in
    // `MultiConnectState.deinit`). On cancellation before that handoff we still own it
    // and must free it here; any failure *inside* `z_create_socket_connection` is owned
    // there (it frees `connection_data` directly, or lets `mcs.deinit` do so). We must
    // NOT free `connection_data` on the error path, or it would be freed twice.
    if (data.cancelled()) {
        python_c.raise_python_runtime_error("Event for socket creation cancelled");
        socket_creation_data.deinit();
        return set_future_exception(error.PythonError, fut);
    }

    z_create_socket_connection(socket_creation_data) catch |err| {
        return set_future_exception(err, fut);
    };
}

// -----------------------------------------------------------------
// STEP#4: Socket connected (or failed to connect)

/// Remove a completed task from the pending list (swap-remove). Completed
/// tasks must never be cancelled: their slot is already freed and may be
/// reused by unrelated later work (BUG-336).
fn removeTaskId(mcs: *MultiConnectState, task_id: usize) void {
    for (mcs.task_ids.items, 0..) |id, idx| {
        if (id == task_id) {
            _ = mcs.task_ids.swapRemove(idx);
            return;
        }
    }
}

fn socket_connected_callback(data: *const CallbackManager.CallbackData) !void {
    const socket_data: *SocketData = @ptrCast(@alignCast(data.user_data.?));
    const mcs = socket_data.multi_state;
    const fd = socket_data.socket_fd;
    // BUG-336: this request is complete — drop its id so the success-path
    // and deinit CancelIO rounds only hit still-pending connects. The freed
    // slot can be reused (e.g. by a factory-scheduled call_later timer)
    // before those cancels execute; cancelling the stale id would kill the
    // new occupant and fire its callback immediately.
    const completed_id = socket_data.task_id;
    removeTaskId(mcs, completed_id);

    const creation_data = mcs.connection_data.creation_data;
    const loop = creation_data.loop.?;
    const loop_data = utils.get_data_ptr(Loop, loop);
    const allocator = loop_data.allocator;
    allocator.destroy(socket_data);

    mcs.pending -= 1;

    // S4c/S4d: the round was aborted — the future is already resolved and
    // mcs is owed to this last completion. Never touch the future or
    // create a transport; just drop the fd and count down to teardown.
    if (mcs.aborted) {
        if (fd >= 0) _ = std.os.linux.close(fd);
        if (!(mcs.timer_scheduled and !mcs.timer_fired) and mcs.pending == 0) mcs.deinit();
        return;
    }

    if (mcs.succeeded or data.cancelled()) {
        if (fd >= 0) _ = std.os.linux.close(fd);
        if (!(mcs.timer_scheduled and !mcs.timer_fired) and mcs.pending == 0) mcs.deinit();
        return;
    }

    const io_uring_res = data.io_uring_res();
    const io_uring_err = data.io_uring_err();

    if (io_uring_err != .SUCCESS or io_uring_res < 0) {
        // BUG-359: close the failed socket immediately — the fallible
        // exception bookkeeping below must not be able to skip the close
        // (cleanup_socket_connected_callback only destroys the struct; it
        // does not close the fd).
        if (fd >= 0) _ = std.os.linux.close(fd);
        // BUG-359: when this is the final pending connect (and no
        // happy-eyeballs timer is waiting to fire), mcs must be torn down
        // on every exit path, including if the all_errors bookkeeping
        // below fails.
        defer if (mcs.pending == 0 and !(mcs.timer_scheduled and !mcs.timer_fired)) {
            mcs.deinit();
        };

        if (mcs.all_errors) {
            const errno_val = if (io_uring_res < 0) -io_uring_res else @intFromEnum(io_uring_err);
            const exc = python_c.PyObject_CallFunction(python_c.PyExc_OSError, "is\x00", @as(c_int, @intCast(errno_val)), "Connect call failed\x00") orelse return error.PythonError;
            defer python_c.py_decref(exc);
            if (python_c.PyList_Append(mcs.exceptions.?, exc) != 0) return error.PythonError;
        }

        mcs.failed_count += 1;

        if (mcs.pending == 0) {
            if (mcs.timer_scheduled and !mcs.timer_fired) {
                // The happy-eyeballs timer callback owns the final
                // teardown in this state.
                return;
            }

            const future = creation_data.future.?;
            const future_data = utils.get_data_ptr(Future, future);

            if (mcs.all_errors) {
                const builtins = python_c.PyImport_ImportModule("builtins\x00") orelse return error.PythonError;
                defer python_c.py_decref(builtins);
                const exc_group_cls = python_c.PyObject_GetAttrString(builtins, "ExceptionGroup\x00") orelse return error.PythonError;
                defer python_c.py_decref(exc_group_cls);

                const msg = python_c.PyUnicode_FromString("Multiple connection failures\x00") orelse return error.PythonError;
                defer python_c.py_decref(msg);

                const exc_group = python_c.PyObject_CallFunctionObjArgs(exc_group_cls, msg, mcs.exceptions.?, @as(?*python_c.PyObject, null)) orelse return error.PythonError;
                defer python_c.py_decref(exc_group);

                // BUG-359: a cancelled/finished future raised
                // InvalidStateError here and skipped mcs.deinit().
                if (future_data.status == .pending) {
                    try Future.Python.Result.future_fast_set_exception(@ptrCast(future), future_data, exc_group);
                }
            } else {
                const errno_val = if (io_uring_res < 0) -io_uring_res else @intFromEnum(io_uring_err);
                const exc = python_c.PyObject_CallFunction(
                    python_c.PyExc_OSError,
                    "is\x00",
                    @as(c_int, @intCast(errno_val)),
                    "Connect call failed\x00",
                ) orelse {
                    const exc = python_c.PyErr_GetRaisedException() orelse return error.PythonError;
                    defer python_c.py_decref(exc);
                    if (future_data.status == .pending) {
                        try Future.Python.Result.future_fast_set_exception(
                            @ptrCast(future),
                            future_data,
                            exc,
                        );
                    }
                    return error.PythonError;
                };
                defer python_c.py_decref(exc);
                // BUG-359: see the all_errors branch — never leak mcs on a
                // non-pending future.
                if (future_data.status == .pending) {
                    try Future.Python.Result.future_fast_set_exception(@ptrCast(future), future_data, exc);
                }
            }
        }
        return;
    }

    // Success — mark and create transport (synchronous)
    mcs.succeeded = true;

    // task_ids holds only still-pending connects (the winner removed
    // itself above). Cancel the still-armed happy-eyeballs timer as well
    // so its callback runs the BUG-120 teardown path.
    for (mcs.task_ids.items) |task_id| {
        _ = loop_data.io.queue(.{ .CancelIO = task_id }) catch |err| std.log.warn("queue cancel failed: {s}", .{@errorName(err)});
    }
    if (mcs.timer_scheduled and !mcs.timer_fired) {
        if (mcs.happy_timer_id) |timer_id| {
            _ = loop_data.io.queue(.{ .CancelIO = timer_id }) catch |err| std.log.warn("queue cancel failed: {s}", .{@errorName(err)});
        }
    }

    const fut = creation_data.future orelse {
        if (!(mcs.timer_scheduled and !mcs.timer_fired) and mcs.pending == 0) mcs.deinit();
        return error.PythonError;
    };
    const protocol_factory = creation_data.protocol_factory orelse {
        if (!(mcs.timer_scheduled and !mcs.timer_fired) and mcs.pending == 0) mcs.deinit();
        return set_future_exception(error.PythonError, fut);
    };

    var transport_creation_data = TransportCreationData{
        .protocol_factory = protocol_factory,
        .future = fut,
        .loop = loop,
        .socket_fd = fd,
        .zero_copying = false,
        .fd_created = true,
    };
    defer {
        if (transport_creation_data.fd_created) {
            _ = std.os.linux.close(@intCast(transport_creation_data.socket_fd));
        }
    }

    z_create_transport_and_set_future_result(&transport_creation_data) catch |err| {
        if (!(mcs.timer_scheduled and !mcs.timer_fired) and mcs.pending == 0) mcs.deinit();
        return set_future_exception(err, fut);
    };
    transport_creation_data.fd_created = false;
    if (!(mcs.timer_scheduled and !mcs.timer_fired) and mcs.pending == 0) mcs.deinit();
    return;
}

// -----------------------------------------------------------------
// STEP#5: Create transport and set future result
