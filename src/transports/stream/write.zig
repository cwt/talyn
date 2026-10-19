const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const Stream = @import("main.zig");
const StreamTransportObject = Stream.StreamTransportObject;

const WriteTransport = @import("../write_transport.zig");

const Lifecyle = @import("lifecycle.zig");

pub fn write_operation_completed(write_transport: *WriteTransport, data_written: usize, remaining_data: usize, err: std.os.linux.E) !void {
    const instance: *StreamTransportObject = @ptrCast(write_transport.parent_transport);
    defer Lifecyle.maybe_close_fd(instance);

    if (err != .SUCCESS or data_written == 0) {
        return;
    }

    if (instance.is_closing or instance.closed) {
        return;
    }

    if (!instance.is_writing) {
        if (remaining_data <= instance.writing_low_water_mark) {
            instance.is_writing = true;

            if (instance.protocol_resume_writing) |cb| {
                const ret = python_c.PyObject_CallNoArgs(cb) orelse return error.PythonError;
                python_c.py_decref(ret);
            }
        }
    }
}

pub fn transport_can_write_eof(_: ?*StreamTransportObject) callconv(.c) ?PyObject {
    return python_c.get_py_true();
}

pub fn transport_write_eof(self: ?*StreamTransportObject) callconv(.c) ?PyObject {
    const instance = self.?;

    const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", instance);
    // BUG-379: with a buffered write_eof() still draining, a repeated
    // write_eof() is a silent no-op (stdlib _eof == True semantics)
    // instead of raising "Transport is closed".
    if (write_transport.is_closing and !write_transport.eof_pending) {
        python_c.raise_python_runtime_error("Transport is closed\x00");
        return null;
    }

    write_transport.queue_eof() catch |err| {
        return utils.handle_zig_function_error(err, null);
    };

    return python_c.get_py_none();
}

pub fn transport_get_write_buffer_size(self: ?*StreamTransportObject) callconv(.c) ?PyObject {
    const instance = self.?;

    const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", instance);
    return python_c.PyLong_FromUnsignedLongLong(@intCast(write_transport.buffer_size));
}

pub fn transport_get_write_buffer_limits(self: ?*StreamTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;

    const low_water_mark = python_c.PyLong_FromUnsignedLongLong(@intCast(instance.writing_low_water_mark)) orelse return null;
    defer python_c.py_decref(low_water_mark);

    const high_water_mark = python_c.PyLong_FromUnsignedLongLong(@intCast(instance.writing_high_water_mark)) orelse return null;
    defer python_c.py_decref(high_water_mark);

    return python_c.PyTuple_Pack(2, low_water_mark, high_water_mark);
}

inline fn z_transport_set_write_buffer_limits(self: *StreamTransportObject, args: []?PyObject, knames: ?PyObject) !PyObject {
    if (args.len > 2) {
        python_c.raise_python_value_error("set_write_buffer_limits() takes at most 2 arguments\x00");
        return error.PythonError;
    }

    // BUG-379: merge positionals + kwargs through the CPython-faithful
    // helper: duplicate positional/kwarg passing raises TypeError like
    // CPython and the values stay BORROWED, fixing the positional-ref
    // leak the old py_newref + overwrite dance had (a keyword overwriting
    // a positional ref, and any parse failure dropping both).
    var merged: [2]?PyObject = undefined;
    try python_c.merge_vector_call_args(args, knames, &.{ "high\x00", "low\x00" }, &merged);

    // BUG-379: None means "not specified" (stdlib signature
    // set_write_buffer_limits(high=None, low=None)); the old code passed
    // Py_None to PyLong_AsUnsignedLongLong and raised TypeError.
    var high: ?i64 = null;
    var low: ?i64 = null;

    if (merged[0]) |obj| {
        if (!python_c.is_none(obj)) {
            const value = python_c.PyLong_AsLongLong(obj);
            if (python_c.PyErr_Occurred() != null) return error.PythonError;
            high = value;
        }
    }

    if (merged[1]) |obj| {
        if (!python_c.is_none(obj)) {
            const value = python_c.PyLong_AsLongLong(obj);
            if (python_c.PyErr_Occurred() != null) return error.PythonError;
            low = value;
        }
    }

    // stdlib defaults (Lib/asyncio/transports.py
    // `_set_write_buffer_limits`): both unspecified -> high = 64 KiB,
    // then low = high // 4; only low given -> high = 4 * low. The old
    // code defaulted low to a plain 32 KiB and clamped it into range
    // instead of validating.
    if (high == null) {
        high = if (low) |l| ((l *| 4)) else 64 * 1024;
    }
    if (low == null) {
        low = @divTrunc(high.?, 4);
    }

    if (!(high.? >= low.? and low.? >= 0)) {
        const msg = python_c.PyUnicode_FromFormat(
            "high (%zd) must be >= low (%zd) must be >= 0\x00",
            high.?,
            low.?,
        );
        if (msg) |m| {
            defer python_c.py_decref(m);
            python_c.PyErr_SetObject(python_c.PyExc_ValueError, m);
            return error.PythonError;
        }
        python_c.raise_python_value_error("high must be >= low and low must be >= 0\x00");
        return error.PythonError;
    }

    self.writing_high_water_mark = @intCast(high.?);
    self.writing_low_water_mark = @intCast(low.?);

    // BUG-379: re-evaluate flow control against the new limits, like
    // stdlib's set_write_buffer_limits() -> _maybe_pause_protocol() (plus
    // the mirrored resume when the new low-water admits the buffered
    // size). Both pauses and resumes are mutually exclusive because
    // validation guarantees low <= high.
    const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", self);

    if (self.is_writing and write_transport.buffer_size > self.writing_high_water_mark) {
        self.is_writing = false;
        if (self.protocol_pause_writing) |cb| {
            const ret = python_c.PyObject_CallNoArgs(cb) orelse return error.PythonError;
            python_c.py_decref(ret);
        }
    }

    if (!self.is_writing and write_transport.buffer_size <= self.writing_low_water_mark) {
        self.is_writing = true;
        if (self.protocol_resume_writing) |cb| {
            const ret = python_c.PyObject_CallNoArgs(cb) orelse return error.PythonError;
            python_c.py_decref(ret);
        }
    }

    return python_c.get_py_none();
}

pub fn transport_set_write_buffer_limits(self: ?*StreamTransportObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject) callconv(.c) ?PyObject {
    return utils.execute_zig_function(z_transport_set_write_buffer_limits, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames });
}

pub fn transport_write(self: ?*StreamTransportObject, py_buffer: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;

    const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", instance);
    // BUG-379: writes stay valid while a buffered write_eof() has not
    // flushed yet (stdlib only forbids them once the FIN actually went
    // out); the old gate also silently dropped these writes when the
    // buffered EOF marked the transport as closing.
    if (write_transport.is_closing and !write_transport.eof_pending) {
        return python_c.get_py_none();
    }

    const new_buffer_size = write_transport.append_new_buffer_to_write(py_buffer.?) catch |err| {
        return utils.handle_zig_function_error(err, null);
    };

    if (new_buffer_size > instance.writing_high_water_mark) {
        if (instance.is_writing) {
            instance.is_writing = false;

            if (instance.protocol_pause_writing) |cb| {
                const ret = python_c.PyObject_CallNoArgs(cb) orelse return null;
                python_c.py_decref(ret);
            }
        }
    }

    return python_c.get_py_none();
}

pub fn transport_write_lines(self: ?*StreamTransportObject, py_buffers: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;

    const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", instance);
    // BUG-379: same gate as transport_write — writes stay valid while a
    // buffered write_eof() is still pending.
    if (write_transport.is_closing and !write_transport.eof_pending) {
        return python_c.get_py_none();
    }

    const iter: PyObject = python_c.PyObject_GetIter(py_buffers.?) orelse return null;
    defer python_c.py_decref(iter);

    var new_buffer_size: usize = 0;
    while (true) {
        const py_buffer: PyObject = python_c.PyIter_Next(iter) orelse break;
        defer python_c.py_decref(py_buffer);

        new_buffer_size = write_transport.append_new_buffer_to_write(py_buffer) catch |err| {
            return utils.handle_zig_function_error(err, null);
        };
    }

    // BUG-377 (BUG-298 revisited): PyIter_Next returns null BOTH for a
    // finished iterator AND for a raising one. When the generator raised,
    // returning Py_None here would leave the exception live on the thread
    // state (SystemError at the call boundary in debug builds; silent
    // exception corruption in release builds).
    if (python_c.PyErr_Occurred() != null) {
        return null;
    }

    if (new_buffer_size > instance.writing_high_water_mark) {
        if (instance.is_writing) {
            instance.is_writing = false;

            if (instance.protocol_pause_writing) |cb| {
                const ret = python_c.PyObject_CallNoArgs(cb) orelse return null;
                python_c.py_decref(ret);
            }
        }
    }

    return python_c.get_py_none();
}
