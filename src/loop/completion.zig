const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

/// Lightweight record for IO completions. Replaces the 48-byte Callback
/// for transport operations. Python reads these in a batch and dispatches
/// protocol methods directly, eliminating per-completion Zig→Python crossings.
pub const CompletionOp = enum(u8) {
    DataReceived,       // protocol.data_received(bytes)
    EofReceived,        // protocol.eof_received()
    BufferUpdated,      // protocol.buffer_updated(nbytes)
    ConnectionMade,     // protocol.connection_made(transport)
    ConnectionLost,     // protocol.connection_lost(exc)
    ResumeWriting,      // protocol.resume_writing()
    DatagramReceived,   // protocol.datagram_received(data, addr)
    ErrorReceived,      // protocol.error_received(exc)
};

/// Single completion record — 32 bytes (vs 48-byte Callback).
/// No function pointers: Python switches on `op` to call the right method.
pub const CompletionRecord = extern struct {
    op: CompletionOp,
    transport: ?PyObject,     // StreamTransportObject (for read ops) or DatagramTransportObject
    data: ?PyObject,          // PyBytes for data_received, PyException for errors, null for EOF
    nbytes: i64,               // bytes received (for buffered protocol), or error code
};

/// Fixed-size batch buffer shared between Zig and Python.
/// Zig writes records, Python reads and dispatches.
pub const CompletionBatch = struct {
    const MaxRecords = 4096;

    records: [MaxRecords]CompletionRecord = undefined,
    ready_count: usize = 0,

    pub inline fn is_empty(self: *const CompletionBatch) bool {
        return self.ready_count == 0;
    }

    pub inline fn is_full(self: *const CompletionBatch) bool {
        return self.ready_count == MaxRecords;
    }

    pub inline fn push(self: *CompletionBatch, record: CompletionRecord) bool {
        if (self.ready_count == MaxRecords) return false;
        const idx = self.ready_count;
        self.records[idx] = record;
        self.ready_count += 1;
        return true;
    }

    pub fn reset(self: *CompletionBatch) void {
        self.ready_count = 0;
    }

    /// GC traversal: visit all PyObject pointers in the batch.
    pub fn traverse(self: *const CompletionBatch, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
        var i: usize = 0;
        while (i < self.ready_count) : (i += 1) {
            const rec = &self.records[i];
            if (rec.transport) |t| {
                const vret = visit.?(t, arg);
                if (vret != 0) return vret;
            }
            if (rec.data) |d| {
                const vret = visit.?(d, arg);
                if (vret != 0) return vret;
            }
        }
        return 0;
    }
};
