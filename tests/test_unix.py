import asyncio
import os

import pytest

import talyn


def _unix_path() -> str:
    return f"/tmp/talyn_test_{os.getpid()}.sock"


class EchoProtocol(asyncio.Protocol):
    def connection_made(self, transport: asyncio.Transport) -> None:
        self.transport = transport

    def data_received(self, data: bytes) -> None:
        self.transport.write(data)

    def connection_lost(self, exc: BaseException | None) -> None:
        pass


class ClientProtocol(asyncio.Protocol):
    def __init__(self) -> None:
        self.received = asyncio.get_running_loop().create_future()

    def connection_made(self, transport: asyncio.Transport) -> None:
        self.transport = transport

    def data_received(self, data: bytes) -> None:
        self.received.set_result(data)

    def connection_lost(self, exc: BaseException | None) -> None:
        pass


# --- create_unix_connection ---


def test_create_unix_connection() -> None:
    path = _unix_path()
    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()
            # Start a server first
            server = await loop.create_unix_server(EchoProtocol, path)
            transport, protocol = await loop.create_unix_connection(
                ClientProtocol, path
            )
            transport.write(b"hello")
            data = await protocol.received
            assert data == b"hello"
            transport.close()
            server.close()

        talyn.run(main())
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def test_create_unix_server() -> None:
    path = _unix_path()
    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()
            server = await loop.create_unix_server(EchoProtocol, path)
            assert server.is_serving()
            server.close()
            await server.wait_closed()

        talyn.run(main())
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def test_create_unix_server_sockets() -> None:
    path = _unix_path()
    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()
            server = await loop.create_unix_server(EchoProtocol, path)
            sockets = server.sockets
            assert len(sockets) >= 1
            server.close()

        talyn.run(main())
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def test_create_unix_connection_invalid_path() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises(OSError):
            await loop.create_unix_connection(
                EchoProtocol, "/tmp/nonexistent_path_xyz.sock"
            )

    talyn.run(main())


def test_create_unix_server_missing_args() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises((ValueError, TypeError)):
            await loop.create_unix_server(EchoProtocol)

    talyn.run(main())


def test_create_unix_connection_multiple() -> None:
    path = _unix_path()
    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()
            server = await loop.create_unix_server(EchoProtocol, path)
            for i in range(3):
                t, p = await loop.create_unix_connection(ClientProtocol, path)
                msg = f"msg{i}".encode()
                t.write(msg)
                data = await p.received
                assert data == msg
                t.close()
            server.close()

        talyn.run(main())
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def test_abstract_unix_socket_peername():
    """BUG-287: abstract-namespace sockets (leading NUL, length via
    addrlen) must report their full name instead of an empty string, and
    fully-filled paths must not read past the buffer."""
    import asyncio
    import socket

    async def main():
        loop = asyncio.get_running_loop()

        name = "\0talyn_bug287_probe"
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(name)
        srv.listen(1)

        class Proto(asyncio.Protocol):
            pass

        reader_proto = asyncio.Protocol
        t, p = await loop.create_unix_connection(Proto, path=name)
        try:
            sockname = t.get_extra_info("peername")
            assert isinstance(sockname, str)
            assert sockname.startswith("\x00"), f"abstract name lost: {sockname!r}"
            assert "talyn_bug287_probe" in sockname
        finally:
            t.close()
            srv.close()

    talyn.run(main())
