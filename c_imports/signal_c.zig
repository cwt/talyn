pub const SIG_DFL: i32 = 0;
pub const SIG_IGN: i32 = 1;

pub const SigHandler = *const fn (i32) callconv(.c) void;

fn default_signal_handler(_: i32) callconv(.c) void {}

pub extern "c" fn signal(sig: i32, handler: SigHandler) callconv(.c) SigHandler;
pub extern "c" fn siginterrupt(sig: i32, flag: i32) i32;

pub const default_handler: SigHandler = &default_signal_handler;
