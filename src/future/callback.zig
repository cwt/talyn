const std = @import("std");

const CallbackManager = @import("callback_manager");
const Loop = @import("../loop/main.zig");
const Future = @import("main.zig");

const utils = @import("utils");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const ExceptionMessage: [:0]const u8 = "An error ocurred while executing future callbacks";
const ModuleName: [:0]const u8 = "future";

// pub const Data = struct {
//     py_future: PyObject,
//     py_callback: PyObject,
//     py_context: PyObject,
//     exception_handler: PyObject,
//     can_execute: bool = true,
//     dec_future: bool = false
// };

const PythonGenericData = struct {
    // BUG-370: optional so that a removed callback can detach its
    // references at removal time instead of holding them until Future
    // teardown. A detached entry always has cancelled == true.
    callback: ?PyObject,
    context: ?PyObject,
};

const ZigGenericData = struct { callback: *const fn (?*Future.Python.FutureObject, ?*anyopaque) anyerror!void, ptr: ?*anyopaque };

pub const Data = union(enum) {
    PythonGeneric: PythonGenericData,
    ZigGeneric: ZigGenericData,
};

pub const Callback = struct { data: Data, cancelled: bool = false, executed: bool = false };

/// BUG-414: small-buffer-optimized queue for the Future's per-callback
/// bookkeeping. The common case is exactly one done-callback (talyn tasks
/// step through `py_wake_up`) and zero exceptions; keeping both inline
/// removes the per-Future glibc/pymalloc arena churn that produced the
/// ~3x task-churn footprint high-water. Falls back to a heap ArrayList
/// beyond the inline capacity, with identical semantics.
pub fn InlineQueue(comptime T: type, comptime N: usize) type {
    return struct {
        const Self = @This();

        pub const Heap = std.ArrayList(T);

        inline_buf: [N]T = undefined,
        inline_len: usize = 0,
        heap: Heap = .empty,

        pub inline fn items(self: *const Self) []const T {
            return if (self.heap.items.len > 0)
                self.heap.items
            else
                self.inline_buf[0..self.inline_len];
        }

        pub inline fn itemsMut(self: *Self) []T {
            return if (self.heap.items.len > 0)
                self.heap.items
            else
                self.inline_buf[0..self.inline_len];
        }

        pub fn append(self: *Self, alloc: std.mem.Allocator, value: T) !void {
            if (self.heap.items.len > 0) {
                try self.heap.append(alloc, value);
                return;
            }
            if (self.inline_len < N) {
                self.inline_buf[self.inline_len] = value;
                self.inline_len += 1;
                return;
            }
            // promote the inline buffer to the heap, then append
            var heap: Heap = .empty;
            errdefer heap.deinit(alloc);
            try heap.ensureTotalCapacity(alloc, N + 1);
            heap.appendSliceAssumeCapacity(self.inline_buf[0..self.inline_len]);
            heap.appendAssumeCapacity(value);
            self.heap = heap;
        }

        pub fn pop(self: *Self) T {
            const items_mut = self.itemsMut();
            const value = items_mut[items_mut.len - 1];
            if (self.heap.items.len > 0) {
                self.heap.items.len -= 1;
            } else {
                self.inline_len -= 1;
            }
            return value;
        }

        pub const empty = Self{};

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.heap.deinit(alloc);
            self.heap = .empty;
            self.inline_len = 0;
        }
    };
}

pub const CallbacksSetData = InlineQueue(Callback, 2);
pub const ExceptionsQueueData = InlineQueue(?*python_c.PyObject, 1);

fn release_python_future_data(data: ?*anyopaque) void {
    const future: *Future = @ptrCast(@alignCast(data.?));
    const py_future = utils.get_parent_ptr(Future.Python.FutureObject, future);
    python_c.py_decref(@ptrCast(py_future));
}

fn traverse_python_future_data(ptr: ?*anyopaque, visit_ptr: ?*anyopaque, arg: ?*anyopaque) c_int {
    const future: *Future = @ptrCast(@alignCast(ptr.?));
    const py_future = utils.get_parent_ptr(Future.Python.FutureObject, future);
    const visit: python_c.visitproc = @ptrCast(@alignCast(visit_ptr.?));
    return visit.?(@ptrCast(py_future), arg);
}

fn execute_python_callback(context: PyObject, callback: PyObject, future: PyObject) !void {
    defer {
        python_c.py_decref(context);
        python_c.py_decref(callback);
    }

    if (python_c.PyContext_Enter(context) < 0) {
        return error.PythonError;
    }
    defer _ = python_c.PyContext_Exit(context);

    const result: ?PyObject = python_c.PyObject_CallOneArg(callback, future);

    if (result) |v| {
        python_c.py_decref(v);
    } else {
        return error.PythonError;
    }
}

fn run_python_future_set_callbacks(data: *const CallbackManager.CallbackData) !void {
    const future: *Future = @ptrCast(@alignCast(data.user_data.?));
    const py_future = utils.get_parent_ptr(Future.Python.FutureObject, future);

    if (data.cancelled()) {
        release_callbacks_queue(&future.callbacks_queue);
        python_c.py_decref(@ptrCast(py_future));
        return;
    }

    var callbacks_items = future.callbacks_queue.itemsMut();
    var exceptions_array = &future.exceptions_queue;
    errdefer {
        for (exceptions_array.itemsMut()) |*exc| {
            python_c.py_xdecref(exc.*);
            exc.* = null;
        }
        while (exceptions_array.itemsMut().len > 0) _ = exceptions_array.pop();
    }

    var ci: usize = 0;
    while (ci < callbacks_items.len) : (ci += 1) {
        const callback = &callbacks_items[ci];
        if (callback.cancelled or callback.executed) continue;
        callback.executed = true;

        switch (callback.data) {
            .PythonGeneric => |py_data| {
                // Detached (removed) entries carry no references — the
                // cancelled skip above already covers them; the guard
                // keeps the invariant explicit for Mandate #4.
                if (py_data.callback == null or py_data.context == null) continue;
                execute_python_callback(py_data.context.?, py_data.callback.?, @ptrCast(py_future)) catch |err| {
                    utils.handle_zig_function_error(err, {});

                    const exc = python_c.PyErr_GetRaisedException() orelse return error.PythonError;
                    exceptions_array.append(future.loop.allocator, exc) catch |err2| {
                        std.log.err("Failed to queue exception from Python callback: {s}", .{@errorName(err2)});
                        python_c.py_decref(exc);
                    };
                };
            },
            .ZigGeneric => |z_data| {
                z_data.callback(py_future, z_data.ptr) catch |err| {
                    utils.handle_zig_function_error(err, {});

                    const exc = python_c.PyErr_GetRaisedException() orelse return error.PythonError;
                    exceptions_array.append(future.loop.allocator, exc) catch |err2| {
                        std.log.err("Failed to queue exception from Zig callback: {s}", .{@errorName(err2)});
                        python_c.py_decref(exc);
                    };
                };
            },
        }
    }

    const exceptions_len = exceptions_array.items().len;
    if (exceptions_len > 0) {
        const exc_tuple = python_c.PyTuple_New(@intCast(exceptions_len)) orelse return error.PythonError;
        defer python_c.py_decref(exc_tuple);

        for (0.., exceptions_array.itemsMut()) |i, *exc| {
            if (python_c.PyTuple_SetItem(exc_tuple, @intCast(i), exc.*) < 0) {
                return error.PythonError;
            }

            exc.* = null;
        }

        const exception_message = python_c.PyUnicode_FromString("Multiple exceptions occurred while executing future callbacks\x00") orelse return error.PythonError;
        defer python_c.py_decref(exception_message);

        var args: [2]PyObject = undefined;
        args[0] = exception_message;
        args[1] = exc_tuple;

        const exc = python_c.PyObject_Vectorcall(python_c.PyExc_BaseExceptionGroup, &args, 2, null) orelse return error.PythonError;
        python_c.PyErr_SetRaisedException(exc);

        return error.PythonError;
    }

    python_c.py_decref(@ptrCast(py_future));
}

pub fn traverse_callbacks_queue(queue: *const CallbacksSetData, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
    for (queue.items()) |callback| {
        if (callback.executed or callback.cancelled) continue;
        switch (callback.data) {
            .PythonGeneric => |data| {
                const vret1 = visit.?(@ptrCast(data.callback), arg);
                if (vret1 != 0) return vret1;
                const vret2 = visit.?(@ptrCast(data.context), arg);
                if (vret2 != 0) return vret2;
            },
            .ZigGeneric => |data| {
                // data.ptr is always a PythonTaskObject (Task) in Talyn.
                // Traverse it so GC can see Task -> Future -> Task cycles.
                if (data.ptr) |ptr| {
                    const vret = visit.?(@ptrCast(@alignCast(ptr)), arg);
                    if (vret != 0) return vret;
                }
            },
        }
    }
    return 0;
}

pub fn release_callbacks_queue(queue: *CallbacksSetData) void {
    for (queue.itemsMut()) |*callback| {
        if (callback.executed) continue;
        callback.executed = true;
        switch (callback.data) {
            .PythonGeneric => |data| {
                // BUG-370: the fields are optional now — a removed
                // (detached) entry has no references left; plain
                // py_decref would dereference them.
                python_c.py_xdecref(data.callback);
                python_c.py_xdecref(data.context);
            },
            .ZigGeneric => |data| {
                data.callback(null, data.ptr) catch |err| {
                    std.log.err("Error while releasing future callback: {s}", .{@errorName(err)});
                };
            },
        }
    }
}

pub inline fn add_done_callback(self: *Future, callback_data: Data) !void {
    if (self.status != .pending or self.released) return;

    try self.callbacks_queue.append(self.loop.allocator, .{
        .data = callback_data,
    });
    errdefer _ = self.callbacks_queue.pop();

    // BUG-414: the exceptions_queue used to be eagerly grown to the
    // callbacks count here. Its appends in run_python_future_set_callbacks
    // are already lazy (only when a callback actually raises), so most
    // Futures never write a single entry — the eager chunk allocated
    // ~32 B of never-reused native arena per task-spawn and is why RSS grew
    // linearly on the task lifecycle. Appends grow the queue on demand
    // instead; every consumer iterates values, none index positionally.
}

/// BUG-370: Python callbacks are compared by PyObject equality (Py_EQ),
/// not pointer identity — attribute lookups re-wrap bound methods into
/// NEW method objects, so identity never matched and removal silently
/// returned 0 (breaking run_until_complete's own
/// `remove_done_callback(self.__run_until_complete_cb)`). Matched
/// entries are marked cancelled and their callback/context references
/// are detached + decref'd immediately instead of lingering until
/// Future teardown. Python exceptions from custom `__eq__` propagate.
pub fn remove_done_callback(self: *Future, py_callback: PyObject) !usize {
    if (self.status != .pending or self.released) return 0;

    var removed_count: usize = 0;
    var i: usize = 0;
    while (i < self.callbacks_queue.items().len) : (i += 1) {
        if (self.status != .pending or self.released) break;
        const entry = self.callbacks_queue.items()[i];
        if (entry.cancelled or entry.executed) continue;
        switch (entry.data) {
            .ZigGeneric => {},
            .PythonGeneric => |value| {
                const candidate = value.callback orelse continue;
                python_c.py_incref(candidate);
                defer python_c.py_decref(candidate);
                const equal = python_c._c.PyObject_RichCompareBool(
                    candidate,
                    py_callback,
                    python_c._c.Py_EQ,
                );
                if (equal < 0) {
                    return error.PythonError;
                }
                if (equal == 1) {
                    if (self.released or i >= self.callbacks_queue.items().len) break;
                    const slot = &self.callbacks_queue.itemsMut()[i];
                    if (slot.cancelled or slot.executed) continue;
                    switch (slot.data) {
                        .ZigGeneric => {},
                        .PythonGeneric => |*mut_val| {
                            const callback_obj = mut_val.callback;
                            const context_obj = mut_val.context;
                            mut_val.callback = null;
                            mut_val.context = null;
                            slot.cancelled = true;
                            python_c.py_xdecref(callback_obj);
                            python_c.py_xdecref(context_obj);
                            removed_count += 1;
                        },
                    }
                }
            },
        }
    }

    return removed_count;
}

pub fn call_done_callbacks(self: *Future, new_status: Future.FutureStatus) !void {
    if (self.status != .pending) return;

    self.status = new_status;

    if (self.callbacks_queue.items().len == 0) {
        self.loop.reserved_slots -= 1;
        return;
    }

    if (!self.loop.initialized) {
        self.loop.reserved_slots -= 1;
        release_callbacks_queue(&self.callbacks_queue);
        python_c.raise_python_runtime_error("Event loop is closed\x00");
        return error.PythonError;
    }

    self.python_payload = .{
        .module_ptr = null,
        .callback_ptr = null,
        .traverse = &traverse_python_future_data,
    };
    const pyfut = utils.get_parent_ptr(Future.Python.FutureObject, self);
    const callback = CallbackManager.Callback{
        .func = &run_python_future_set_callbacks,
        .cleanup = &release_python_future_data,
        .data = CallbackManager.CallbackData.init_python(self, &self.python_payload),
    };

    try Loop.Scheduling.Soon.dispatch_guaranteed(self.loop, &callback);
    python_c.py_incref(@ptrCast(pyfut));
}
