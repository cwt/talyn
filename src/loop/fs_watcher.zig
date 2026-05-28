const std = @import("std");
const Loop = @import("main.zig");
const CallbackManager = @import("callback_manager");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const utils = @import("utils");

const FSWatcher = @This();

loop: *Loop = undefined,
inotify_fd: std.posix.fd_t = -1,
inotify_task_id: usize = 0,
watchers: std.ArrayListUnmanaged(*Watcher) = .{ .items = &.{}, .capacity = 0 },

pub const Watcher = struct {
    callback: PyObject,
    mask: u32,
    wd: i32,
};

pub fn init(self: *FSWatcher, loop: *Loop) !void {
    self.loop = loop;
    self.watchers = .{ .items = &.{}, .capacity = 0 };
    self.inotify_fd = -1;
    self.inotify_task_id = 0;
}

pub fn deinit(self: *FSWatcher) void {
    if (self.inotify_fd >= 0) {
        _ = std.os.linux.close(self.inotify_fd);
        self.inotify_fd = -1;
    }
    self.inotify_task_id = 0;
    
    for (self.watchers.items) |watcher| {
        python_c.py_decref(watcher.callback);
        self.loop.allocator.destroy(watcher);
    }
    self.watchers.deinit(self.loop.allocator);
}

fn ensure_inotify(self: *FSWatcher) !void {
    if (self.inotify_fd >= 0) return;
    
    const ret = std.os.linux.inotify_init1(std.os.linux.IN.NONBLOCK | std.os.linux.IN.CLOEXEC);
    if (@as(i32, @intCast(ret)) < 0) return error.SystemResources;
    const fd: std.posix.fd_t = @intCast(ret);
    errdefer _ = std.os.linux.close(fd);
    
    self.inotify_task_id = try self.loop.io.queue(.{
        .WaitReadable = .{
            .fd = fd,
            .callback = .{
                .func = &on_inotify_event,
                .cleanup = null,
                .data = .{ .user_data = self },
            },
        }
    });
    
    self.inotify_fd = fd;
}

fn on_inotify_event(data: *const CallbackManager.CallbackData) !void {
    const self: *FSWatcher = @alignCast(@ptrCast(data.user_data.?));
    
    if (data.cancelled() or self.inotify_fd < 0) {
        return;
    }

    var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
    while (true) {
        const n = std.posix.read(self.inotify_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (n == 0) break;
        
        var pos: usize = 0;
        while (pos < n) {
            const event: *const std.os.linux.inotify_event = @ptrCast(@alignCast(&buf[pos]));
            const name = if (event.len > 0) std.mem.sliceTo(buf[pos + @sizeOf(std.os.linux.inotify_event) .. pos + @sizeOf(std.os.linux.inotify_event) + event.len], 0) else "";
            
            for (self.watchers.items) |watcher| {
                if (watcher.wd == event.wd and (watcher.mask & event.mask) != 0) {
                    try self.dispatch_event(watcher, event.mask, event.cookie, name);
                }
            }
            
            pos += @sizeOf(std.os.linux.inotify_event) + event.len;
        }
    }

    // Re-arm
    self.inotify_task_id = try self.loop.io.queue(.{
        .WaitReadable = .{
            .fd = self.inotify_fd,
            .callback = .{
                .func = &on_inotify_event,
                .cleanup = null,
                .data = .{ .user_data = self },
            },
        }
    });
}

fn dispatch_event(self: *FSWatcher, watcher: *Watcher, mask: u32, cookie: u32, name: []const u8) !void {
    const py_mask = python_c.PyLong_FromUnsignedLong(mask) orelse return error.PythonError;
    defer python_c.py_decref(py_mask);
    const py_cookie = python_c.PyLong_FromUnsignedLong(cookie) orelse return error.PythonError;
    defer python_c.py_decref(py_cookie);
    const py_name = python_c.PyUnicode_FromStringAndSize(name.ptr, @intCast(name.len)) orelse return error.PythonError;
    defer python_c.py_decref(py_name);
    
    const args = python_c.PyTuple_Pack(3, py_mask, py_cookie, py_name) orelse return error.PythonError;
    defer python_c.py_decref(args);
    
    const res = python_c.PyObject_Call(watcher.callback, args, null) orelse {
        const exc = python_c.PyErr_GetRaisedException() orelse return;
        defer python_c.py_decref(exc);
        const loop_obj = utils.get_parent_ptr(Loop.Python.LoopObject, self.loop);
        const ctx = python_c.PyDict_New() orelse return;
        defer python_c.py_decref(ctx);
        _ = python_c.PyDict_SetItemString(ctx, "message\x00", python_c.PyUnicode_FromString("Exception in inotify callback\x00") orelse return);
        _ = python_c.PyDict_SetItemString(ctx, "exception\x00", exc);
        const ret = python_c.PyObject_CallMethod(@ptrCast(loop_obj), "call_exception_handler\x00", "O\x00", ctx) orelse {
            python_c.PyErr_Clear();
            return;
        };
        python_c.py_decref(ret);
        return;
    };
    python_c.py_decref(res);
}

pub fn add_watch(self: *FSWatcher, path: [:0]const u8, mask: u32, callback: PyObject) !i32 {
    try self.ensure_inotify();
    
    const wd_ret = std.os.linux.inotify_add_watch(self.inotify_fd, path, mask);
    if (@as(i32, @intCast(wd_ret)) < 0) return error.SystemResources;
    const wd: i32 = @intCast(wd_ret);
    
    const watcher = try self.loop.allocator.create(Watcher);
    errdefer self.loop.allocator.destroy(watcher);
    watcher.* = .{
        .callback = python_c.py_newref(callback),
        .mask = mask,
        .wd = wd,
    };
    
    try self.watchers.append(self.loop.allocator, watcher);
    return wd;
}

pub fn remove_watch(self: *FSWatcher, wd: i32, callback: PyObject) void {
    var i: usize = 0;
    while (i < self.watchers.items.len) {
        const watcher = self.watchers.items[i];
        if (watcher.wd == wd and watcher.callback == callback) {
            python_c.py_decref(watcher.callback);
            self.loop.allocator.destroy(watcher);
            _ = self.watchers.swapRemove(i);
            
            // Check if any watchers remain for this WD
            var found = false;
            for (self.watchers.items) |other| {
                if (other.wd == wd) {
                    found = true;
                    break;
                }
            }
            
            if (!found) {
                _ = std.os.linux.inotify_rm_watch(self.inotify_fd, wd);
            }
            return;
        } else {
            i += 1;
        }
    }
}

pub fn traverse(self: *const FSWatcher, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
    for (self.watchers.items) |watcher| {
        const vret = visit.?(@ptrCast(watcher.callback), arg);
        if (vret != 0) return vret;
    }
    return 0;
}
