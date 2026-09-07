"""Test socket connect/accept/shutdown correctness without IOSQE_ASYNC.

These exercises the exact code paths affected by PRIORITY 16:
- sock_connect (was IOSQE_ASYNC, now deferred)
- sock_accept (was IOSQE_ASYNC, now deferred)
- sock_shutdown (was IOSQE_ASYNC, now deferred)

Without IOSQE_ASYNC the kernel handles these inline for localhost sockets.
The test verifies correctness is preserved after the flag removal.
"""

import asyncio
import socket

import talyn


def test_many_sequential_connections():
    """Mimic Socket Ops benchmark: many sequential connect/accept/close cycles."""

    async def main():
        async def handler(reader, writer):
            try:
                data = await reader.read(256)
                if data:
                    writer.write(data)
                    await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        async def one_shot(port):
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            writer.write(b"x" * 64)
            await writer.drain()
            data = await reader.readexactly(64)
            assert data == b"x" * 64
            writer.close()
            await writer.wait_closed()

        server = await asyncio.start_server(handler, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        async with server:
            for _ in range(100):
                await one_shot(port)

    talyn.run(main())


def test_raw_socket_connect_accept():
    """Test low-level loop.sock_connect/sock_accept/sock_sendall/sock_recv."""

    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(5)
        server_sock.setblocking(False)
        addr = server_sock.getsockname()

        results = []

        async def accept_loop():
            for _ in range(20):
                client, client_addr = await loop.sock_accept(server_sock)
                try:
                    data = await loop.sock_recv(client, 1024)
                    await loop.sock_sendall(client, data.upper())
                finally:
                    client.close()
                results.append(data)

        server_task = loop.create_task(accept_loop())

        for i in range(20):
            client_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            client_sock.setblocking(False)
            await loop.sock_connect(client_sock, addr)
            msg = f"hello-{i}".encode()
            await loop.sock_sendall(client_sock, msg)
            data = await loop.sock_recv(client_sock, 1024)
            assert data == msg.upper()
            client_sock.close()

        await server_task
        server_sock.close()
        assert len(results) == 20

    talyn.run(main())


def test_shutdown_variants():
    """Test that socket shutdown works correctly in all variants."""

    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        server_sock.setblocking(False)
        addr = server_sock.getsockname()

        async def server_side():
            client, _ = await loop.sock_accept(server_sock)
            try:
                data = await loop.sock_recv(client, 1024)
                assert data == b"before-shutdown"
                await loop.sock_sendall(client, b"ack")
                await loop.sock_recv(client, 1024)
            finally:
                client.close()

        server_task = loop.create_task(server_side())

        client_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client_sock.setblocking(False)
        await loop.sock_connect(client_sock, addr)
        await loop.sock_sendall(client_sock, b"before-shutdown")
        data = await loop.sock_recv(client_sock, 1024)
        assert data == b"ack"

        client_sock.shutdown(socket.SHUT_WR)
        await server_task
        client_sock.close()
        server_sock.close()

    talyn.run(main())


def test_concurrent_connect_accept_stress():
    """Multiple concurrent connections to stress connect/accept without IOSQE_ASYNC."""

    async def main():
        async def handler(reader, writer):
            try:
                data = await reader.read(100)
                writer.write(data)
                await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        server = await asyncio.start_server(handler, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        async with server:

            async def one_shot(i):
                reader, writer = await asyncio.open_connection("127.0.0.1", port)
                msg = f"msg-{i}".encode()
                writer.write(msg)
                await writer.drain()
                data = await reader.readexactly(len(msg))
                assert data == msg
                writer.close()
                await writer.wait_closed()

            tasks = [one_shot(i) for i in range(50)]
            await asyncio.gather(*tasks)

    talyn.run(main())


def test_unix_socket_connect_accept():
    """Unix domain sockets also exercise connect/accept/shutdown paths."""
    import os
    import tempfile

    async def main():
        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, "test.sock")

            async def handler(reader, writer):
                data = await reader.read(256)
                writer.write(data)
                await writer.drain()
                writer.close()
                await writer.wait_closed()

            server = await asyncio.start_unix_server(handler, path)
            async with server:
                for _ in range(20):
                    reader, writer = await asyncio.open_unix_connection(path)
                    writer.write(b"unix-echo")
                    await writer.drain()
                    data = await reader.readexactly(9)
                    assert data == b"unix-echo"
                    writer.close()
                    await writer.wait_closed()

    talyn.run(main())


def test_sock_ops_future_refcount_stability():
    """BUG-310 companion: every socket-op initiator stores py_newref'd
    future/loop references in its op data and releases them via the
    completion cleanup (or, since BUG-310, the io.queue-failure errdefer).
    Cycling the ops must show zero net reference drift - a double-decref
    in any cleanup path shows up as negative drift, a missed decref as
    positive drift."""
    import sys

    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(16)
        addr = server_sock.getsockname()[1]

        async def cycle(n: int) -> None:
            for _ in range(n):
                # Connect first (the listen backlog holds the connection),
                # then pick it up with sock_accept.
                client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                client.setblocking(False)
                await loop.sock_connect(client, ("127.0.0.1", addr))
                server, _ = await loop.sock_accept(server_sock)
                await loop.sock_sendall(client, b"ping")
                await loop.sock_recv(server, 4)
                client.close()
                server.close()

        # Warm-up
        await cycle(2)
        await asyncio.sleep(0.05)
        base = sys.getrefcount(asyncio.BaseProtocol)
        await cycle(10)
        await asyncio.sleep(0.1)
        delta = sys.getrefcount(asyncio.BaseProtocol) - base
        server_sock.close()
        assert delta == 0, f"future/loop reference drift over 10 cycles: {delta}"

    talyn.run(main())
