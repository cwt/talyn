"""BUG-378 regression tests.

StreamTransport lifecycle state machine:

- ``close_transports`` did not set ``is_closing``, so an EOF/I/O-error
  close left ``transport.is_closing()`` False and a later
  ``transport.close()`` ran the machinery a second time.
- ``close()`` followed by ``abort()`` invoked
  ``protocol.connection_lost`` twice (close_transports scheduled one
  via ``call_soon`` and ``abort()`` fired one synchronously).
- ``close()`` cancelled the in-flight write and notified
  ``connection_lost`` on the next tick while buffered writes were still
  pending — violating the asyncio contract that ``close()`` flushes
  buffered data before ``connection_lost``; the cancelled write left
  the buffered remainder permanently undrained.
"""

import pytest

import talyn

talyn.install()

import asyncio

PAYLOAD = b"x" * (16 * 1024 * 1024)


class CountingLostProtocol(asyncio.Protocol):
    def __init__(self):
        self.lost_count = 0
        self.connected = asyncio.get_running_loop().create_future()

    def connection_made(self, transport):
        self.transport = transport
        if not self.connected.done():
            self.connected.set_result(None)

    def data_received(self, data):
        pass

    def connection_lost(self, exc):
        self.lost_count += 1


@pytest.mark.asyncio
async def test_bug378_connection_lost_called_exactly_once_close_then_abort():
    loop = asyncio.get_running_loop()
    server = await loop.create_server(CountingLostProtocol, "127.0.0.1", 0)
    addr = server.sockets[0].getsockname()

    transport, protocol = await loop.create_connection(
        CountingLostProtocol, addr[0], addr[1]
    )
    await protocol.connected
    transport.write(b"ping")
    transport.close()
    transport.abort()  # immediately after close(): must not double-notify

    deadline = loop.time() + 2.0
    while protocol.lost_count < 1 and loop.time() < deadline:
        await asyncio.sleep(0.02)
    await asyncio.sleep(0.1)  # let any stray second notification fire
    assert protocol.lost_count == 1, (
        f"protocol.connection_lost called {protocol.lost_count} times "
        "(close()+abort() double notification)"
    )

    await asyncio.sleep(0.05)
    transport.close()  # repeated close afterwards stays a no-op
    await asyncio.sleep(0.02)
    assert protocol.lost_count == 1
    server.close()


class ByteCounterProtocol(asyncio.Protocol):
    def __init__(self):
        self.received = bytearray()
        self.lost_at = None

    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        self.received.extend(data)

    def connection_lost(self, exc):
        self.lost_at = len(self.received)


@pytest.mark.asyncio
async def test_bug378_close_flushes_buffered_writes_before_connection_lost():
    loop = asyncio.get_running_loop()
    counter = ByteCounterProtocol()

    def make_counter():
        return counter

    server = await loop.create_server(make_counter, "127.0.0.1", 0)
    addr = server.sockets[0].getsockname()

    transport, protocol = await loop.create_connection(
        CountingLostProtocol, addr[0], addr[1]
    )
    transport.write(PAYLOAD)  # large: one SQE in flight + buffered tail
    transport.close()  # immediately after the write

    deadline = loop.time() + 10.0
    while counter.lost_at is None and loop.time() < deadline:
        await asyncio.sleep(0.05)

    server.close()
    assert counter.received == PAYLOAD, (
        f"peer received {len(counter.received)}/{len(PAYLOAD)} bytes: "
        "close() cancelled the in-flight write and dropped buffered data"
    )
    assert protocol.lost_count == 1


@pytest.mark.asyncio
async def test_bug378_is_closing_true_after_peer_eof():
    loop = asyncio.get_running_loop()
    served = []

    def make_server_protocol():
        protocol = CountingLostProtocol()
        served.append(protocol)
        return protocol

    server = await loop.create_server(make_server_protocol, "127.0.0.1", 0)
    addr = server.sockets[0].getsockname()

    transport, protocol = await loop.create_connection(
        CountingLostProtocol, addr[0], addr[1]
    )
    await protocol.connected

    service = served[0] if served else None
    if service is not None:
        service.transport.abort()  # server side hangs up -> client sees EOF

    deadline = loop.time() + 5.0
    while loop.time() < deadline and not transport.is_closing():
        await asyncio.sleep(0.05)

    assert transport.is_closing(), (
        "transport.is_closing() stayed False after the peer closed the "
        "connection (EOF close path)"
    )
    server.close()


@pytest.mark.asyncio
async def test_bug378_eof_with_pending_writes_still_settles():
    # Peer EOF while a large write is still in flight/pending: pre-fix
    # close() cancelled the in-flight SQE and the cancelled completion
    # never resubmitted, so the write side stayed identified as open
    # forever (is_closing() False, connection_lost never reaching a
    # settled closed state). Post-fix close() lets the drain continue.
    loop = asyncio.get_running_loop()
    served = []

    def make_server_protocol():
        protocol = CountingLostProtocol()
        served.append(protocol)
        return protocol

    server = await loop.create_server(make_server_protocol, "127.0.0.1", 0)
    addr = server.sockets[0].getsockname()

    transport, protocol = await loop.create_connection(
        CountingLostProtocol, addr[0], addr[1]
    )
    await protocol.connected

    transport.write(PAYLOAD)
    await asyncio.sleep(0.01)  # let a write SQE enter flight

    service = served[0] if served else None
    if service is not None:
        service.transport.abort()  # the peer goes away mid-write

    deadline = loop.time() + 5.0
    while loop.time() < deadline and not transport.is_closing():
        await asyncio.sleep(0.05)

    assert transport.is_closing(), (
        "transport never settled after peer EOF with pending writes "
        "(cancelled in-flight write stranded the drain)"
    )
    server.close()
