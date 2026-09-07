import asyncio
import socket

import pytest

import talyn


class EchoProtocol(asyncio.Protocol):
    def connection_made(self, transport: asyncio.Transport) -> None:
        self.transport = transport

    def data_received(self, data: bytes) -> None:
        self.transport.write(data)

    def connection_lost(self, exc: BaseException | None) -> None:
        pass


def test_create_server_basic() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        server = await loop.create_server(EchoProtocol, "127.0.0.1", 0)
        assert server.is_serving()
        sock = server.sockets[0]
        port = sock.getsockname()[1]
        assert port > 0
        server.close()
        await server.wait_closed()

    talyn.run(main())


def test_create_server_bind_any() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        server = await loop.create_server(EchoProtocol, "0.0.0.0", 0)
        assert server.is_serving()
        server.close()

    talyn.run(main())


def test_create_server_close() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        server = await loop.create_server(EchoProtocol, "127.0.0.1", 0)
        server.close()
        assert not server.is_serving()

    talyn.run(main())


def test_create_server_sockets_property() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        server = await loop.create_server(EchoProtocol, "127.0.0.1", 0)
        sockets = server.sockets
        assert len(sockets) == 1
        assert isinstance(sockets[0], socket.socket)
        server.close()

    talyn.run(main())


def test_create_server_invalid_protocol_factory() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises((TypeError, ValueError)):
            await loop.create_server(None, "127.0.0.1", 0)

    talyn.run(main())


def test_create_server_get_loop() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        server = await loop.create_server(EchoProtocol, "127.0.0.1", 0)
        assert server.get_loop() is loop
        server.close()

    talyn.run(main())


def test_create_server_localhost() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        server = await loop.create_server(EchoProtocol, "localhost", 0)
        assert server.is_serving()
        sock = server.sockets[0]
        port = sock.getsockname()[1]
        assert port > 0
        server.close()
        await server.wait_closed()

    talyn.run(main())


def test_create_server_localhost_echo() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        server = await loop.create_server(EchoProtocol, "localhost", 0)
        sock = server.sockets[0]
        port = sock.getsockname()[1]

        reader, writer = await asyncio.open_connection("localhost", port)
        writer.write(b"hello from localhost")
        await writer.drain()
        data = await reader.read(100)
        assert data == b"hello from localhost"
        writer.close()
        await writer.wait_closed()

        server.close()
        await server.wait_closed()

    talyn.run(main())


def test_create_server_bind_all_interfaces() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        server = await loop.create_server(EchoProtocol, None, 0)
        assert server.is_serving()
        assert len(server.sockets) >= 1
        for s in server.sockets:
            name = s.getsockname()
            assert name[0] in ("0.0.0.0", "::"), f"unexpected addr: {name}"
        server.close()
        await server.wait_closed()

    talyn.run(main())


def test_create_server_unresolvable_host() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises(RuntimeError):
            await loop.create_server(EchoProtocol, "invalid--domain", 0)

    talyn.run(main())


def test_create_server_invalid_dns_timeout() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises(TypeError):
            await loop.create_server(EchoProtocol, "127.0.0.1", 0, dns_timeout="invalid")
        with pytest.raises(ValueError):
            await loop.create_server(EchoProtocol, "127.0.0.1", 0, dns_timeout=-1.0)

    talyn.run(main())



def test_create_server_fd_hygiene_across_cycles() -> None:
    """BUG-308 companion: server socket ownership must be exactly-once -
    no leaked listening fds across repeated create/close cycles (a
    double-close or missed transfer shows up as fd-count drift)."""
    import os

    def open_fd_count() -> int:
        return len(os.listdir("/proc/self/fd"))

    async def main() -> None:
        loop = asyncio.get_running_loop()

        # Warm-up cycle: lazy allocations (DNS caches, socket module imports)
        # settle here so the baseline is stable.
        warm = await loop.create_server(EchoProtocol, "127.0.0.1", 0)
        warm.close()
        await warm.wait_closed()
        baseline = open_fd_count()

        for _ in range(8):
            server = await loop.create_server(EchoProtocol, "127.0.0.1", 0)
            server.close()
            await server.wait_closed()

        assert open_fd_count() == baseline

    talyn.run(main())


def test_create_server_sock_malformed_ipv4_rejected() -> None:
    """BUG-318: a sock= whose getsockname returns a short dotted-quad (or
    more than 4 octets) must be rejected instead of binding to a
    non-deterministic address built from uninitialized stack bytes."""

    class FakeSock:
        family = socket.AF_INET

        def __init__(self, real: socket.socket, host: str) -> None:
            self._real = real
            self._host = host

        def fileno(self) -> int:
            return self._real.fileno()

        def getsockname(self) -> tuple[str, int]:
            return (self._host, self._real.getsockname()[1])

    async def main() -> None:
        loop = asyncio.get_running_loop()
        real = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        real.bind(("127.0.0.1", 0))
        try:
            for bad_host in ("127.1", "10.0.1", "1", "1.2.3.4.5", "a.b.c.d", ""):
                with pytest.raises(Exception):
                    await loop.create_server(EchoProtocol, sock=FakeSock(real, bad_host))
        finally:
            real.close()

    talyn.run(main())
