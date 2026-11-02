const types = @import("resolv/types.zig");
const queue_mod = @import("resolv/queue.zig");

pub const ControlData = types.ControlData;
pub const DnsTimeout = types.DnsTimeout;
pub const parse_dns_timeout = types.parse_dns_timeout;
pub const timeout_from_secs = types.timeout_from_secs;
pub const timeout_to_secs = types.timeout_to_secs;
pub const dns_timeout_to_kernel_timespec = types.dns_timeout_to_kernel_timespec;
pub const queue = queue_mod.queue;
