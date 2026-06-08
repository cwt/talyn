const std = @import("std");
const builtin = @import("builtin");

const utils =  @import("utils");
const python_c = @import("python_c");

const CallbackManager = @import("callback_manager");
const Loop = @import("../../main.zig");

pub const Read = @import("read.zig");
pub const Write = @import("write.zig");
pub const Timer = @import("timer.zig");
pub const Cancel = @import("cancel.zig");
pub const Socket = @import("socket.zig");

pub const TotalTasksItems = 1024;

pub const BlockingOperation = enum {
    WaitReadable,
    WaitWritable,
    PerformRead,
    PerformWrite,
    PerformWriteV,
    PerformRecvMsg,
    PerformSendMsg,
    WaitTimer,
    Cancel,
    CancelByFd,
    SocketShutdown,
    SocketConnect,
    SocketAccept,
};

pub const BlockingTaskData = union(enum) {
    callback: CallbackManager.Callback,
    none,
};

pub const BlockingTask = struct {
    data: BlockingTaskData,
    operation: BlockingOperation,
    index: u16,

    /// Persistent storage for io_uring pointer target data.
    /// io_uring stores pointers in sqe.addr that the kernel dereferences
    /// at submit time. With deferred submission, the pointed-to data must
    /// outlive the caller's stack. These fields live in task_data_pool,
    /// enabling deferred (batched) submission for ALL operation types.
    timer_storage: std.os.linux.kernel_timespec = undefined,

    /// Storage for zero-copy msghdr (sendmsg/recvmsg with MSG.ZEROCOPY).
    /// The caller's iovecs point to heap-allocated transport buffers,
    /// but the enclosing msghdr itself would otherwise live on the stack.
    /// Storing it here allows deferred submission for zero-copy paths.
    msg_storage: std.posix.msghdr = undefined,

    /// Storage for a single iovec used by Write.perform zero-copy path.
    /// That path builds a [1]iovec_const on the stack pointing to the
    /// data buffer; with deferred submission, the iovec array must also
    /// live in task_data_pool.
    write_iov: std.posix.iovec = undefined,

    /// Storage for a multi-iovec copy used by Write.perform_with_iovecs.
    /// BUG-30: The caller's iovec array might be stack-allocated, but
    /// the kernel reads it at submit time (which may be deferred). We
    /// copy the caller's iovecs into this heap-resident buffer and
    /// point msg_storage.iov at it. The copy is freed in discard/deinit.
    write_iovs_copy: ?[]std.posix.iovec = null,

    inline fn reset(self: *BlockingTask) *BlockingTasksSet {
        const pool_start = @intFromPtr(self) - @as(usize, self.index) * @sizeOf(BlockingTask);
        const set: *BlockingTasksSet = @ptrFromInt(
            pool_start - @offsetOf(BlockingTasksSet, "task_data_pool")
        );

        self.data = .none;
        self.operation = undefined;

        return set;
    }

    pub fn discard(self: *BlockingTask) void {
        // BUG-30: Free the heap-allocated iovec copy if it exists.
        const set = self.reset();
        if (self.write_iovs_copy) |iovs| {
            set.loop.allocator.free(iovs);
            self.write_iovs_copy = null;
        }
        set.loop.reserved_slots -= 1;
        set.pop(self);
    }

    pub fn deinit(self: *BlockingTask) void {
        // BUG-30: Free the heap-allocated iovec copy if it exists.
        const set = self.reset();
        if (self.write_iovs_copy) |iovs| {
            set.loop.allocator.free(iovs);
            self.write_iovs_copy = null;
        }
        set.pop(self);
    }

    pub fn check_result(self: *BlockingTask, result: std.os.linux.E) void {
        switch (self.operation) {
            .WaitTimer => {
                switch (result) {
                    .TIME => {},
                    .CANCELED => {},
                    .SUCCESS => {},
                    else => std.log.warn("WaitTimer: unexpected io_uring result {s}", .{@tagName(result)}),
                }
            },
            // BUG-64: Cancel operations are fire-and-forget by
            // design, but log unexpected result codes. -ENOENT
            // is expected (the task already completed), but other
            // errors may indicate a problem.
            .Cancel => switch (result) {
                .SUCCESS, .NOENT => {},
                else => std.log.warn("Cancel: unexpected result {s}", .{@tagName(result)}),
            },
            .CancelByFd => switch (result) {
                .SUCCESS, .NOENT => {},
                else => std.log.warn("CancelByFd: unexpected result {s}", .{@tagName(result)}),
            },
            .PerformWriteV, .PerformWrite, .PerformSendMsg => {
                switch (result) {
                    .SUCCESS => {},
                    .CANCELED, .BADF, .FBIG, .INTR, .IO, .NOSPC, .INVAL, .CONNRESET,
                    .PIPE, .NOBUFS, .NXIO, .ACCES, .NETDOWN, .NETUNREACH,
                    .SPIPE => {},
                    .AGAIN => {},
                    else => std.log.warn("PerformWriteV/Write/SendMsg: unexpected io_uring result {s}", .{@tagName(result)}),
                }
            },
            .PerformRead, .PerformRecvMsg => {
                switch (result) {
                    .SUCCESS => {},
                    .CANCELED, .BADF, .BADMSG, .INTR, .INVAL, .IO, .ISDIR,
                    .OVERFLOW, .SPIPE, .CONNRESET, .NOTCONN, .TIMEDOUT,
                    .NOBUFS, .NOMEM, .NXIO => {},
                    .AGAIN => {},
                    else => std.log.warn("PerformRead/RecvMsg: unexpected io_uring result {s}", .{@tagName(result)}),
                }
            },
            .SocketShutdown => {
                switch (result) {
                    .SUCCESS => {},
                    .CANCELED, .INVAL, .NOTCONN, .NOTSOCK, .BADF, .NOBUFS => {},
                    .AGAIN => {},
                    else => std.log.warn("SocketShutdown: unexpected io_uring result {s}", .{@tagName(result)}),
                }
            },
            .SocketConnect, .SocketAccept => {
                switch (result) {
                    .SUCCESS => {},
                    .ACCES, .PERM, .ADDRINUSE, .ADDRNOTAVAIL, .AFNOSUPPORT, .ALREADY,
                    .BADF, .CONNREFUSED, .FAULT, .INPROGRESS, .INTR, .ISCONN,
                    .NETUNREACH, .NOTSOCK, .PROTOTYPE, .TIMEDOUT => {},
                    .AGAIN => {},
                    else => std.log.warn("SocketConnect/Accept: unexpected io_uring result {s}", .{@tagName(result)}),
                }
            },
            else => {
                switch (result) {
                    .SUCCESS => {},
                    .CANCELED, .BADF, .INTR => {},
                    else => std.log.warn("Generic: unexpected io_uring result {s}", .{@tagName(result)}),
                }
            }
        }
    }
};

fn eventfd_callback(data: *const CallbackManager.CallbackData) !void {
    if (data.cancelled()) return;

    const io: *IO = @alignCast(@ptrCast(data.user_data.?));
    try io.register_eventfd_callback();
}

const BlockingTasksSetLinkedList = utils.LinkedList(BlockingTasksSet);

pub const BlockingTasksSet = struct {
    task_data_pool: [TotalTasksItems]BlockingTask = undefined,
    free_slots: [TotalTasksItems]u16 = undefined,
    free_count: u16 = 0,

    loop: *Loop = undefined,
    index: u16 = 0,
    active_tasks: u16 = 0,

    disattached: bool = false,

    list: *BlockingTasksSetLinkedList = undefined,
    node: BlockingTasksSetLinkedList.Node = undefined,

    pub fn init(self: *BlockingTasksSet, node: BlockingTasksSetLinkedList.Node, list: *BlockingTasksSetLinkedList, loop: *Loop) void {
        for (&self.task_data_pool, 0..) |*task, index| {
            task.* = .{
                .data = .none,
                .operation = undefined,
                .index = @intCast(index)
            };
        }

        self.index = 0;
        self.active_tasks = 0;
        self.free_count = 0;
        self.disattached = false;

        self.loop = loop;
        self.list = list;
        self.node = node;
    }

    pub fn deinit(self: *BlockingTasksSet) void { 
        if (self.disattached) {
            self.list.unlink_node(self.node) catch {};
        }

        self.list.release_node(self.node);
    }

    pub fn cancel_all(self: *BlockingTasksSet, loop: *Loop) !void {
        for (self.task_data_pool[0..self.index]) |*task| {
            switch (task.data) {
                .callback => |*data| {
                    data.data.set_cancelled(true);
                    try Loop.Scheduling.Soon.dispatch_guaranteed_nonthreadsafe(loop, data);
                },
                .none => {}
            }
        }
    }

    inline fn reset(self: *BlockingTasksSet) void {
        self.index = 0;
        self.active_tasks = 0;
        self.free_count = 0;
    }

    pub fn push(
        self: *BlockingTasksSet,
        operation: BlockingOperation,
        callback: ?*const CallbackManager.Callback
    ) !*BlockingTask {
        try self.loop.reserve_slots(1);

        var slot_idx: u16 = undefined;
        if (self.free_count > 0) {
            self.free_count -= 1;
            slot_idx = self.free_slots[self.free_count];
        } else {
            const index = self.index;
            if (index == TotalTasksItems) return error.Overflow;
            slot_idx = index;
            @atomicStore(u16, &self.index, index + 1, .release);
        }

        const data_slot = &self.task_data_pool[slot_idx];
        
        // GC Safety: Initialize data BEFORE incrementing active_tasks
        data_slot.data = if (callback) |v| .{ .callback = v.* } else .none;
        data_slot.operation = operation;
        
        self.active_tasks += 1;

        return data_slot;
    }

    pub inline fn pop(self: *BlockingTasksSet, task: *BlockingTask) void {
        const slot_idx = task.index;

        // Clear the slot's data
        task.data = .none;
        task.operation = undefined;
        task.write_iovs_copy = null;

        // Push the index back to free_slots
        self.free_slots[self.free_count] = slot_idx;
        self.free_count += 1;

        const active_tasks = self.active_tasks - 1;
        if (active_tasks == 0) {
            if (self.disattached) {
                self.deinit();
            } else {
                self.reset();
            }
            return;
        }

        self.active_tasks = active_tasks;
    }

    pub inline fn free(self: *BlockingTasksSet) bool {
        if (self.index == TotalTasksItems) {
            self.disattached = true;
            return false;
        }

        return true;
    }

    pub fn traverse(self: *const BlockingTasksSet, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
        const current_index = @atomicLoad(u16, &self.index, .acquire);
        for (self.task_data_pool[0..current_index]) |*task| {
            switch (task.data) {
                .callback => |*cb| {
                    if (cb.data.traverse()) |t| {
                        const vret = t(cb.data.user_data, @constCast(@ptrCast(visit)), arg);
                        if (vret != 0) return vret;
                    }

                    if (cb.data.module_ptr()) |mod| {
                        const vret1 = visit.?(@ptrCast(mod), arg);
                        if (vret1 != 0) return vret1;
                        if (cb.data.callback_ptr()) |cp| {
                            const vret2 = visit.?(@ptrCast(cp), arg);
                            if (vret2 != 0) return vret2;
                        }
                    }
                },
                .none => {}
            }
        }
        return 0;
    }
};

pub const WaitData = struct {
    callback: CallbackManager.Callback,
    fd: std.os.linux.fd_t,
    fixed_file_index: ?u16 = null,
    timeout: ?std.os.linux.kernel_timespec = null
};

pub const BlockingOperationData = union(BlockingOperation) {
    WaitReadable: WaitData,
    WaitWritable: WaitData,
    PerformRead: Read.PerformData,
    PerformWrite: Write.PerformData,
    PerformWriteV: Write.PerformVData,
    PerformRecvMsg: Read.RecvMsgData,
    PerformSendMsg: Write.SendMsgData,
    WaitTimer: Timer.WaitData,
    Cancel: usize,
    CancelByFd: usize,
    SocketShutdown: Socket.ShutdownData,
    SocketConnect: Socket.ConnectData,
    SocketAccept: Socket.AcceptData,
};

pub const RegisteredBufferPool = struct {
    pub const SlotSize = 65536; // 64KB
    pub const SlotCount = 16;   // 16 slots -> 1MB (fits under host MEMLOCK limits)

    pub const LeaseResult = struct {
        index: u16,
        slice: []u8,
    };

    buffer_memory: []u8 = &.{},
    iovecs: []std.posix.iovec = &.{},
    free_slots: []u16 = &.{},
    free_count: usize = 0,

    pub fn init(self: *RegisteredBufferPool, allocator: std.mem.Allocator) !void {
        self.buffer_memory = try allocator.alloc(u8, SlotSize * SlotCount);
        errdefer allocator.free(self.buffer_memory);
        @memset(self.buffer_memory, 0);

        self.iovecs = try allocator.alloc(std.posix.iovec, SlotCount);
        errdefer allocator.free(self.iovecs);

        self.free_slots = try allocator.alloc(u16, SlotCount);
        errdefer allocator.free(self.free_slots);

        for (0..SlotCount) |i| {
            self.iovecs[i] = .{
                .base = self.buffer_memory[i * SlotSize .. (i + 1) * SlotSize].ptr,
                .len = SlotSize,
            };
            self.free_slots[i] = @intCast(i);
        }
        self.free_count = SlotCount;
    }

    pub fn deinit(self: *RegisteredBufferPool, allocator: std.mem.Allocator) void {
        if (self.buffer_memory.len > 0) allocator.free(self.buffer_memory);
        if (self.iovecs.len > 0) allocator.free(self.iovecs);
        if (self.free_slots.len > 0) allocator.free(self.free_slots);
        self.* = .{};
    }

    pub fn lease(self: *RegisteredBufferPool) ?LeaseResult {
        if (self.free_slots.len == 0 or self.free_count == 0) return null;
        self.free_count -= 1;
        const index = self.free_slots[self.free_count];
        const offset = @as(usize, index) * SlotSize;
        return .{
            .index = index,
            .slice = self.buffer_memory[offset .. offset + SlotSize],
        };
    }

    pub fn release(self: *RegisteredBufferPool, index: u16) void {
        if (self.free_slots.len == 0) return;
        if (self.free_count >= SlotCount) return; // Overflow guard: prevent double-release
        self.free_slots[self.free_count] = index;
        self.free_count += 1;
    }
};

loop: *Loop = undefined,

busy_sets: BlockingTasksSetLinkedList = undefined,
set_node: BlockingTasksSetLinkedList.Node = undefined,
set: *BlockingTasksSet = undefined,

ring: std.os.linux.IoUring = undefined,
ring_blocked: u8 = 0,

eventfd: std.posix.fd_t = -1,
eventfd_val: u64 = 0,
blocking_ready_tasks: []std.os.linux.io_uring_cqe = &.{},

/// Fixed file table for IOSQE_FIXED_FILE optimization.
/// Registered as a sparse table via register_files_sparse at init.
/// Index 0 is reserved for eventfd. Transport sockets use 1..TotalTasksItems-1.
fixed_file_table: []std.posix.fd_t = &.{},
fixed_file_free: std.ArrayListUnmanaged(u16) = .{ .items = &.{}, .capacity = 0 },
fixed_files_enabled: bool = false,

buffer_pool: RegisteredBufferPool = .{},

pub fn init(self: *IO, loop: *Loop, allocator: std.mem.Allocator) !void {
    self.busy_sets = BlockingTasksSetLinkedList.init(allocator);

    self.set_node = try self.busy_sets.create_new_node(.{});
    self.set = &self.set_node.data;
    self.set.init(self.set_node, &self.busy_sets, loop);
    errdefer self.set.deinit();

    self.loop = loop;

    // Initialize the io_uring ring. To maximize performance and minimize scheduling
    // overhead/context switches, we attempt to configure the ring with:
    // 1. IORING_SETUP_COOP_TASKRUN (Linux >= 5.11): Avoids hardware interrupts by running
    //    completion task work cooperatively on the main thread during io_uring_enter.
    // 2. IORING_SETUP_SINGLE_ISSUER (Linux >= 6.0): Bypasses internal ring locks in the
    //    kernel since only the registering main thread issues and reaps events.
    // We implement a graceful runtime fallback chain for backward compatibility.
    const coop_flag = std.os.linux.IORING_SETUP_COOP_TASKRUN;
    const single_issuer_flag = std.os.linux.IORING_SETUP_SINGLE_ISSUER;

    self.ring = init_ring: {
        // Attempt: Coop Taskrun + Single Issuer (High performance, Linux 6.0+)
        if (std.os.linux.IoUring.init(TotalTasksItems, coop_flag | single_issuer_flag)) |r| {
            break :init_ring r;
        } else |err| {
            if (err == error.ArgumentsInvalid) {
                // Fallback 1: Coop Taskrun only (Linux 5.11+)
                if (std.os.linux.IoUring.init(TotalTasksItems, coop_flag)) |r| {
                    break :init_ring r;
                } else |err2| {
                    if (err2 == error.ArgumentsInvalid) {
                        // Fallback 2: Default scheduling flags (Linux 5.1+)
                        break :init_ring try std.os.linux.IoUring.init(TotalTasksItems, 0);
                    }
                    return err2;
                }
            }
            return err;
        }
    };
    errdefer self.ring.deinit();

    _ = std.os.linux.fcntl(self.ring.fd, std.posix.F.SETFD, @intCast(std.posix.FD_CLOEXEC));

    const eventfd_ret = std.os.linux.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
    if (@as(i32, @intCast(eventfd_ret)) < 0) return error.SystemResources;
    self.eventfd = @intCast(eventfd_ret);
    errdefer _ = std.os.linux.close(self.eventfd);

    self.blocking_ready_tasks = try allocator.alloc(std.os.linux.io_uring_cqe, TotalTasksItems);
    errdefer allocator.free(self.blocking_ready_tasks);

    @atomicStore(u8, &self.ring_blocked, 0, .seq_cst);

    // Initialize fixed file table for IOSQE_FIXED_FILE optimization.
    // Raise RLIMIT_NOFILE if needed — fixed file table needs TotalTasksItems slots.
    const nr_files: u32 = TotalTasksItems;
    var rlim: std.os.linux.rlimit = undefined;
    _ = std.os.linux.getrlimit(.NOFILE, &rlim);
    _ = std.os.linux.setrlimit(.NOFILE, &.{ .cur = nr_files + 64, .max = rlim.max });

    self.fixed_file_table = try allocator.alloc(std.posix.fd_t, nr_files);
    errdefer allocator.free(self.fixed_file_table);
    @memset(self.fixed_file_table[0..], -1);

    self.fixed_file_free = .{ .items = &.{}, .capacity = 0 };
    try self.fixed_file_free.ensureTotalCapacity(allocator, nr_files - 1);
    for (1..nr_files) |i| {
        self.fixed_file_free.appendAssumeCapacity(@intCast(i));
    }

    self.ring.register_files_sparse(nr_files) catch {
        // Kernel doesn't support sparse file registration — skip fixed files.
        // IO operations will use raw fds instead of fixed file indices.
        self.fixed_files_enabled = false;
        return;
    };
    errdefer self.ring.unregister_files() catch {};

    // Register eventfd at fixed file index 0
    self.fixed_file_table[0] = self.eventfd;
    try self.ring.register_files_update(0, self.fixed_file_table[0..1]);

    self.fixed_files_enabled = true;

    try self.buffer_pool.init(allocator);
    errdefer self.buffer_pool.deinit(allocator);

    self.ring.register_buffers(self.buffer_pool.iovecs) catch |err| {
        // Graceful fallback if buffer registration fails
        self.buffer_pool.deinit(allocator);
        std.debug.print("io_uring buffer registration failed: {}\n", .{err});
    };
}

pub fn register_fixed_file(self: *IO, fd: std.posix.fd_t) !u16 {
    const mutex = &self.loop.mutex;
    mutex.lock();
    defer mutex.unlock();

    if (!self.fixed_files_enabled) return error.FixedFilesDisabled;
    if (self.ring.fd < 0) return error.LoopDeinitialized;
    const index = self.fixed_file_free.pop() orelse return error.NoFixedFileSlots;
    // BUG-26: If register_files_update fails, the slot has been
    // popped from fixed_file_free but never re-pushed. The slot
    // would be permanently lost, leading to gradual exhaustion of
    // fixed file slots and eventually NoFixedFileSlots errors on
    // all new connections. Added an errdefer to re-push the slot
    // on failure.
    self.fixed_file_table[index] = fd;
    errdefer self.fixed_file_free.append(self.loop.allocator, index) catch {};
    try self.ring.register_files_update(index, self.fixed_file_table[index..index + 1]);
    return index;
}

pub fn unregister_fixed_file(self: *IO, index: u16) void {
    const mutex = &self.loop.mutex;
    mutex.lock();
    defer mutex.unlock();

    if (!self.fixed_files_enabled) return;
    self.fixed_file_table[index] = -1;
    if (self.ring.fd >= 0) {
        self.ring.register_files_update(index, self.fixed_file_table[index..index + 1]) catch {};
    }
    // BUG-27: If the append fails (OOM), the slot index is
    // permanently lost. Previously this was a silent `catch {}`.
    // Now we log the error so it's visible — the slot leak is
    // still going to happen, but at least the operator sees it.
    self.fixed_file_free.append(self.loop.allocator, index) catch |err| {
        std.log.err("unregister_fixed_file: failed to append slot {d} back to free list: {}", .{ index, err });
    };
}

pub fn lease_buffer(self: *IO) ?RegisteredBufferPool.LeaseResult {
    const mutex = &self.loop.mutex;
    mutex.lock();
    defer mutex.unlock();
    return self.buffer_pool.lease();
}

pub fn release_buffer(self: *IO, index: u16) void {
    const mutex = &self.loop.mutex;
    mutex.lock();
    defer mutex.unlock();
    self.buffer_pool.release(index);
}

pub fn register_eventfd_callback(self: *IO) !void {
    if (self.fixed_files_enabled) {
        _ = try self.queue(.{
            .PerformRead = .{
                .fd = 0,
                .fixed_file_index = 0,
                .callback = .{
                    .func = &eventfd_callback,
                    .cleanup = null,
                    .data = .{
                        .user_data = self,
                    }
                },
                .data = .{ .buffer = @as([*]u8, @ptrCast(&self.eventfd_val))[0..@sizeOf(u64)] },
            }
        });
    } else {
        _ = try self.queue(.{
            .PerformRead = .{
                .fd = self.eventfd,
                .fixed_file_index = null,
                .callback = .{
                    .func = &eventfd_callback,
                    .cleanup = null,
                    .data = .{
                        .user_data = self,
                    }
                },
                .data = .{ .buffer = @as([*]u8, @ptrCast(&self.eventfd_val))[0..@sizeOf(u64)] },
            }
        });
    }
}

pub fn wakeup_eventfd(self: *IO) !void {
    const val: u64 = 1;
    while (true) {
        const ret = std.os.linux.write(self.eventfd, @as([*]const u8, @ptrCast(&val)), @sizeOf(u64));
        if (ret >= 0) return;
        switch (std.os.errno(ret)) {
            .INTR => continue,
            else => return,
        }
    }
}

pub fn traverse(self: *const IO, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
    const vret1 = self.set.traverse(visit, arg);
    if (vret1 != 0) return vret1;

    var node: ?BlockingTasksSetLinkedList.Node = self.busy_sets.first;
    while (node) |n| {
        node = n.next;
        const vret2 = n.data.traverse(visit, arg);
        if (vret2 != 0) return vret2;
    }
    return 0;
}

pub fn deinit(self: *IO) void {
    self.set.cancel_all(self.loop) catch {};
    self.set.deinit();
    var node: ?BlockingTasksSetLinkedList.Node = self.busy_sets.first;
    while (node) |n| {
        node = n.next;

        const set = &n.data;
        set.cancel_all(self.loop) catch {};
        set.deinit();
    }
    
    self.ring.unregister_buffers() catch {};
    self.buffer_pool.deinit(self.busy_sets.allocator);

    self.ring.deinit();
    self.busy_sets.allocator.free(self.blocking_ready_tasks);
    self.fixed_file_free.deinit(self.busy_sets.allocator);
    self.busy_sets.allocator.free(self.fixed_file_table);
    _ = std.os.linux.close(self.eventfd);
}

pub fn get_blocking_tasks_set(self: *IO) !*BlockingTasksSet {
    const set = self.set;
    if (set.free()) {
        return set;
    }

    // BUG-28: The errdefer `set.disattached = false` is critical
    // for correctness on OOM. When `set.free()` returned false
    // above, it set `set.disattached = true` to mark the OLD set
    // for deinit when its tasks complete. If OOM occurs in
    // create_new_node (the only thing that can fail here), we must
    // roll back that flag — otherwise the OLD set's node would be
    // freed by deinit() while `self.set_node` still points to it,
    // leaving a dangling pointer.
    //
    // The errdefer is scoped BEFORE the create_new_node call so it
    // only runs if the allocation fails. If the allocation succeeds,
    // we proceed to move the OLD set to busy_sets; from that point
    // on, the OLD set's disattached=true state is correct and must
    // not be rolled back.
    errdefer set.disattached = false;

    const new_node = try self.busy_sets.create_new_node(.{});
    errdefer self.busy_sets.release_node(new_node);

    const new_set = &new_node.data;
    new_set.init(new_node, &self.busy_sets, self.loop);

    self.busy_sets.append_node(self.set_node);

    self.set_node = new_node;
    self.set = new_set;

    return new_set;
}

pub fn flush_pending_sqes(self: *IO) !u32 {
    const ready = self.ring.sq_ready();
    if (ready == 0) return 0;
    return try submit_guaranteed(&self.ring);
}

pub fn queue_unlocked(self: *IO, event: BlockingOperationData) !usize {
    if (self.ring.fd < 0) return error.LoopDeinitialized;

    const set = try self.get_blocking_tasks_set();

    if (event == .Cancel or event == .CancelByFd) {
        _ = try self.flush_pending_sqes();
    }

    const data_ptr = try switch (event) {
        .WaitReadable => |data| Read.wait_ready(&self.ring, set, data),
        .WaitWritable => |data| Write.wait_ready(&self.ring, set, data),
        .PerformRead => |data| Read.perform(&self.ring, set, data),
        .PerformWrite => |data| Write.perform(&self.ring, set, data),
        .PerformWriteV => |data| Write.perform_with_iovecs(&self.ring, set, data),
        .PerformRecvMsg => |data| Read.recvmsg(&self.ring, set, data),
        .PerformSendMsg => |data| Write.sendmsg(&self.ring, set, data),
        .WaitTimer => |data| Timer.wait(&self.ring, set, data),
        .SocketShutdown => |data| Socket.shutdown(&self.ring, set, data),
        .Cancel => |data| Cancel.perform(&self.ring, data),
        .CancelByFd => |fd| Cancel.perform_by_fd(&self.ring, fd),
        .SocketConnect => |data| Socket.connect(&self.ring, set, data),
        .SocketAccept => |data| Socket.accept(&self.ring, set, data)
    };

    if (event == .Cancel or event == .CancelByFd or (event != .Cancel and event != .CancelByFd and self.ring.sq_ready() >= TotalTasksItems - 2)) {
        _ = try self.flush_pending_sqes();
    }

    if (@atomicLoad(u8, &self.ring_blocked, .seq_cst) != 0) {
        try self.wakeup_eventfd();
    }

    return data_ptr;
}

pub fn queue(self: *IO, event: BlockingOperationData) !usize {
    const mutex = &self.loop.mutex;
    mutex.lock();
    defer mutex.unlock();

    return try self.queue_unlocked(event);
}

pub fn submit_guaranteed(ring: *std.os.linux.IoUring) !u32 {
    while (true) {
        const submitted = ring.submit() catch |err| {
            if (err == error.SignalInterrupt) continue;
            return err;
        };
        return submitted;
    }
}

const IO = @This();
