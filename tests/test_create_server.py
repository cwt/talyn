from talyn import Loop
import talyn

import asyncio, socket, pytest
from typing import Any


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
