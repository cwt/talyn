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
    transport_generation: u64,
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

const testing = std.testing;

test "CompletionRecord.transport_generation field" {
    // Verifies BUG-32: the generation field can be stored and read back
    // correctly so dispatch can detect stale records.
    const record = CompletionRecord{
        .op = .DataReceived,
        .stream_transport = @ptrFromInt(0xDEAD_BEEF),
        .buffer_ptr = @ptrFromInt(0xCAFE_F00D),
        .nbytes = 42,
        .transport_generation = 7,
    };
    try testing.expectEqual(@as(u64, 7), record.transport_generation);
    try testing.expectEqual(@as(i64, 42), record.nbytes);
}

test "CompletionBatch push stores transport_generation" {
    var batch = CompletionBatch{};
    const pushed = batch.push(.{
        .op = .DataReceived,
        .stream_transport = null,
        .buffer_ptr = null,
        .nbytes = 1024,
        .transport_generation = 99,
    });
    try testing.expect(pushed);
    try testing.expectEqual(@as(usize, 1), batch.ready_count);
    try testing.expectEqual(@as(u64, 99), batch.records[0].transport_generation);

    batch.reset();
    try testing.expect(batch.is_empty());
}
