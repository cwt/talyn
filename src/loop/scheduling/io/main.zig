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

pub const TotalTasksItems = switch (builtin.mode) {
    .Debug => 8192,
    .ReleaseSmall => 1024,
    else => 8192
};

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

    inline fn reset(self: *BlockingTask) *BlockingTasksSet {
        const set: *BlockingTasksSet = @ptrFromInt(
            @intFromPtr(self) - @as(usize, self.index) * @sizeOf(BlockingTask)
        );

        self.data = .none;
        self.operation = undefined;

        return set;
    }

    pub fn discard(self: *BlockingTask) void {
        const set = self.reset();
        set.pop();
    }
    
    pub fn deinit(self: *BlockingTask) void {
        const set = self.reset();
        set.inc_finished_tasks_counter();
    }

    pub fn check_result(self: *BlockingTask, result: std.os.linux.E) void {
        switch (self.operation) {
            .WaitTimer => {
                switch (result) {
                    .TIME => {},
                    .CANCELED => {},
                    .SUCCESS => {},
                    else => {}
                }
            },
            .Cancel => {},
            .PerformWriteV, .PerformWrite, .PerformSendMsg => {
                switch (result) {
                    .SUCCESS => {},
                    .CANCELED, .BADF, .FBIG, .INTR, .IO, .NOSPC, .INVAL, .CONNRESET,
                    .PIPE, .NOBUFS, .NXIO, .ACCES, .NETDOWN, .NETUNREACH,
                    .SPIPE => {},
                    .AGAIN => {},
                    else => {}
                }
            },
            .PerformRead, .PerformRecvMsg => {
                switch (result) {
                    .SUCCESS => {},
                    .CANCELED, .BADF, .BADMSG, .INTR, .INVAL, .IO, .ISDIR,
                    .OVERFLOW, .SPIPE, .CONNRESET, .NOTCONN, .TIMEDOUT,
                    .NOBUFS, .NOMEM, .NXIO => {},
                    .AGAIN => {},
                    else => {}
                }
            },
            .SocketShutdown => {
                switch (result) {
                    .SUCCESS => {},
                    .CANCELED, .INVAL, .NOTCONN, .NOTSOCK, .BADF, .NOBUFS => {},
                    .AGAIN => {},
                    else => {}
                }
            },
            .SocketConnect, .SocketAccept => {
                switch (result) {
                    .SUCCESS => {},
                    .ACCES, .PERM, .ADDRINUSE, .ADDRNOTAVAIL, .AFNOSUPPORT, .ALREADY,
                    .BADF, .CONNREFUSED, .FAULT, .INPROGRESS, .INTR, .ISCONN,
                    .NETUNREACH, .NOTSOCK, .PROTOTYPE, .TIMEDOUT => {},
                    .AGAIN => {},
                    else => {}
                }
            },
            else => {
                switch (result) {
                    .SUCCESS => {},
                    .CANCELED, .BADF, .INTR => {},
                    else => {}
                }
            }
        }
    }
};

fn eventfd_callback(data: *const CallbackManager.CallbackData) !void {
    if (data.cancelled) return;

    const io: *IO = @alignCast(@ptrCast(data.user_data.?));
    try io.register_eventfd_callback();
}

const BlockingTasksSetLinkedList = utils.LinkedList(BlockingTasksSet);

pub const BlockingTasksSet = struct {
    task_data_pool: [TotalTasksItems]BlockingTask,

    loop: *Loop,
    index: u16,
    finished_tasks: u16,

    disattached: bool,

    list: *BlockingTasksSetLinkedList,

    pub fn init(self: *BlockingTasksSet, list: *BlockingTasksSetLinkedList, loop: *Loop) void {
        for (&self.task_data_pool, 0..) |*task, index| {
            task.* = .{
                .data = .none,
                .operation = undefined,
                .index = @intCast(index)
            };
        }

        self.index = 0;
        self.finished_tasks = 0;
        self.disattached = false;

        self.loop = loop;
        self.list = list;
    }

    pub fn deinit(self: *BlockingTasksSet) void { 
        const node: BlockingTasksSetLinkedList.Node = @ptrFromInt(
            @intFromPtr(self) - @offsetOf(BlockingTasksSetLinkedList._linked_list_node, "data")
        );

        if (self.disattached) {
            self.list.unlink_node(node) catch {};
        }

        self.list.release_node(node);
    }

    pub fn cancel_all(self: *BlockingTasksSet, loop: *Loop) !void {
        for (self.task_data_pool[0..self.index]) |*task| {
            switch (task.data) {
                .callback => |*data| {
                    data.data.cancelled = true;
                    try Loop.Scheduling.Soon.dispatch_guaranteed_nonthreadsafe(loop, data);
                },
                .none => {}
            }
        }
    }

    inline fn reset(self: *BlockingTasksSet) void {
        self.index = 0;
        self.finished_tasks = 0;
    }

    pub fn push(
        self: *BlockingTasksSet,
        operation: BlockingOperation,
        callback: ?*const CallbackManager.Callback
    ) !*BlockingTask {
        const index = self.index;
        if (index == TotalTasksItems) return error.Overflow;

        try self.loop.reserve_slots(1);

        const data_slot = &self.task_data_pool[index];
        
        // GC Safety: Initialize data BEFORE incrementing index
        data_slot.data = if (callback) |v| .{ .callback = v.* } else .none;
        data_slot.operation = operation;
        
        @atomicStore(u16, &self.index, index + 1, .release);

        return data_slot;
    }

    pub inline fn pop(self: *BlockingTasksSet) void {
        self.index -= 1;
        self.loop.reserved_slots -= 1;
    }

    pub inline fn inc_finished_tasks_counter(self: *BlockingTasksSet) void {
        const finished_tasks = self.finished_tasks + 1;
        if (finished_tasks == TotalTasksItems and self.disattached) {
            self.deinit();
            return;
        }

        if (finished_tasks == self.index) {
            self.reset();
            return;
        }

        self.finished_tasks = finished_tasks;
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
                    if (cb.data.traverse) |t| {
                        const vret = t(cb.data.user_data, @constCast(@ptrCast(visit)), arg);
                        if (vret != 0) return vret;
                    }

                    if (cb.data.module_ptr) |mod| {
                        const vret1 = visit.?(@ptrCast(mod), arg);
                        if (vret1 != 0) return vret1;
                        if (cb.data.callback_ptr) |cp| {
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
    SocketShutdown: Socket.ShutdownData,
    SocketConnect: Socket.ConnectData,
    SocketAccept: Socket.AcceptData,
};

pub const RegisteredBufferPool = struct {
    pub const SlotSize = 65536; // 64KB
    pub const SlotCount = 64;   // 64 slots -> 4MB (fits under host MEMLOCK limits)

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
        self.free_slots[self.free_count] = index;
        self.free_count += 1;
    }
};

loop: *Loop = undefined,

busy_sets: BlockingTasksSetLinkedList = undefined,
set_node: BlockingTasksSetLinkedList.Node = undefined,
set: *BlockingTasksSet = undefined,

ring: std.os.linux.IoUring = undefined,
ring_blocked: bool = false,

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

    self.set_node = try self.busy_sets.create_new_node(undefined);
    self.set = &self.set_node.data;
    self.set.init(&self.busy_sets, loop);
    errdefer self.set.deinit();

    self.loop = loop;

    self.ring = try std.os.linux.IoUring.init(
        TotalTasksItems,
        0,
    );
    errdefer self.ring.deinit();

    _ = std.os.linux.fcntl(self.ring.fd, std.posix.F.SETFD, @intCast(std.posix.FD_CLOEXEC));

    const eventfd_ret = std.os.linux.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
    if (@as(i32, @intCast(eventfd_ret)) < 0) return error.SystemResources;
    self.eventfd = @intCast(eventfd_ret);
    errdefer _ = std.os.linux.close(self.eventfd);

    self.blocking_ready_tasks = try allocator.alloc(std.os.linux.io_uring_cqe, TotalTasksItems);
    errdefer allocator.free(self.blocking_ready_tasks);

    self.ring_blocked = false;

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
    self.fixed_file_table[index] = fd;
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
    self.fixed_file_free.append(self.loop.allocator, index) catch {};
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
                        .module_ptr = null,
                        .callback_ptr = null,
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
                        .module_ptr = null,
                        .callback_ptr = null,
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
    errdefer set.disattached = false;

    const new_node = try self.busy_sets.create_new_node(undefined);
    errdefer self.busy_sets.release_node(new_node);

    const new_set = &new_node.data;
    new_set.init(&self.busy_sets, self.loop);

    self.busy_sets.append_node(self.set_node);

    self.set_node = new_node;
    self.set = new_set;

    return new_set;
}

pub fn flush_pending_sqes(self: *IO) !u32 {
    return try submit_guaranteed(&self.ring);
}

pub fn queue(self: *IO, event: BlockingOperationData) !usize {
    const set = try self.get_blocking_tasks_set();

    if (event == .Cancel) {
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
        .SocketConnect => |data| Socket.connect(&self.ring, set, data),
        .SocketAccept => |data| Socket.accept(&self.ring, set, data)
    };

    if (event != .Cancel and self.ring.sq_ready() >= TotalTasksItems - 2) {
        _ = try self.flush_pending_sqes();
    }

    return data_ptr;
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
