const std = @import("std");

/// Lightweight record for IO completions. Replaces the 48-byte Callback
/// for transport operations. No PyObject pointers — raw Zig pointers only,
/// so GC does NOT need to traverse the batch. Python objects are created
/// during dispatch from the raw buffer data + transport cached methods.
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
/// Stores only raw Zig pointers — NO PyObject pointers at all.
/// GC never touches this batch. PyBytes is created during dispatch.
pub const CompletionRecord = extern struct {
    op: CompletionOp,
    stream_transport: ?*anyopaque,  // *Stream.StreamTransportObject (Zig ptr, NOT PyObject)
    buffer_ptr: ?*anyopaque,        // raw bytes from read transport buffer
    nbytes: i64,
};

/// Fixed-size batch buffer shared between Zig and dispatch.
/// Zig writes records, dispatch reads and calls protocol methods.
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
};
