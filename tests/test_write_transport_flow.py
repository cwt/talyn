"""BUG-379 regression tests.

WriteTransport flow-control and write_eof bugs:

- ``queue_eof`` returned immediately whenever ``buffer_size > 0``:
  because all ``transport.write()`` payloads are batched into
  ``pending_buffers`` (submitted on the ``.prepare`` hook), calling
  ``transport.write(b"request"); transport.write_eof()`` silently
  dropped the FIN — the peer never saw an EOF.
- ``write_operation_completed`` only invoked the stream-level
  completion callback at the full (0-byte) drain, so
  ``protocol.resume_writing()`` could not fire when the buffer dropped
  below ``writing_low_water_mark`` during a multi-chunk drain.
- ``set_write_buffer_limits`` raised ``TypeError`` on ``None``,
  raised ``OverflowError`` on negatives, silently clamped ``low > high``,
  used the wrong ``low`` defaults (32 KiB instead of ``high // 4``),
  leaked positional references when kwargs were merged on top, and
  never re-evaluated pause/resume against the new limits.
"""

import pytest

import talyn

talyn.install()

import asyncio


class ServerFinObserver(asyncio.Protocol):
    def __init__(self):
        self.received = b""
        self.got_fin = False
        self.received_at_fin = None

    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        self.received += bytes(data)

    def connection_lost(self, exc):
        self.got_fin = True
        self.received_at_fin = len(self.received)


@pytest.mark.asyncio
async def test_bug379_write_eof_after_write_sends_fin():
    loop = asyncio.get_running_loop()
    observer = ServerFinObserver()

    def make_observer():
        return observer

    server = await loop.create_server(make_observer, "127.0.0.1", 0)
    addr = server.sockets[0].getsockname()

    transport, protocol = await loop.create_connection(
        ServerFinObserver, addr[0], addr[1]
    )
    # The exact trigger scenario from the report: a write that only
    # reaches the socket after the .prepare flush, followed directly by
    # write_eof().
    transport.write(b"request")
    transport.write_eof()

    deadline = loop.time() + 3.0
    while not observer.got_fin and loop.time() < deadline:
        await asyncio.sleep(0.05)

    assert observer.got_fin, (
        "the peer never saw the connection drain: write_eof() called "
        "after write(b'request') was silently dropped (no FIN)"
    )
    assert observer.received == b"request", (
        f"peer received {observer.received!r} before EOF"
    )
    assert observer.received_at_fin == len(b"request")

    transport.close()  # idempotent: already closing after write_eof()
    server.close()


class PausedFlowProtocol(asyncio.Protocol):
    def __init__(self):
        self.connected = asyncio.get_running_loop().create_future()
        self.transport = None
        self.pause_sizes = []
        self.resume_sizes = []

    def connection_made(self, transport):
        self.transport = transport
        if not self.connected.done():
            self.connected.set_result(None)

    def data_received(self, data):
        pass

    def pause_writing(self):
        self.pause_sizes.append(self.transport.get_write_buffer_size())

    def resume_writing(self):
        self.resume_sizes.append(self.transport.get_write_buffer_size())

    def connection_lost(self, exc):
        pass


class DiscardServerProtocol(asyncio.Protocol):
    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        pass  # keep reading so the socket buffer keeps accepting writes

    def connection_lost(self, exc):
        pass


@pytest.mark.asyncio
async def test_bug379_resume_writing_fires_at_low_water_crossing():
    loop = asyncio.get_running_loop()
    server = await loop.create_server(
        DiscardServerProtocol, "127.0.0.1", 0
    )
    addr = server.sockets[0].getsockname()

    transport, protocol = await loop.create_connection(
        PausedFlowProtocol, addr[0], addr[1]
    )
    await protocol.connected

    try:
        transport.set_write_buffer_limits(high=64 * 1024, low=16 * 1024)

        # One write call == one pending buffer == one SQE; 70000 > high
        # pauses writing at the write() call itself.
        transport.write(b"s" * 70000)
        assert protocol.pause_sizes == [70000], (
            f"pause_writing did not fire at the write boundary: "
            f"{protocol.pause_sizes}"
        )

        # Multi-chunk drain: 6 more SQEs step the buffer down by
        # 10000 at a time; at 10000 the crossing below low (16384)
        # happens with data still buffered.
        for _ in range(6):
            transport.write(b"s" * 10000)

        # Drain until complete.
        deadline = loop.time() + 10.0
        while transport.get_write_buffer_size() > 0 and loop.time() < deadline:
            await asyncio.sleep(0.01)

        assert transport.get_write_buffer_size() == 0
        assert protocol.resume_sizes and protocol.resume_sizes[-1] > 0, (
            f"resume_writing only fired at the empty buffer: "
            f"{protocol.resume_sizes} — the low-water mark was ignored "
            "during the multi-chunk drain"
        )
        assert protocol.resume_sizes[-1] <= 16 * 1024, (
            f"resume fired above the low-water mark: {protocol.resume_sizes}"
        )
    finally:
        transport.close()
        server.close()


@pytest.mark.asyncio
async def test_bug379_set_write_buffer_limits_semantics():
    loop = asyncio.get_running_loop()
    server = await loop.create_server(
        DiscardServerProtocol, "127.0.0.1", 0
    )
    addr = server.sockets[0].getsockname()

    transport, _protocol = await loop.create_connection(
        PausedFlowProtocol, addr[0], addr[1]
    )
    try:
        # high only -> low defaults to high // 4 (stdlib); the old code
        # returned (32768, 40000). Post-fix: (10000, 40000).
        transport.set_write_buffer_limits(high=40000)
        assert transport.get_write_buffer_limits() == (10000, 40000)

        # None (both signatures of the stdlib call) is "not specified":
        # resets to the defaults high=64 KiB, low=high // 4.
        transport.set_write_buffer_limits(None, None)
        assert transport.get_write_buffer_limits() == (65536 // 4, 65536)

        transport.set_write_buffer_limits(high=None, low=None)
        assert transport.get_write_buffer_limits() == (65536 // 4, 65536)

        # Negative values raise ValueError (the old code overflowed into
        # OverflowError for negatives and silently clamped low > high).
        with pytest.raises(ValueError):
            transport.set_write_buffer_limits(low=-1)
        with pytest.raises(ValueError):
            transport.set_write_buffer_limits(high=-50)

        # low > high must raise, not clamp.
        with pytest.raises(ValueError):
            transport.set_write_buffer_limits(high=100, low=200)

        # Duplicate argument passing (positional + keyword) raises
        # TypeError like CPython; the old code silently overwrote and
        # leaked the positional reference.
        with pytest.raises(TypeError):
            transport.set_write_buffer_limits(1024, high=2048)

        # Only low given -> high = 4 * low (stdlib defaulting).
        transport.set_write_buffer_limits(low=512)
        assert transport.get_write_buffer_limits() == (512, 2048)
    finally:
        transport.close()
        server.close()


@pytest.mark.asyncio
async def test_bug379_set_write_buffer_limits_reevaluates_flow_control():
    loop = asyncio.get_running_loop()
    server = await loop.create_server(
        DiscardServerProtocol, "127.0.0.1", 0
    )
    addr = server.sockets[0].getsockname()

    transport, protocol = await loop.create_connection(
        PausedFlowProtocol, addr[0], addr[1]
    )
    await protocol.connected

    try:
        # Fill the buffer far above the default high-water mark: the
        # write() path pauses.
        transport.write(b"p" * 70000)
        assert protocol.pause_sizes == [70000]
        protocol.pause_sizes.clear()

        # Raising the limit above the buffered size lets the transport
        # resume (the new low-water admits the buffered size).
        transport.set_write_buffer_limits(high=512 * 1024, low=128 * 1024)
        assert protocol.resume_sizes and protocol.resume_sizes[-1] == 70000, (
            f"set_write_buffer_limits did not re-evaluate flow control: "
            f"{protocol.resume_sizes}"
        )

        # Lowering it below the buffered size pauses again.
        transport.set_write_buffer_limits(high=16 * 1024, low=4 * 1024)
        assert protocol.pause_sizes and protocol.pause_sizes[-1] == 70000, (
            f"set_write_buffer_limits did not pause above the new "
            f"high-water mark: {protocol.pause_sizes}"
        )
    finally:
        transport.close()
        server.close()
