const std = @import("std");
const builtin = @import("builtin");

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn tryLock(m: *SpinMutex) bool {
        return m.inner.tryLock();
    }

    pub fn lock(m: *SpinMutex) void {
        var spin: usize = 0;
        while (!m.inner.tryLock()) {
            spin += 1;
            if (spin < 10) {
                std.atomic.spinLoopHint();
            } else if (spin < 20) {
                var i: usize = 0;
                while (i < 10) : (i += 1) {
                    std.atomic.spinLoopHint();
                }
            } else {
                std.Thread.yield() catch {};
                spin = 0;
            }
        }
    }

    pub fn unlock(m: *SpinMutex) void {
        m.inner.unlock();
    }
};

const DummyLock = struct {
    pub fn tryLock(_: *DummyLock) bool {
        return true;
    }

    pub fn lock(_: *DummyLock) void {}
    pub fn unlock(_: *DummyLock) void {}
};

pub const Mutex = if (builtin.single_threaded) DummyLock else SpinMutex;

pub inline fn init() Mutex {
    return .{};
}
