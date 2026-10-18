const std = @import("std");

pub const Stream = @import("stream/main.zig");
pub const StreamServer = @import("streamserver/main.zig");
pub const Datagram = @import("datagram/main.zig");
pub const Subprocess = @import("subprocess/transport.zig");

// Force analysis of each transport module so their `test` blocks are
// collected by `zig build test` (unreferenced `pub const` imports are
// lazily skipped by test discovery).
test {
    _ = Stream;
    _ = StreamServer;
    _ = Datagram;
    _ = Subprocess;
}

test "transports collection check" {
    try std.testing.expect(true);
}
