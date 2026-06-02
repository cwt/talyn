import asyncio
import os
import socket

import pytest

import talyn
from talyn import StreamTransport


class BufferedEchoProtocol(asyncio.BufferedProtocol):
    def __init__(self) -> None:
        loop = asyncio.get_running_loop()

        self.disconnected = loop.create_future()
        self.received = loop.create_future()
        self.buffer: bytearray | None = None

        self.pause_writing_fut = loop.create_future()
        self.resume_writing_fut = loop.create_future()
        self.eof_received_fut = loop.create_future()

        self.error: BaseException | None = None

    def get_buffer(self, sizehint: int) -> bytearray:
        self.buffer = bytearray(sizehint)
        return self.buffer

    def buffer_updated(self, nbytes: int) -> None:
        if self.buffer is not None:
            data = bytes(self.buffer[:nbytes])

            loop = asyncio.get_running_loop()
            new_fut = loop.create_future()
            self.received.set_result((new_fut, data))

            self.received = new_fut
            self.buffer = None

    def connection_lost(self, exc: BaseException | None) -> None:
        self.error = exc

        self.received.cancel()
        self.resume_writing_fut.cancel()
        self.pause_writing_fut.cancel()

        self.disconnected.set_result(None)

    def eof_received(self) -> bool | None:
        self.eof_received_fut.set_result(None)

        loop = asyncio.get_running_loop()
        self.eof_received_fut = loop.create_future()

        return None

    def pause_writing(self) -> None:
        self.pause_writing_fut.set_result(None)

        loop = asyncio.get_running_loop()
        self.pause_writing_fut = loop.create_future()

    def resume_writing(self) -> None:
        self.resume_writing_fut.set_result(None)

        loop = asyncio.get_running_loop()
        self.resume_writing_fut = loop.create_future()


class EchoProtocol(asyncio.Protocol):
    def __init__(self) -> None:
        loop = asyncio.get_running_loop()

        self.disconnected = loop.create_future()
        self.received = loop.create_future()

        self.pause_writing_fut = loop.create_future()
        self.resume_writing_fut = loop.create_future()
        self.eof_received_fut = loop.create_future()

        self.error: BaseException | None = None

    # def connection_made(self, transport):
    #     self.transport = transport
    #     self.connected.set_result(None)

    def data_received(self, data: bytes) -> None:
        loop = asyncio.get_running_loop()
        new_fut = loop.create_future()

        self.received.set_result((new_fut, data))
        self.received = new_fut

    def connection_lost(self, exc: BaseException | None) -> None:
        self.error = exc

        self.received.cancel()
        self.resume_writing_fut.cancel()
        self.pause_writing_fut.cancel()

        self.disconnected.set_result(None)

    def eof_received(self) -> bool | None:
        self.eof_received_fut.set_result(None)

        loop = asyncio.get_running_loop()
        self.eof_received_fut = loop.create_future()

        return None

    def pause_writing(self) -> None:
        self.pause_writing_fut.set_result(None)

        loop = asyncio.get_running_loop()
        self.pause_writing_fut = loop.create_future()

    def resume_writing(self) -> None:
        self.resume_writing_fut.set_result(None)

        loop = asyncio.get_running_loop()
        self.resume_writing_fut = loop.create_future()


async def _test_stream_transport_basics() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = EchoProtocol()
    client_protocol = EchoProtocol()

    # Create transport
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)
    try:
        # Test writing data
        test_data = b"Hello, World!"
        server_transport.write(test_data)

        # Wait for data to be received and echoed back
        _, received_data = await asyncio.wait_for(
            asyncio.shield(client_protocol.received), 1
        )
        assert received_data == test_data

        test_data2 = b"Thanks!!"
        client_transport.write(test_data2)

        _, received_data = await asyncio.wait_for(
            asyncio.shield(server_protocol.received), 1
        )
        assert received_data == test_data2

        # Close transport and wait for disconnection
        server_transport.close()
        await asyncio.wait_for(asyncio.shield(server_protocol.disconnected), 1)
        assert server_protocol.error is None  # Normal close
    finally:
        server_transport.close()
        client_transport.close()


def test_stream_transport_basics() -> None:
    talyn.run(_test_stream_transport_basics())


async def _test_stream_transport_multiple_writes() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = EchoProtocol()
    client_protocol = EchoProtocol()

    # Create transport
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)

    try:
        # Test multiple writes from server to client
        messages = [b"Hello", b"World", b"Testing", b"Multiple", b"Writes"]

        for msg in messages:
            server_transport.write(msg)
            _, received = await asyncio.wait_for(
                asyncio.shield(client_protocol.received), 1
            )
            assert received == msg

        # Test multiple writes from client to server
        responses = [b"Response1", b"Response2", b"Response3", b"Final"]
        for msg in responses:
            client_transport.write(msg)
            _, received = await asyncio.wait_for(
                asyncio.shield(server_protocol.received), 1
            )
            assert received == msg
    finally:
        server_transport.close()
        client_transport.close()


def test_stream_transport_multiple_writes() -> None:
    talyn.run(_test_stream_transport_multiple_writes())


async def _test_stream_transport_large_writes() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = EchoProtocol()
    client_protocol = EchoProtocol()

    # Create transport
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)

    try:
        # Test large write from server to client (1MB)
        large_data = os.urandom(1024 * 1024)  # 1MB of data
        server_transport.write(large_data)

        response = b""
        fut = client_protocol.received
        while len(response) < len(large_data):
            fut, received = await asyncio.wait_for(asyncio.shield(fut), 10)
            response += received

        assert response == large_data

        # Test large write from client to server (2MB)
        large_response = os.urandom(2 * 1024 * 1024)  # 2MB of data
        client_transport.write(large_response)

        response = b""
        fut = server_protocol.received
        while len(response) < len(large_response):
            fut, received = await asyncio.wait_for(asyncio.shield(fut), 10)
            response += received

        assert response == large_response
    finally:
        server_transport.close()
        client_transport.close()


def test_stream_transport_large_writes() -> None:
    talyn.run(_test_stream_transport_large_writes())


async def _test_stream_transport_watermarks() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = EchoProtocol()
    client_protocol = EchoProtocol()

    # Create transport with custom watermarks
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)

    try:
        server_transport.set_write_buffer_limits(10, 10)
        # Test writing data slightly below high watermark
        received_fut = client_protocol.received
        pause_writing = client_protocol.pause_writing_fut

        data_below = os.urandom(5)
        server_transport.write(data_below)

        await asyncio.wait_for(asyncio.shield(received_fut), 1)
        assert not pause_writing.done()

        received_fut = client_protocol.received
        pause_writing = server_protocol.pause_writing_fut
        resume_writing = server_protocol.resume_writing_fut

        data_above = os.urandom(15)
        server_transport.write(data_above)

        await asyncio.wait_for(asyncio.shield(pause_writing), 1)
        await asyncio.wait_for(asyncio.shield(resume_writing), 1)
        await asyncio.wait_for(asyncio.shield(received_fut), 1)
    finally:
        server_transport.close()
        client_transport.close()


def test_stream_transport_watermarks() -> None:
    talyn.run(_test_stream_transport_watermarks())


async def _test_stream_transport_eof() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = EchoProtocol()
    client_protocol = EchoProtocol()

    # Create transport
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)

    try:
        # Test EOF handling
        test_data = b"Last message before EOF"
        server_transport.write(test_data)

        # Wait for data to be received
        _, received_data = await asyncio.wait_for(
            asyncio.shield(client_protocol.received), 1
        )
        assert received_data == test_data

        # Close write end of the server socket to trigger EOF
        server_transport.write_eof()

        # Wait for EOF to be received by client
        await asyncio.wait_for(asyncio.shield(client_protocol.eof_received_fut), 1)
    finally:
        server_transport.close()
        client_transport.close()


def test_stream_transport_eof() -> None:
    talyn.run(_test_stream_transport_eof())


async def _test_stream_transport_eof_with_pending_writes() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = EchoProtocol()
    client_protocol = EchoProtocol()

    # Create transport with small buffer to ensure writes are pending
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)

    try:
        client_eof_fut = client_protocol.eof_received_fut

        # Write first two chunks of data
        data1 = b"First chunk of data"
        server_transport.write(data1)

        data2 = b"Second chunk of data"
        server_transport.write(data2)

        # Try to write EOF while writes are pending
        server_transport.write_eof()

        # Write third chunk of data after EOF
        data3 = b"Third chunk after attempted EOF"
        server_transport.write(data3)

        await asyncio.sleep(0.1)
        assert not client_eof_fut.done()
    finally:
        server_transport.close()
        client_transport.close()


def test_stream_transport_eof_with_pending_writes() -> None:
    talyn.run(_test_stream_transport_eof_with_pending_writes())


async def _test_buffered_protocol_basics() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = BufferedEchoProtocol()
    client_protocol = BufferedEchoProtocol()

    # Create transport
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)

    try:
        # Test writing data
        test_data = b"Hello, Buffered World!"
        server_transport.write(test_data)

        # Wait for data to be received
        _, received_data = await asyncio.wait_for(
            asyncio.shield(client_protocol.received), 1
        )
        assert received_data == test_data

        # Test response
        response_data = b"Buffered Response!"
        client_transport.write(response_data)

        _, received_data = await asyncio.wait_for(
            asyncio.shield(server_protocol.received), 1
        )
        assert received_data == response_data

    finally:
        server_transport.close()
        client_transport.close()


def test_buffered_protocol_basics() -> None:
    talyn.run(_test_buffered_protocol_basics())


async def _test_stream_transport_writelines() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = EchoProtocol()
    client_protocol = EchoProtocol()

    # Create transport
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)

    try:
        # Test writelines with a list of bytes
        messages = [b"First Line\n", b"Second Line\n", b"Third Line\n"]
        server_transport.writelines(messages)

        # Verify each line is received correctly
        total_length = sum(map(len, messages))
        data_received = b""
        fut = client_protocol.received
        while len(data_received) < total_length:
            fut, received = await asyncio.wait_for(asyncio.shield(fut), 1)
            data_received += received

        assert len(data_received) == total_length
        assert data_received.decode() == "".join(x.decode() for x in messages)
    finally:
        server_transport.close()
        client_transport.close()


def test_stream_transport_writelines() -> None:
    talyn.run(_test_stream_transport_writelines())


# BUG-50 regression: writelines with many empty buffers must not stack-overflow.
# The previous recursive `submit_next_chunk` would overflow the stack if a
# caller provided many zero-length iovec entries in a row. The fix replaced
# the recursion with a `while` loop. This test exercises that path.
async def _test_stream_transport_writelines_many_empty_buffers() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = EchoProtocol()
    client_protocol = EchoProtocol()

    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)

    try:
        # 10,000 empty buffers followed by a real one. With the recursive
        # submit_next_chunk, this would overflow the stack (each call adds a
        # stack frame); the loop-based fix handles it in O(N) time with O(1)
        # stack depth.
        messages: list[bytes] = [b""] * 10_000 + [b"hello\n"]
        server_transport.writelines(messages)

        # Verify the real message is received.
        total_length = len(b"hello\n")
        data_received = b""
        fut = client_protocol.received
        while len(data_received) < total_length:
            fut, received = await asyncio.wait_for(asyncio.shield(fut), 1)
            data_received += received
        assert data_received == b"hello\n"
    finally:
        server_transport.close()
        client_transport.close()


def test_stream_transport_writelines_many_empty_buffers() -> None:
    talyn.run(_test_stream_transport_writelines_many_empty_buffers())


async def _test_stream_transport_abort() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = EchoProtocol()
    client_protocol = EchoProtocol()

    # Create transport
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)

    try:
        # Send some data before abort
        test_data = b"Data before abort"
        server_transport.write(test_data)

        # Wait for data to be received
        _, received_data = await asyncio.wait_for(
            asyncio.shield(client_protocol.received), 1
        )
        assert received_data == test_data

        # Abort the server transport
        server_transport.abort()

        # Wait for disconnection and verify error
        await asyncio.wait_for(asyncio.shield(server_protocol.disconnected), 1)
        assert server_protocol.error is None

        # Try to write after abort - should not raise but data won't be sent
        server_transport.write(b"Data after abort")

        # Client should detect the connection was lost
        await asyncio.wait_for(asyncio.shield(client_protocol.disconnected), 1)
    finally:
        server_transport.close()
        client_transport.close()


def test_stream_transport_abort() -> None:
    talyn.run(_test_stream_transport_abort())


async def _test_stream_transport_reading_control() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = EchoProtocol()
    client_protocol = EchoProtocol()

    # Create transport
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)

    try:
        # Verify initial reading state
        assert server_transport.is_reading()
        assert client_transport.is_reading()

        # Test pausing reading on server
        server_transport.pause_reading()
        assert not server_transport.is_reading()

        await asyncio.sleep(0)

        # Send data from client while server reading is paused
        test_data = b"Data while paused"
        client_transport.write(test_data)

        server_received_fut = server_protocol.received
        # Give some time for potential data transfer
        await asyncio.sleep(0.1)

        # Server should not have received the data yet
        assert not server_received_fut.done()

        # Resume reading and verify data is received
        server_transport.resume_reading()
        assert server_transport.is_reading()

        _, received_data = await asyncio.wait_for(
            asyncio.shield(server_received_fut), 1
        )
        assert received_data == test_data

        # Test pausing and resuming on client side
        client_transport.pause_reading()
        assert not client_transport.is_reading()

        response_data = b"Response data"
        server_transport.write(response_data)

        client_received_fut = client_protocol.received
        await asyncio.sleep(0.1)
        assert not client_received_fut.done()

        client_transport.resume_reading()
        assert client_transport.is_reading()

        _, received_response = await asyncio.wait_for(
            asyncio.shield(client_protocol.received), 1
        )
        assert received_response == response_data

    finally:
        server_transport.close()
        client_transport.close()


def test_stream_transport_reading_control() -> None:
    talyn.run(_test_stream_transport_reading_control())


async def _test_stream_transport_rapid_reading_toggle() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = EchoProtocol()
    client_protocol = EchoProtocol()

    # Create transport
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)

    try:
        # Initial state should be reading
        assert server_transport.is_reading()

        # Rapidly toggle reading state
        for _ in range(10):
            server_transport.pause_reading()
            assert not server_transport.is_reading()

            server_transport.resume_reading()
            assert server_transport.is_reading()

        # Verify transport still works after rapid toggling
        test_data = b"Data after toggling"
        client_transport.write(test_data)

        _, received_data = await asyncio.wait_for(
            asyncio.shield(server_protocol.received), 1
        )
        assert received_data == test_data

    finally:
        server_transport.close()
        client_transport.close()


def test_stream_transport_rapid_reading_toggle() -> None:
    talyn.run(_test_stream_transport_rapid_reading_toggle())


async def _test_stream_transport_buffer_types() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = EchoProtocol()
    client_protocol = EchoProtocol()

    # Create transport
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)

    try:
        # Test with bytes
        bytes_data = b"Regular bytes data"
        server_transport.write(bytes_data)
        _, received_data = await asyncio.wait_for(
            asyncio.shield(client_protocol.received), 1
        )
        assert received_data == bytes_data

        # Test with bytearray
        bytearray_data = bytearray(b"Bytearray data")
        server_transport.write(bytearray_data)
        _, received_data = await asyncio.wait_for(
            asyncio.shield(client_protocol.received), 1
        )
        assert received_data == bytearray_data

        # Test with memoryview
        original_data = b"Memoryview data"
        memview_data = memoryview(original_data)
        server_transport.write(memview_data)
        _, received_data = await asyncio.wait_for(
            asyncio.shield(client_protocol.received), 1
        )
        assert received_data == original_data

        # Test with sliced memoryview
        full_data = b"Full data with slice"
        memview_slice = memoryview(full_data)[5:15]  # slice "data with" portion
        server_transport.write(memview_slice)
        _, received_data = await asyncio.wait_for(
            asyncio.shield(client_protocol.received), 1
        )
        assert received_data == full_data[5:15]

    finally:
        server_transport.close()
        client_transport.close()


def test_stream_transport_buffer_types() -> None:
    talyn.run(_test_stream_transport_buffer_types())


async def _test_stream_transport_extra_info() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = EchoProtocol()
    client_protocol = EchoProtocol()

    # Create transport
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)

    try:
        # Test socket info
        socket_info = server_transport.get_extra_info("socket")
        assert socket_info is not None
        assert socket_info.fileno() == server_socket.fileno()

        socket_info = client_transport.get_extra_info("socket")
        assert socket_info is not None
        assert socket_info.fileno() == client_socket.fileno()

        # Test peername
        peername = server_transport.get_extra_info("peername")
        assert peername == server_socket.getpeername()

        peername = client_transport.get_extra_info("peername")
        assert peername == client_socket.getpeername()

        # Test sockname multiple times to verify no borrowed reference leak/double-free (BUG-03)
        sockname1 = server_transport.get_extra_info("sockname")
        sockname2 = server_transport.get_extra_info("sockname")
        assert sockname1 == sockname2
        assert sockname1 == server_socket.getsockname()

        sockname3 = client_transport.get_extra_info("sockname")
        sockname4 = client_transport.get_extra_info("sockname")
        assert sockname3 == sockname4
        assert sockname3 == server_socket.getsockname()

        # Test peername multiple times too
        peername1 = server_transport.get_extra_info("peername")
        peername2 = server_transport.get_extra_info("peername")
        assert peername1 == peername2
        assert peername1 == server_socket.getpeername()
    finally:
        server_transport.close()
        client_transport.close()


def test_stream_transport_extra_info() -> None:
    talyn.run(_test_stream_transport_extra_info())


async def _test_stream_transport_invalid_inputs() -> None:
    loop = asyncio.get_running_loop()
    server_socket, _ = socket.socketpair()
    server_socket.setblocking(False)

    server_protocol = EchoProtocol()

    # Test invalid file descriptor
    with pytest.raises(ValueError):
        StreamTransport(-1, server_protocol, loop)

    # Test None protocol
    with pytest.raises(TypeError):
        StreamTransport(server_socket.fileno(), None, loop)  # type: ignore

    # Test None loop
    with pytest.raises(TypeError):
        StreamTransport(server_socket.fileno(), server_protocol, None)  # type: ignore

    # Test invalid extra_info key
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    try:
        server_transport.get_extra_info("invalid_key")
    finally:
        server_transport.close()


def test_stream_transport_invalid_inputs() -> None:
    talyn.run(_test_stream_transport_invalid_inputs())


async def _test_stream_transport_write_edge_cases() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = EchoProtocol()
    client_protocol = EchoProtocol()

    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)
    client_transport = StreamTransport(client_socket.fileno(), client_protocol, loop)

    try:
        # Test writing empty bytes
        server_transport.write(b"")
        await asyncio.sleep(0.1)  # Give time for potential processing

        # Test writing None
        with pytest.raises(TypeError):
            server_transport.write(None)  # type: ignore

        # Test writing non-bytes/bytearray/memoryview
        with pytest.raises(TypeError):
            server_transport.write("not bytes")  # type: ignore

        # Test writelines with invalid input
        with pytest.raises(TypeError):
            server_transport.writelines(["not", "bytes"])  # type: ignore

        # Test writelines with None
        with pytest.raises(TypeError):
            server_transport.writelines(None)  # type: ignore

    finally:
        server_transport.close()
        client_transport.close()


def test_stream_transport_write_edge_cases() -> None:
    talyn.run(_test_stream_transport_write_edge_cases())


async def _test_stream_transport_get_write_buffer_limits() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()

    server_socket.setblocking(False)
    client_socket.setblocking(False)

    server_protocol = asyncio.Protocol()

    # Create transport
    server_transport = StreamTransport(server_socket.fileno(), server_protocol, loop)

    try:
        # Check default limits
        limits = server_transport.get_write_buffer_limits()
        assert isinstance(limits, tuple)
        assert len(limits) == 2

        # Set new limits
        server_transport.set_write_buffer_limits(low=1000, high=2000)
        assert server_transport.get_write_buffer_limits() == (1000, 2000)
    finally:
        server_transport.close()
        client_socket.close()


def test_stream_transport_get_write_buffer_limits() -> None:
    talyn.run(_test_stream_transport_get_write_buffer_limits())


async def _test_stream_transport_is_writing_initialized() -> None:
    loop = asyncio.get_running_loop()
    server_socket, client_socket = socket.socketpair()
    server_socket.setblocking(False)
    client_socket.setblocking(False)

    resume_called_before_pause = False
    pause_called = False

    class TrackingProtocol(asyncio.Protocol):
        def connection_made(self, transport):
            pass

        def data_received(self, data):
            pass

        def pause_writing(self):
            nonlocal pause_called
            pause_called = True

        def resume_writing(self):
            nonlocal resume_called_before_pause
            if not pause_called:
                resume_called_before_pause = True

        def connection_lost(self, exc):
            pass

    proto = TrackingProtocol()
    transport = StreamTransport(server_socket.fileno(), proto, loop)
    try:
        transport.write(b"hello")
        await asyncio.sleep(0.1)
        assert not resume_called_before_pause, (
            "resume_writing called before pause_writing "
            "- is_writing was not initialized to true"
        )

        transport.set_write_buffer_limits(high=10, low=5)
        transport.write(b"x" * 20)
        await asyncio.sleep(0.1)
        assert pause_called, (
            "pause_writing should be called when buffer exceeds high watermark"
        )
    finally:
        transport.close()
        client_socket.close()


def test_stream_transport_is_writing_initialized() -> None:
    talyn.run(_test_stream_transport_is_writing_initialized())
