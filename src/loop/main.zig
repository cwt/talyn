const std = @import("std");
const builtin = @import("builtin");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");
const lock = @import("../utils/lock.zig");

const CallbackManager = @import("callback_manager");
pub const Scheduling = @import("scheduling/main.zig");
const FSWatcher = @import("fs_watcher.zig");
const ChildWatcher = @import("child_watcher.zig");
const UnixSignals = @import("unix_signals.zig");
pub const Completion = @import("completion.zig");

pub const DNS = @import("dns/main.zig");
const Handle = @import("../handle.zig");

pub const WatchersBTree = utils.BTree(std.posix.fd_t, *FDWatcher, 11);

pub const FDWatcher = struct {
    handle: *Handle.PythonHandleObject,
    loop_data: *Loop,
    blocking_task_id: usize = 0,
    event_type: u32,
    fd: std.posix.fd_t,
    python_payload: CallbackManager.PythonPayload = .{},
};

pub const HooksList = utils.LinkedList(CallbackManager.Callback);

pub fn init_module(_: std.mem.Allocator) void {}

allocator: std.mem.Allocator,

initialized: bool = false,
running: bool = false,
stopping: bool = false,

reader_watchers: WatchersBTree,
writer_watchers: WatchersBTree,

prepare_hooks: HooksList,
check_hooks: HooksList,
idle_hooks: HooksList,

ready_tasks_queue_max_capacity: usize,

ready_tasks_queue_index: u8 = 0,
ready_tasks_queues: *[2]CallbackManager.DynamicRingBuffer,
reserved_slots: usize = 0,

io: Scheduling.IO,
dns: DNS,

/// P15 Phase 1: Batch buffer for IO completion records.
/// Zig writes CompletionRecords here during fetch_completed_tasks.
/// Python reads the batch and dispatches protocol methods in a tight loop.
completion_batch: Completion.CompletionBatch = .{},

fs_watcher: FSWatcher,
child_watcher: ChildWatcher,

mutex: lock.Mutex,

unix_signals: UnixSignals,

pub fn init(self: *Loop, allocator: std.mem.Allocator, rtq_capacity: usize) !void {
    if (self.initialized) {
        python_c.raise_python_runtime_error("Loop is already initialized\x00");
        return error.PythonError;
    }

    var reader_watchers = try WatchersBTree.init(allocator);
    errdefer reader_watchers.deinit() catch |err| std.log.warn("deinit failed: {s}", .{@errorName(err)});

    var writer_watchers = try WatchersBTree.init(allocator);
    errdefer writer_watchers.deinit() catch |err| std.log.warn("deinit failed: {s}", .{@errorName(err)});

    const queues = try allocator.create([2]CallbackManager.DynamicRingBuffer);
    errdefer allocator.destroy(queues);
    queues.* = .{ .{}, .{} };
    try queues[0].init(allocator, rtq_capacity);
    errdefer queues[0].deinit();
    try queues[1].init(allocator, rtq_capacity);
    // Mirror queues[0]: if a later init step fails, free queues[1]'s buffers
    // too. Without this, a failed loop.init (e.g. io_uring ring setup under a
    // clamped RLIMIT_MEMLOCK) leaks queues[1].callbacks / executed.
    errdefer queues[1].deinit();

    self.allocator = allocator;
    self.mutex = lock.init();
    self.ready_tasks_queues = queues;
    self.ready_tasks_queue_index = 0;
    self.reserved_slots = 0;
    self.reader_watchers = reader_watchers;
    self.writer_watchers = writer_watchers;
    self.prepare_hooks = HooksList.init(allocator);
    self.check_hooks = HooksList.init(allocator);
    self.idle_hooks = HooksList.init(allocator);
    self.fs_watcher = .{};
    self.child_watcher = .{};
    self.unix_signals = .{};
    self.io = .{};
    self.dns = .{};
    self.running = false;
    self.stopping = false;
    self.ready_tasks_queue_max_capacity = rtq_capacity;

    try self.fs_watcher.init(self);
    try self.child_watcher.init(self);

    try self.io.init(self, allocator);
    errdefer self.io.deinit();

    try self.io.register_eventfd_callback();

    try UnixSignals.init(self);
    errdefer self.unix_signals.deinit();

    try self.dns.init(self);
    errdefer self.dns.deinit();

    self.initialized = true;
}

pub fn release(self: *Loop) void {
    if (!self.initialized) return;
    if (self.running) {
        python_c.raise_python_runtime_error("Loop is running, can't be deallocated\x00");
        return;
    }
    self.initialized = false;

    self.dns.deinit();
    self.fs_watcher.deinit();
    self.child_watcher.deinit();
    self.unix_signals.deinit();

    // Release pending callbacks while IO is still functional.
    for (self.ready_tasks_queues) |*ready_tasks_queue| {
        CallbackManager.release_dynamic_ring_buffer(ready_tasks_queue);
    }

    // BUG-29: Drain the FD watchers BEFORE `io.deinit()`. The `FDWatcher`
    // structs contain `blocking_task_id` referencing io_uring tasks, and
    // draining them may need to call `io.cancel(...)` to clean up
    // in-flight operations. If we deinit the ring first, those operations
    // are leaked and any cleanup logic in the watcher dtor is no longer
    // able to communicate with the kernel.
    {
        var sig: std.posix.fd_t = undefined;
        // BUG-274: invalidate each watcher's fd while popping. Cancelled
        // completions of the armed polls are dispatched AFTER the trees
        // below are deinit'd; their cleanup callback calls
        // reader_watchers.delete(fd) / writer_watchers.delete(fd) when fd
        // is still valid, traversing a freed B-tree root.
        while (self.reader_watchers.pop(&sig)) |watcher| {
            watcher.fd = -1;
        }
        while (self.writer_watchers.pop(&sig)) |watcher| {
            watcher.fd = -1;
        }
    }
    self.reader_watchers.deinit() catch |err| std.log.warn("deinit failed: {s}", .{@errorName(err)});
    self.writer_watchers.deinit() catch |err| std.log.warn("deinit failed: {s}", .{@errorName(err)});

    self.io.deinit();

    // Release callbacks dispatched by cancel_all during io.deinit().
    for (self.ready_tasks_queues) |*ready_tasks_queue| {
        CallbackManager.release_dynamic_ring_buffer(ready_tasks_queue);
    }

    // BUG-332: only now can DNS control data released during teardown be
    // destroyed - the cancel completions above still reference it.
    self.dns.release_deferred();

    for (self.ready_tasks_queues) |*q| {
        q.deinit();
    }
    self.allocator.destroy(self.ready_tasks_queues);

    // BUG-62: Use clear_with_cleanup to invoke each Callback's
    // cleanup function before destroying the linked-list node.
    // This prevents Python object reference leaks on loop
    // release.
    self.prepare_hooks.clear_with_cleanup(struct {
        fn cb(data: CallbackManager.Callback) void {
            if (data.cleanup) |cleanup| {
                cleanup(data.data.user_data);
            }
        }
    }.cb);
    self.check_hooks.clear_with_cleanup(struct {
        fn cb(data: CallbackManager.Callback) void {
            if (data.cleanup) |cleanup| {
                cleanup(data.data.user_data);
            }
        }
    }.cb);
    self.idle_hooks.clear_with_cleanup(struct {
        fn cb(data: CallbackManager.Callback) void {
            if (data.cleanup) |cleanup| {
                cleanup(data.data.user_data);
            }
        }
    }.cb);
}

pub inline fn reserve_slots(self: *Loop, amount: usize) !void {
    self.reserved_slots += amount;
}

pub const HookType = enum {
    prepare,
    check,
    idle,
};

pub fn add_hook(self: *Loop, hook_type: HookType, callback: CallbackManager.Callback) !HooksList.Node {
    const mutex = &self.mutex;
    mutex.lock();
    defer mutex.unlock();

    const hooks = switch (hook_type) {
        .prepare => &self.prepare_hooks,
        .check => &self.check_hooks,
        .idle => &self.idle_hooks,
    };
    const node = try hooks.create_new_node(callback);
    hooks.append_node(node);
    return node;
}

pub fn remove_hook(self: *Loop, hook_type: HookType, node: HooksList.Node) void {
    const mutex = &self.mutex;
    mutex.lock();
    defer mutex.unlock();

    const hooks = switch (hook_type) {
        .prepare => &self.prepare_hooks,
        .check => &self.check_hooks,
        .idle => &self.idle_hooks,
    };
    hooks.unlink_node(node) catch |err| std.log.warn("unlink_node failed: {s}", .{@errorName(err)});
    hooks.release_node(node);
}

pub const Runner = @import("runner.zig");
pub const Python = @import("python/main.zig");

test "loop hooks" {
    const allocator = std.testing.allocator;
    const loop = try allocator.create(Loop);
    defer allocator.destroy(loop);

    try loop.init(allocator, 1024);
    defer loop.release();

    const Mock = struct {
        called_count: usize = 0,
        fn callback(data: *const CallbackManager.CallbackData) !void {
            const self: *@This() = @ptrCast(@alignCast(data.user_data.?));
            self.called_count += 1;
        }
    };

    var prepare_mock = Mock{};
    var check_mock = Mock{};

    const p_node = try loop.add_hook(.prepare, .{
        .func = &Mock.callback,
        .cleanup = null,
        .data = .{ .user_data = &prepare_mock },
    });

    const c_node = try loop.add_hook(.check, .{
        .func = &Mock.callback,
        .cleanup = null,
        .data = .{ .user_data = &check_mock },
    });

    // Manually execute hooks since we are not running the full loop
    var node = loop.prepare_hooks.first;
    while (node) |n| {
        try n.data.func(&n.data.data);
        node = n.next;
    }

    try std.testing.expectEqual(@as(usize, 1), prepare_mock.called_count);
    try std.testing.expectEqual(@as(usize, 0), check_mock.called_count);

    loop.remove_hook(.prepare, p_node);
    loop.remove_hook(.check, c_node);

    try std.testing.expectEqual(@as(usize, 0), loop.prepare_hooks.len);
    try std.testing.expectEqual(@as(usize, 0), loop.check_hooks.len);
}

test "syscall optimization" {
    const allocator = std.testing.allocator;
    const loop = try allocator.create(Loop);
    defer allocator.destroy(loop);

    try loop.init(allocator, 1024);
    defer loop.release();

    // Verify initially the SQ queue has 2 infrastructure SQEs (eventfd & signalfd)
    try std.testing.expectEqual(@as(u32, 2), loop.io.ring.sq_ready());

    // First flush should submit both and return 2
    const submitted1 = try loop.io.flush_pending_sqes();
    try std.testing.expectEqual(@as(u32, 2), submitted1);

    // Verify the SQ queue is now empty and subsequent flushes short-circuit to 0
    try std.testing.expectEqual(@as(u32, 0), loop.io.ring.sq_ready());
    const submitted2 = try loop.io.flush_pending_sqes();
    try std.testing.expectEqual(@as(u32, 0), submitted2);
}

test "BUG-02: link_timeout failure rollback" {
    const allocator = std.testing.allocator;
    const loop = try allocator.create(Loop);
    defer allocator.destroy(loop);

    try loop.init(allocator, 1024);
    defer loop.release();

    const ring = &loop.io.ring;
    const capacity = ring.sq.sqes.len;

    // Clear any infrastructure SQEs
    _ = try loop.io.flush_pending_sqes();

    // Fill the ring until there is exactly 1 slot left
    var i: usize = 0;
    while (i < capacity - 1) : (i += 1) {
        _ = try ring.get_sqe();
    }

    try std.testing.expectEqual(@as(u32, @intCast(capacity - 1)), ring.sq_ready());

    const mock_callback = CallbackManager.Callback{
        .func = undefined,
        .cleanup = undefined,
        .data = .{ .user_data = null },
    };
    const timeout_ts = std.os.linux.kernel_timespec{ .sec = 1, .nsec = 0 };
    const wait_data = Scheduling.IO.WaitData{
        .fd = 0,
        .callback = mock_callback,
        .timeout = timeout_ts,
    };

    const set = try loop.io.get_blocking_tasks_set();
    const result = Scheduling.IO.Read.wait_ready(ring, set, wait_data);

    // The call should fail with SubmissionQueueFull
    try std.testing.expectError(error.SubmissionQueueFull, result);

    // If rollback succeeded, ring.sq_ready() should still be capacity - 1, and NOT capacity!
    try std.testing.expectEqual(@as(u32, @intCast(capacity - 1)), ring.sq_ready());
}

test "BUG-334: link_timeout timespec must be heap-resident, not a dead stack pointer" {
    const allocator = std.testing.allocator;
    const loop = try allocator.create(Loop);
    defer allocator.destroy(loop);

    try loop.init(allocator, 1024);
    defer loop.release();

    const ring = &loop.io.ring;

    // Drop the infrastructure SQEs so the last-SQE index below is unambiguous.
    _ = try loop.io.flush_pending_sqes();

    const set = try loop.io.get_blocking_tasks_set();
    const payload = try allocator.alloc(u8, 64);
    defer allocator.free(payload);
    const iovs = try allocator.alloc(std.posix.iovec_const, 1);
    defer allocator.free(iovs);
    iovs[0] = .{ .base = payload.ptr, .len = payload.len };

    const callback = CallbackManager.Callback{
        .func = struct {
            fn noop(_: *const CallbackManager.CallbackData) !void {}
        }.noop,
        .cleanup = null,
        .data = .{ .user_data = null },
    };
    const timeout = std.os.linux.kernel_timespec{ .sec = 7, .nsec = 42 };

    // The kernel dereferences sqe.addr of a LINK_TIMEOUT SQE at *submit* time,
    // and submission is deferred past the queuing frame. So sqe.addr must land
    // on the BlockingTask's persistent timer_storage inside task_data_pool,
    // never on the caller's stack. Every case is rolled back (SQE popped from the
    // SQ, task slot discarded) so the test leaves the ring and set pristine and
    // never submits these SQEs to the kernel.
    const Verify = struct {
        fn run(ring_: *std.os.linux.IoUring, set_: *Scheduling.IO.BlockingTasksSet, task: *Scheduling.IO.BlockingTask, expected: std.os.linux.kernel_timespec) !void {
            const sqe = &ring_.sq.sqes[(ring_.sq.sqe_tail -% 1) & ring_.sq.mask];

            try std.testing.expectEqual(std.os.linux.IORING_OP.LINK_TIMEOUT, sqe.opcode);

            const addr = sqe.addr;
            const pool_start = @intFromPtr(&set_.task_data_pool[0]);
            const pool_end = pool_start + Scheduling.IO.TotalTasksItems * @sizeOf(Scheduling.IO.BlockingTask);

            try std.testing.expect(addr >= pool_start and addr < pool_end);
            try std.testing.expectEqual(@intFromPtr(&task.timer_storage), addr);

            // The value the kernel reads at submit time must still be the
            // requested timeout, not whatever now occupies the reclaimed frame.
            const readback: *const std.os.linux.kernel_timespec = @ptrFromInt(addr);
            try std.testing.expectEqual(expected.sec, readback.sec);
            try std.testing.expectEqual(expected.nsec, readback.nsec);

            task.discard();
        }
    };

    // The loop's persistent infrastructure reads (eventfd wake-up +
    // signalfd) are live tasks in this same set; capture the baseline
    // before the cases so queued-then-discarded tasks leave no residue.
    const baseline_active = set.active_tasks;
    const saved_slots = loop.reserved_slots;

    {
        const tail_before = ring.sq.sqe_tail;
        const task_slot = try Scheduling.IO.Read.wait_ready(ring, set, .{
            .callback = callback,
            .fd = 0,
            .timeout = timeout,
        });
        try Verify.run(ring, set, @ptrFromInt(task_slot), timeout);
        ring.sq.sqe_tail = tail_before;
    }
    {
        const tail_before = ring.sq.sqe_tail;
        const task_slot = try Scheduling.IO.Read.perform(ring, set, .{
            .callback = callback,
            .fd = 0,
            .data = .{ .buffer = payload },
            .timeout = timeout,
        });
        try Verify.run(ring, set, @ptrFromInt(task_slot), timeout);
        ring.sq.sqe_tail = tail_before;
    }
    {
        const tail_before = ring.sq.sqe_tail;
        const task_slot = try Scheduling.IO.Write.wait_ready(ring, set, .{
            .callback = callback,
            .fd = 0,
            .timeout = timeout,
        });
        try Verify.run(ring, set, @ptrFromInt(task_slot), timeout);
        ring.sq.sqe_tail = tail_before;
    }
    {
        const tail_before = ring.sq.sqe_tail;
        const task_slot = try Scheduling.IO.Write.perform(ring, set, .{
            .callback = callback,
            .fd = 0,
            .data = payload,
            .timeout = timeout,
        });
        try Verify.run(ring, set, @ptrFromInt(task_slot), timeout);
        ring.sq.sqe_tail = tail_before;
    }
    {
        const tail_before = ring.sq.sqe_tail;
        const task_slot = try Scheduling.IO.Write.perform_with_iovecs(ring, set, .{
            .callback = callback,
            .fd = 0,
            .data = iovs,
            .timeout = timeout,
        });
        try Verify.run(ring, set, @ptrFromInt(task_slot), timeout);
        ring.sq.sqe_tail = tail_before;
    }

    // Every queued SQE was rolled back and every task discarded — no
    // slot, no reserved-slot and no submission-queue residue.
    try std.testing.expectEqual(saved_slots, loop.reserved_slots);
    try std.testing.expectEqual(baseline_active, set.active_tasks);
    try std.testing.expectEqual(@as(u32, 0), ring.sq_ready());
}

test "BUG-117: registered-buffer fallback when io_uring buffer registration fails (low RLIMIT_MEMLOCK)" {
    // Force io_uring_register(IORING_REGISTER_BUFFERS) to fail by clamping the
    // pinned-memory soft limit below the 1 MiB RegisteredBufferPool needs, while
    // keeping it high enough for the io_uring ring + fixed-file table to still
    // initialize. Keep `max` untouched so we can restore it afterwards (raising
    // cur up to max is always allowed). Restore via defer so the clamp never
    // leaks to other tests.
    var orig: std.os.linux.rlimit = undefined;
    _ = std.os.linux.getrlimit(.MEMLOCK, &orig);
    defer _ = std.os.linux.setrlimit(.MEMLOCK, &orig);

    const clamped: std.os.linux.rlimit = .{ .cur = 1024 * 1024 - 65536, .max = orig.max };
    _ = std.os.linux.setrlimit(.MEMLOCK, &clamped);

    const allocator = std.testing.allocator;
    const loop = try allocator.create(Loop);
    defer allocator.destroy(loop);

    // When io_uring ring setup itself fails under the clamped RLIMIT_MEMLOCK
    // (the documented unguarded error path — .NOMEM at IoUring.init_params),
    // the registered-buffer fallback cannot be reached. Skip rather than fail;
    // the fallback is still exercised where ring setup succeeds.
    loop.init(allocator, 1024) catch |err| {
        if (err == error.SystemResources) return;
        return err;
    };
    defer loop.release();

    // On privileged environments (CAP_IPC_LOCK) RLIMIT_MEMLOCK is bypassed and
    // registration always succeeds, so the fallback cannot be exercised here.
    if (loop.io.buffers_registered) return;

    // Fallback must have engaged: no buffers registered, lease returns null, and
    // releasing a never-leased index is a safe no-op.
    try std.testing.expectEqual(false, loop.io.buffers_registered);
    try std.testing.expect(loop.io.lease_buffer() == null);
    loop.io.release_buffer(0);

    // Tear-down must be clean (no double-free / use-after-free). loop.release()
    // runs IO.deinit, which owns buffer_pool exactly once.
}

const Loop = @This();
