// Re-export aggregator. Implementation lives in ops/*.zig.
pub const loop_sock_accept = @import("ops/accept.zig").loop_sock_accept;
pub const loop_sock_connect = @import("ops/connect.zig").loop_sock_connect;
pub const loop_sock_recv = @import("ops/recv.zig").loop_sock_recv;
pub const loop_sock_sendall = @import("ops/sendall.zig").loop_sock_sendall;
pub const loop_sock_recvfrom = @import("ops/recvfrom.zig").loop_sock_recvfrom;
pub const loop_sock_sendto = @import("ops/sendto.zig").loop_sock_sendto;
pub const loop_sock_recv_into = @import("ops/recv_into.zig").loop_sock_recv_into;
