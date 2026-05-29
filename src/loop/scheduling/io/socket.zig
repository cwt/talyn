const std = @import("std");

const CallbackManager = @import("callback_manager");
const IO = @import("main.zig");

pub const ConnectData = struct {
    callback: CallbackManager.Callback,
    addr: *const std.posix.sockaddr,
    len: std.posix.socklen_t,
    socket_fd: std.posix.fd_t
};

pub const ShutdownData = struct {
    socket_fd: std.posix.fd_t,
    how: u32
};

pub const AcceptData = struct {
    callback: CallbackManager.Callback,
    socket_fd: std.posix.fd_t,
    addr: ?*std.posix.sockaddr,
    addrlen: ?*std.posix.socklen_t,
    flags: u32 = std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
};

pub fn connect(ring: *std.os.linux.IoUring, set: *IO.BlockingTasksSet, data: ConnectData) !usize {
    const data_ptr = try set.push(.SocketConnect, &data.callback);
    errdefer data_ptr.discard();

    const sqe = try ring.connect(
        @intCast(@intFromPtr(data_ptr)), data.socket_fd, data.addr, data.len
    );
    sqe.flags |= std.os.linux.IOSQE_ASYNC;

    // IOSQE_ASYNC required: io_uring's inline connect returns -EINPROGRESS
    // for non-blocking sockets without properly installing a poll callback.
    // The workqueue handles the TCP handshake synchronously.
    // Deferred: ring.connect stores a pointer to data.addr which points to
    // heap-allocated SockConnectData — safe until completion.
    return @intFromPtr(data_ptr);
}

pub fn accept(ring: *std.os.linux.IoUring, set: *IO.BlockingTasksSet, data: AcceptData) !usize {
    const data_ptr = try set.push(.SocketAccept, &data.callback);
    errdefer data_ptr.discard();

    const sqe = try ring.accept(@intCast(@intFromPtr(data_ptr)), data.socket_fd, data.addr, data.addrlen, data.flags);
    sqe.flags |= std.os.linux.IOSQE_ASYNC;

    // IOSQE_ASYNC required: io_uring's inline accept may not properly handle
    // the non-blocking case without workqueue offloading.
    // Deferred: ring.accept stores pointers to data.addr/data.addrlen which
    // point to heap-allocated SockAcceptData — safe until completion.
    return @intFromPtr(data_ptr);
}

pub fn shutdown(ring: *std.os.linux.IoUring, set: *IO.BlockingTasksSet, data: ShutdownData) !usize {
    const data_ptr = try set.push(.SocketShutdown, null);
    errdefer data_ptr.discard();

    const sqe = try ring.shutdown(@intCast(@intFromPtr(data_ptr)), data.socket_fd, data.how);
    sqe.flags |= std.os.linux.IOSQE_ASYNC;

    // IOSQE_ASYNC: shutdown is a cold path, workqueue overhead is negligible.
    // No pointer args — safe to defer. Flushed by poll_blocking_events().
    return @intFromPtr(data_ptr);
}
