const std = @import("std");
const builtin = @import("builtin");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const PyEval_SaveThread = python_c.PyEval_SaveThread;
const PyEval_RestoreThread = python_c.PyEval_RestoreThread;

const utils = @import("utils");
const lock = @import("../utils/lock.zig");

const CallbackManager = @import("callback_manager");
const Loop = @import("main.zig");
const Future = @import("../future/main.zig");
const Completion = @import("completion.zig");
const ReadTransport = @import("../transports/read_transport.zig");
const Stream = @import("../transports/stream/main.zig");

fn slow_callback_warning_handler(duration: f64, module_ptr: ?*python_c.PyObject, data: ?*anyopaque) void {
    const loop_obj: *Loop.Python.LoopObject = @alignCast(@ptrCast(data.?));
    const loop_data = utils.get_data_ptr(Loop, loop_obj);

    const msg = std.fmt.allocPrint(loop_data.allocator, "Executing callback took {d:.6} seconds\x00", .{duration}) catch return;
    defer loop_data.allocator.free(msg);

    const context_dict = python_c.PyDict_New() orelse return;
    defer python_c.py_decref(context_dict);

    const py_msg = python_c.PyUnicode_FromString(msg.ptr) orelse return;
    defer python_c.py_decref(py_msg);
    _ = python_c.PyDict_SetItemString(context_dict, "message\x00", py_msg);

    if (module_ptr) |mod| {
        _ = python_c.PyDict_SetItemString(context_dict, "module\x00", mod);
    }

    const ret = python_c.PyObject_CallMethod(@ptrCast(loop_obj), "call_exception_handler\x00", "O\x00", context_dict) orelse {
        if (python_c.PyErr_Occurred()) |exc| {
            if (python_c.PyErr_GivenExceptionMatches(exc, python_c.PyExc_KeyboardInterrupt.?) != 0 or
                python_c.PyErr_GivenExceptionMatches(exc, python_c.PyExc_SystemExit.?) != 0) {
                return;
            }
        }
        python_c.PyErr_Clear();
        return;
    };
    python_c.py_decref(ret);
}

fn exception_handler(err: anyerror, data: ?*anyopaque, module_ptr: ?*python_c.PyObject, callback_ptr: ?PyObject) !void {
    const loop_obj: *Loop.Python.LoopObject = @alignCast(@ptrCast(data.?));
    
    const context_dict = python_c.PyDict_New() orelse return error.PythonError;
    defer python_c.py_decref(context_dict);

    _ = python_c.PyDict_SetItemString(context_dict, "message\x00", python_c.PyUnicode_FromString("Exception in callback\x00") orelse return error.PythonError);

    if (module_ptr) |mod| {
        _ = python_c.PyDict_SetItemString(context_dict, "module\x00", mod);
    }
    if (callback_ptr) |cp| {
        _ = python_c.PyDict_SetItemString(context_dict, "callback\x00", cp);
    }

    const py_err_name = @errorName(err);
    const py_err_obj = python_c.PyUnicode_FromString(py_err_name.ptr) orelse return error.PythonError;
    defer python_c.py_decref(py_err_obj);
    _ = python_c.PyDict_SetItemString(context_dict, "exception\x00", py_err_obj);

    const ret = python_c.PyObject_CallMethod(@ptrCast(loop_obj), "call_exception_handler\x00", "O\x00", context_dict) orelse {
        if (python_c.PyErr_Occurred()) |exc| {
            if (python_c.PyErr_GivenExceptionMatches(exc, python_c.PyExc_KeyboardInterrupt.?) != 0 or
                python_c.PyErr_GivenExceptionMatches(exc, python_c.PyExc_SystemExit.?) != 0) {
                return error.PythonError;
            }
        }
        python_c.PyErr_Clear();
        return;
    };
    python_c.py_decref(ret);
}

pub inline fn call_once(
    ready_queue: *CallbackManager.DynamicRingBuffer,
    _: usize,
    loop_obj: *Loop.Python.LoopObject
) !usize {
    const debug_state = CallbackManager.DebugState{ .slow_callback_duration = loop_obj.slow_callback_duration };

    const callbacks_executed = try CallbackManager.execute_dynamic_ring_buffer(
        ready_queue,
        if (builtin.is_test) null else &exception_handler,
        loop_obj,
        if (loop_obj.debug) &slow_callback_warning_handler else null,
        if (loop_obj.debug) &debug_state else null
    );
    if (callbacks_executed == 0) {
        ready_queue.reset();
    }

    return callbacks_executed;
}

fn dispatch_completion_batch(
    self: *Loop,
    loop_obj: *Loop.Python.LoopObject,
) !void {
    _ = loop_obj;
    const batch = &self.completion_batch;
    if (batch.is_empty()) return;

    const records = batch.records[0..batch.ready_count];
    var had_error = false;

    for (records) |*record| {
        const transport: *Stream.StreamTransportObject = @alignCast(@ptrCast(record.stream_transport orelse continue));

        // BUG-32: Verify the transport hasn't been closed between push and dispatch.
        // If `dispatch_generation` was bumped (e.g., `transport_close` or
        // `transport_force_close` ran via a hook, ready queue, or future code path),
        // the captured record is stale and must be skipped to prevent use-after-free.
        const live_generation = @atomicLoad(u64, &transport.dispatch_generation, .acquire);
        if (live_generation != record.transport_generation) continue;

        switch (record.op) {
            .DataReceived => {
                const ptr: [*]u8 = @ptrCast(record.buffer_ptr orelse continue);
                const py_bytes = python_c.PyBytes_FromStringAndSize(ptr, @intCast(record.nbytes)) orelse {
                    had_error = true;
                    continue;
                };
                defer python_c.py_decref(py_bytes);
                if (python_c.PyObject_CallOneArg(transport.protocol_data_received.?, py_bytes) == null) {
                    had_error = true;
                    continue;
                }
            },
            .BufferUpdated => {
                const nbytes_obj = python_c.PyLong_FromUnsignedLongLong(@intCast(record.nbytes)) orelse {
                    had_error = true;
                    continue;
                };
                defer python_c.py_decref(nbytes_obj);
                if (python_c.PyObject_CallOneArg(transport.protocol_buffer_updated.?, nbytes_obj) == null) {
                    had_error = true;
                    continue;
                }
            },
            else => {},
        }
    }

    batch.reset();

    if (had_error) {
        return error.PythonError;
    }
}

fn execute_hooks(hooks: *Loop.HooksList) !void {
    var node = hooks.first;
    while (node) |n| {
        node = n.next;
        n.data.func(&n.data.data) catch continue;
    }
}

fn fetch_completed_tasks(
    self: *Loop,
    blocking_ready_tasks: []std.os.linux.io_uring_cqe,
    ready_queue: *CallbackManager.DynamicRingBuffer
) !void {
    for (blocking_ready_tasks) |cqe| {
        const user_data = cqe.user_data;
        if (user_data == 0) continue; // Timeout and cancel operations

        const err: std.os.linux.E = @call(.always_inline, std.os.linux.io_uring_cqe.err, .{cqe});
        const blocking_task: *Loop.Scheduling.IO.BlockingTask = @ptrFromInt(user_data);

        switch (blocking_task.data) {
            .callback => |*v| {
                v.data.set_io(cqe.res, err);

                // P15 Phase 2: Batch read transport completions
                // Uses raw Zig pointers (no PyObject*), so GC never touches the batch.
                // Dispatch creates PyBytes on the fly from the raw buffer pointer.
                if (v.func == &ReadTransport.read_operation_completed and err == .SUCCESS and cqe.res > 0) {
                    const read_transport: *ReadTransport = @alignCast(@ptrCast(v.data.user_data.?));
                    const bytes_read: usize = @intCast(cqe.res);

                    const stream_transport: *Stream.StreamTransportObject = @ptrCast(read_transport.parent_transport);
                    _ = stream_transport.protocol orelse continue;

                    const record: Completion.CompletionRecord = .{
                        .op = switch (stream_transport.protocol_type) {
                            .Buffered => .BufferUpdated,
                            .Legacy => .DataReceived,
                        },
                        .stream_transport = @ptrCast(stream_transport),
                        .buffer_ptr = switch (stream_transport.protocol_type) {
                            .Buffered => null,
                            .Legacy => @ptrCast(read_transport.buffer_to_read.ptr),
                        },
                        .nbytes = @as(i64, @intCast(bytes_read)),
                        .transport_generation = @atomicLoad(u64, &stream_transport.dispatch_generation, .acquire),
                    };

                    if (self.completion_batch.push(record)) {
                        v.data.set_batch_dispatched(true);
                        read_transport.batch_dispatched = true;
                    }
                    // Push failure = batch full, fall through to normal callback.
                    // No cleanup needed: no PyObject refs were created.
                }

                blocking_task.check_result(err);
                if (!ready_queue.try_push(v.*)) return error.Overflow;
            },
            .none => {}
        }

        self.reserved_slots -= 1;
        blocking_task.deinit();
    }
}

fn poll_blocking_events(
    self: *Loop,
    mutex: *lock.Mutex,
    wait: bool,
    ready_queue: *CallbackManager.DynamicRingBuffer
) !void {
    const blocking_ready_tasks = self.io.blocking_ready_tasks;

    // If nothing is in-flight, there's nothing to wait for.
    var should_wait = wait;
    if (should_wait and self.reserved_slots == 0) {
        should_wait = false;
    }

    var nevents: u32 = undefined;
    while (true) {
        if (should_wait and ready_queue.is_empty()) {
            std.debug.print("DEBUG BLOCKING: slots={}, set_idx={}, set_active={}, busy_sets={}\n", .{
                self.reserved_slots,
                self.io.set.index,
                self.io.set.active_tasks,
                self.io.busy_sets.len
            });
            for (self.io.set.task_data_pool[0..self.io.set.index]) |*task| {
                if (task.data != .none) {
                    std.debug.print("  - Active Set Task slot {}: op={}\n", .{task.index, task.operation});
                }
            }
            var busy_node = self.io.busy_sets.first;
            while (busy_node) |node| {
                const bset = &node.data;
                std.debug.print("  Busy Set: idx={}, active={}\n", .{bset.index, bset.active_tasks});
                for (bset.task_data_pool[0..bset.index]) |*task| {
                    if (task.data != .none) {
                        std.debug.print("    - Busy Set Task slot {}: op={}\n", .{task.index, task.operation});
                    }
                }
                busy_node = node.next;
            }
            @atomicStore(u8, &self.io.ring_blocked, 1, .seq_cst);
            mutex.unlock();
            defer {
                mutex.lock();
                @atomicStore(u8, &self.io.ring_blocked, 0, .seq_cst);
            }

            const py_thread_state = PyEval_SaveThread();
            const res = self.io.ring.submit_and_wait(1);
            PyEval_RestoreThread(py_thread_state);

            _ = res catch |err| {
                if (err == error.SignalInterrupt) {
                    if (python_c.PyErr_CheckSignals() < 0) return error.PythonError;
                    if (python_c.PyErr_Occurred() != null) return error.PythonError;
                    continue;
                }
                return err;
            };
            nevents = try copy_cqes_eintr_safe(&self.io.ring, blocking_ready_tasks);
        } else {
            // Non-blocking: flush pending SQEs, then peek at CQEs.
            _ = try self.io.flush_pending_sqes();
            nevents = try copy_cqes_eintr_safe(&self.io.ring, blocking_ready_tasks);
        }
        break;
    }

    while (nevents > 0) {
        try fetch_completed_tasks(self, blocking_ready_tasks[0..nevents], ready_queue);

        if (nevents == blocking_ready_tasks.len) {
            nevents = try copy_cqes_eintr_safe(&self.io.ring, blocking_ready_tasks);
        } else {
            break;
        }
    }
}

fn copy_cqes_eintr_safe(ring: *std.os.linux.IoUring, cqes: []std.os.linux.io_uring_cqe) !u32 {
    while (true) {
        return ring.copy_cqes(cqes, 0) catch |err| {
            if (err == error.SignalInterrupt) {
                if (python_c.PyErr_CheckSignals() < 0) return error.PythonError;
                if (python_c.PyErr_Occurred() != null) return error.PythonError;
                continue;
            }
            return err;
        };
    }
}

pub fn start(self: *Loop, loop_obj: *Loop.Python.LoopObject) !void {
    const mutex = &self.mutex;
    mutex.lock();
    defer mutex.unlock();

    if (!self.initialized) {
        python_c.raise_python_runtime_error("Loop is closed\x00");
        return error.PythonError;
    }

    if (self.stopping) {
        python_c.raise_python_runtime_error("Loop is stopping\x00");
        return error.PythonError;
    }

    if (self.running) {
        python_c.raise_python_runtime_error("Loop is already running\x00");
        return error.PythonError;
    }

    self.running = true;
    defer {
        self.running = false;
        self.stopping = false;
    }

    const ready_tasks_queue_max_capacity = self.ready_tasks_queue_max_capacity;

    var ready_tasks_queue_index = self.ready_tasks_queue_index;
    var wait_for_blocking_events: bool = false;
    while (!self.stopping) {
        if (loop_obj.owner_pid != std.os.linux.getpid()) break;

        const old_index = ready_tasks_queue_index;
        const ready_tasks_queue = &self.ready_tasks_queues[old_index];

        try poll_blocking_events(self, mutex, wait_for_blocking_events, ready_tasks_queue);

        ready_tasks_queue_index = 1 - ready_tasks_queue_index;
        self.ready_tasks_queue_index = ready_tasks_queue_index;

        mutex.unlock();
        defer mutex.lock();

        // P15 Phase 2: Dispatch IO completion batch after releasing mutex.
        // Protocol methods may call loop.call_soon() which needs the mutex.
        try dispatch_completion_batch(self, loop_obj);

        if (self.check_hooks.len != 0) try execute_hooks(&self.check_hooks);

        const callbacks_executed = try call_once(
            ready_tasks_queue,
            ready_tasks_queue_max_capacity,
            loop_obj
        );

        if (self.idle_hooks.len != 0) try execute_hooks(&self.idle_hooks);
        if (self.prepare_hooks.len != 0) try execute_hooks(&self.prepare_hooks);
        wait_for_blocking_events = (callbacks_executed == 0 and self.idle_hooks.len == 0);
    }
}
