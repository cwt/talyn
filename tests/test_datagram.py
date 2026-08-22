import asyncio
import socket

import pytest

import talyn


class DatagramProtocol(asyncio.DatagramProtocol):
    def __init__(self):
        self.on_con_made = asyncio.Future()
        self.on_con_lost = asyncio.Future()
        self.received = []

    def connection_made(self, transport):
        self.transport = transport
        self.on_con_made.set_result(True)

    def datagram_received(self, data, addr):
        self.received.append((data, addr))

    def connection_lost(self, exc):
        self.on_con_lost.set_result(exc)


class EchoServerProtocol(asyncio.DatagramProtocol):
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        self.transport.sendto(data, addr)


class EchoClientProtocol(asyncio.DatagramProtocol):
    def __init__(self, on_done, n):
        self.on_done = on_done
        self.n = n
        self.received = 0

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        self.received += 1
        if self.received >= self.n:
            self.on_done.set_result(True)

    def error_received(self, exc):
        self.on_done.set_exception(exc)


@pytest.mark.asyncio
async def test_create_datagram_endpoint_ipv4():
    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_datagram_endpoint(
        DatagramProtocol, local_addr=("127.0.0.1", 0)
    )
    try:
        assert isinstance(transport, asyncio.DatagramTransport)
        assert protocol.on_con_made.done()
    finally:
        transport.close()


@pytest.mark.asyncio
async def test_create_datagram_endpoint_ipv6():
    loop = asyncio.get_running_loop()
    try:
        transport, protocol = await loop.create_datagram_endpoint(
            DatagramProtocol, local_addr=("::1", 0)
        )
    except OSError:
        pytest.skip("IPv6 not supported")

    try:
        assert isinstance(transport, asyncio.DatagramTransport)
        assert protocol.on_con_made.done()
    finally:
        transport.close()


@pytest.mark.asyncio
async def test_create_datagram_endpoint_dns():
    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_datagram_endpoint(
        DatagramProtocol, local_addr=("localhost", 0)
    )
    try:
        assert isinstance(transport, asyncio.DatagramTransport)
        assert protocol.on_con_made.done()
    finally:
        transport.close()


@pytest.mark.asyncio
async def test_create_datagram_endpoint_remote():
    loop = asyncio.get_running_loop()
    # First create a server to listen
    t1, p1 = await loop.create_datagram_endpoint(
        DatagramProtocol, local_addr=("127.0.0.1", 0)
    )
    addr = t1.get_extra_info("sockname")

    # Create client connected to server
    t2, p2 = await loop.create_datagram_endpoint(DatagramProtocol, remote_addr=addr)

    try:
        msg = b"hello"
        t2.sendto(msg)

        # Wait for data
        for _ in range(10):
            if p1.received:
                break
            await asyncio.sleep(0.1)

        assert len(p1.received) == 1
        data, src = p1.received[0]
        assert data == msg
        # src should be t2's sockname
        # Note: If it's localhost, it might be 127.0.0.1
        t2_addr = t2.get_extra_info("sockname")
        assert src[1] == t2_addr[1]  # Compare port
        if src[0] == "127.0.0.1" or src[0] == "::1" or src[0] == "localhost":
            pass  # OK
    finally:
        t1.close()
        t2.close()


@pytest.mark.asyncio
async def test_datagram_echo():
    loop = asyncio.get_running_loop()

    t1, p1 = await loop.create_datagram_endpoint(
        EchoServerProtocol, local_addr=("127.0.0.1", 0)
    )
    addr = t1.get_extra_info("sockname")

    on_done = loop.create_future()
    t2, p2 = await loop.create_datagram_endpoint(
        lambda: EchoClientProtocol(on_done, 3), local_addr=("127.0.0.1", 0)
    )

    t2.sendto(b"hello", addr)
    t2.sendto(b"world", addr)
    t2.sendto(b"!", addr)

    await asyncio.wait_for(on_done, timeout=5)
    assert p2.received == 3

    t1.close()
    t2.close()


@pytest.mark.asyncio
async def test_datagram_get_extra_info_sockname():
    loop = asyncio.get_running_loop()
    t, p = await loop.create_datagram_endpoint(
        DatagramProtocol, local_addr=("127.0.0.1", 0)
    )
    try:
        sockname = t.get_extra_info("sockname")
        assert sockname is not None
        assert len(sockname) == 2
        assert isinstance(sockname[0], str)
        assert isinstance(sockname[1], int)
        assert sockname[1] > 0
    finally:
        t.close()


@pytest.mark.asyncio
async def test_datagram_get_extra_info_socket():
    loop = asyncio.get_running_loop()
    t, p = await loop.create_datagram_endpoint(
        DatagramProtocol, local_addr=("127.0.0.1", 0)
    )
    try:
        sock = t.get_extra_info("socket")
        assert sock is not None
        assert sock.family == socket.AF_INET
        assert sock.type == socket.SOCK_DGRAM
    finally:
        t.close()


@pytest.mark.asyncio
async def test_datagram_sendto_invalid_addr():
    loop = asyncio.get_running_loop()
    t, p = await loop.create_datagram_endpoint(
        DatagramProtocol, local_addr=("127.0.0.1", 0)
    )
    try:
        # Pass an invalid address structure to trigger a failure in fromPyAddr,
        # executing the corrected errdefer chain without double-freeing or leaking.
        with pytest.raises((TypeError, OSError, ValueError)):
            t.sendto(b"hello", 12345)
    finally:
        t.close()


@pytest.mark.asyncio
async def test_datagram_close_with_pending_operations():
    """Test that closing a datagram transport with pending read/write
    io_uring operations does not crash. BUG-20."""
    loop = asyncio.get_running_loop()

    t1, p1 = await loop.create_datagram_endpoint(
        EchoServerProtocol, local_addr=("127.0.0.1", 0)
    )
    addr = t1.get_extra_info("sockname")

    t2, p2 = await loop.create_datagram_endpoint(
        DatagramProtocol, local_addr=("127.0.0.1", 0)
    )

    # Send while reads are pending on both transports
    t2.sendto(b"ping", addr)

    # Close immediately while operations are still in-flight
    t2.close()
    t1.close()

    await asyncio.sleep(0.1)

    assert t2.is_closing()
    assert t1.is_closing()


class FuzzDatagramProtocol(asyncio.DatagramProtocol):
    def __init__(self):
        self.exception_received = asyncio.Future()

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        raise ValueError("Simulated error inside datagram_received")


@pytest.mark.asyncio
async def test_datagram_received_exception_no_double_free():
    loop = asyncio.get_running_loop()
    errors = []

    def custom_exception_handler(l, context):
        errors.append(context)

    loop.set_exception_handler(custom_exception_handler)

    try:
        t1, p1 = await loop.create_datagram_endpoint(
            FuzzDatagramProtocol, local_addr=("127.0.0.1", 0)
        )
        addr = t1.get_extra_info("sockname")

        t2, p2 = await loop.create_datagram_endpoint(
            DatagramProtocol, local_addr=("127.0.0.1", 0)
        )

        t2.sendto(b"ping", addr)
        await asyncio.sleep(0.1)

        t1.close()
        t2.close()

        assert len(errors) > 0
        assert any(isinstance(e.get("exception"), ValueError) for e in errors)
    finally:
        loop.set_exception_handler(None)


def test_create_datagram_endpoint_invalid_dns_timeout() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises(TypeError):
            await loop.create_datagram_endpoint(
                DatagramProtocol, local_addr=("127.0.0.1", 0), dns_timeout="invalid"
            )
        with pytest.raises(ValueError):
            await loop.create_datagram_endpoint(
                DatagramProtocol, local_addr=("127.0.0.1", 0), dns_timeout=-1.0
            )

    talyn.run(main())


@pytest.mark.asyncio
async def test_datagram_close_inflight_recv_buffer_safety():
    loop = asyncio.get_running_loop()
    t1, p1 = await loop.create_datagram_endpoint(
        EchoServerProtocol, local_addr=("127.0.0.1", 0)
    )
    addr = t1.get_extra_info("sockname")

    t2, p2 = await loop.create_datagram_endpoint(
        DatagramProtocol, local_addr=("127.0.0.1", 0)
    )

    t2.sendto(b"payload_bytes", addr)
    t2.close()
    await asyncio.sleep(0.05)
    t1.close()
    await asyncio.sleep(0.05)




class RaisingPauseProtocol(DatagramProtocol):
    def pause_writing(self):
        raise ValueError("simulated pause_writing failure")


@pytest.mark.asyncio
async def test_datagram_sendto_pause_writing_error_no_uaf():
    """BUG-270: a failing buffer_watermark_check after io.queue() took
    ownership must not free the queued SendToData/data_buf (errdefers have
    to stand down once the SQE is outstanding)."""
    loop = asyncio.get_running_loop()
    t, p = await loop.create_datagram_endpoint(
        RaisingPauseProtocol, local_addr=("127.0.0.1", 0)
    )
    try:
        addr = ("127.0.0.1", 9)
        t.set_write_buffer_limits(1, 1)
        with pytest.raises(ValueError, match="simulated pause_writing"):
            t.sendto(b"x" * 16, addr)
        # Transport stays usable afterwards and closes cleanly.
        t.sendto(b"y", addr)
        await asyncio.sleep(0.05)
    finally:
        t.close()


@pytest.mark.asyncio
async def test_bad_protocol_factory_no_resource_leak():
    """BUG-283: a protocol factory returning a non-DatagramProtocol must
    fail cleanly - the failed transport construction used to leak the loop
    reference, a fixed-file slot, and its buffer lease (bare tp_free)."""
    loop = asyncio.get_running_loop()

    class NotADatagramProtocol:  # missing datagram_received etc.
        pass

    def bad_factory():
        return NotADatagramProtocol()

    with pytest.raises(TypeError):
        await loop.create_datagram_endpoint(
            bad_factory, local_addr=("127.0.0.1", 0)
        )

    # The loop must remain fully operational and the fixed-file pool must
    # not have been exhausted by repeated failures.
    for _ in range(5):
        with pytest.raises(TypeError):
            await loop.create_datagram_endpoint(bad_factory, local_addr=("127.0.0.1", 0))

    t, p = await loop.create_datagram_endpoint(
        DatagramProtocol, local_addr=("127.0.0.1", 0)
    )
    t.close()
