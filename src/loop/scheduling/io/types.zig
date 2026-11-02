const std = @import("std");

const CallbackManager = @import("callback_manager");
const Read = @import("read.zig");
const Write = @import("write.zig");
const Timer = @import("timer.zig");
const Socket = @import("socket.zig");

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
    CancelIO,
    CancelTimer,
    CancelByFd,
    SocketShutdown,
    SocketConnect,
    SocketAccept,
};

pub const BlockingTaskData = union(enum) {
    callback: CallbackManager.Callback,
    none,
};

pub const WaitData = struct { callback: CallbackManager.Callback, fd: std.os.linux.fd_t, fixed_file_index: ?u16 = null, timeout: ?std.os.linux.kernel_timespec = null };

pub const BlockingOperationData = union(BlockingOperation) {
    WaitReadable: WaitData,
    WaitWritable: WaitData,
    PerformRead: Read.PerformData,
    PerformWrite: Write.PerformData,
    PerformWriteV: Write.PerformVData,
    PerformRecvMsg: Read.RecvMsgData,
    PerformSendMsg: Write.SendMsgData,
    WaitTimer: Timer.WaitData,
    CancelIO: usize,
    CancelTimer: usize,
    CancelByFd: usize,
    SocketShutdown: Socket.ShutdownData,
    SocketConnect: Socket.ConnectData,
    SocketAccept: Socket.AcceptData,
};

pub const RegisteredBufferPool = struct {
    pub const SlotSize = 65536; // 64KB
    pub const SlotCount = 16; // 16 slots -> 1MB (fits under host MEMLOCK limits)

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
        // Bounds guard: a valid index only ever originates from lease(), which
        // returns 0..SlotCount-1. Anything else (e.g. a corrupted or stale index)
        // must not be written into free_slots, which has exactly SlotCount entries.
        if (index >= SlotCount) return;
        if (self.free_count >= SlotCount) return; // Overflow guard: prevent double-release
        self.free_slots[self.free_count] = index;
        self.free_count += 1;
    }
};

test "RegisteredBufferPool lease/release/deinit guards (BUG-117 basis)" {
    const allocator = std.testing.allocator;
    var pool: RegisteredBufferPool = .{};
    try pool.init(allocator);
    defer pool.deinit(allocator);

    // Lease every slot.
    var leased: [RegisteredBufferPool.SlotCount]RegisteredBufferPool.LeaseResult = undefined;
    for (&leased) |*slot| {
        const result = pool.lease();
        try std.testing.expect(result != null);
        slot.* = result.?;
    }
    // Pool exhausted -> lease returns null (never dereferences freed memory).
    try std.testing.expectEqual(@as(?RegisteredBufferPool.LeaseResult, null), pool.lease());

    // Release one slot and lease it back; indices must be unique and in range.
    pool.release(leased[0].index);
    const reclaimed = pool.lease();
    try std.testing.expect(reclaimed != null);
    try std.testing.expectEqual(leased[0].index, reclaimed.?.index);
    pool.release(reclaimed.?.index);

    // Release the rest back.
    for (leased[1..]) |*slot| {
        pool.release(slot.*.index);
    }
    try std.testing.expectEqual(RegisteredBufferPool.SlotCount, pool.free_count);

    // Releasing an already-free index is a safe no-op (overflow guard).
    pool.release(leased[0].index);
    try std.testing.expectEqual(RegisteredBufferPool.SlotCount, pool.free_count);

    // After deinit the pool is empty and both lease/release are safe no-ops.
    pool.deinit(allocator);
    try std.testing.expectEqual(@as(?RegisteredBufferPool.LeaseResult, null), pool.lease());
    pool.release(0);
}
