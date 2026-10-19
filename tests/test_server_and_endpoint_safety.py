import asyncio
import gc
import socket
import tempfile
import weakref

import pytest

import talyn


class SimpleEchoProtocol(asyncio.Protocol):
    def connection_made(self, transport: asyncio.Transport) -> None:
        self.transport = transport

    def data_received(self, data: bytes) -> None:
        self.transport.write(data)

    def connection_lost(self, exc: BaseException) -> None:
        pass


class SimpleDatagramProtocol(asyncio.DatagramProtocol):
    def connection_made(self, transport: asyncio.DatagramTransport) -> None:
        self.transport = transport

    def datagram_received(self, data: bytes, addr: tuple) -> None:
        self.transport.sendto(data, addr)

    def error_received(self, exc: BaseException) -> None:
        pass

    def connection_lost(self, exc: BaseException) -> None:
        pass


def test_create_server_with_sock_kwarg_only() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server = await loop.create_server(SimpleEchoProtocol, sock=server_sock)
        try:
            assert server.is_serving()
            sockets = server.sockets
            assert len(sockets) == 1
        finally:
            server.close()
            await server.wait_closed()
            server_sock.close()

    talyn.run(main())


def test_create_datagram_endpoint_with_sock_kwarg() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        dgram_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        dgram_sock.bind(("127.0.0.1", 0))
        transport, protocol = await loop.create_datagram_endpoint(
            SimpleDatagramProtocol,
            sock=dgram_sock,
        )
        try:
            assert transport is not None
            assert protocol is not None
        finally:
            transport.close()
            dgram_sock.close()

    talyn.run(main())


def test_unix_server_abstract_namespace_cleanup() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        abstract_path = "\0talyn_test_abstract_socket_12345"
        server = await loop.create_unix_server(
            SimpleEchoProtocol,
            path=abstract_path,
        )
        try:
            assert server.is_serving()
        finally:
            server.close()
            await server.wait_closed()

    talyn.run(main())


def test_task_factory_two_args_fallback() -> None:
    calls = []

    def legacy_factory(target_loop, coro):
        calls.append((target_loop, coro))
        return asyncio.Task(coro, loop=target_loop)

    async def main() -> None:
        loop = asyncio.get_running_loop()
        loop.set_task_factory(legacy_factory)
        try:
            async def sample_coro() -> int:
                return 42

            task = loop.create_task(sample_coro())
            result = await task
            assert result == 42
            assert len(calls) == 1
        finally:
            loop.set_task_factory(None)

    talyn.run(main())


def test_set_exception_handler_validation() -> None:
    loop = talyn.Loop()
    try:
        with pytest.raises(TypeError):
            loop.set_exception_handler("not_callable_handler")

        with pytest.raises(TypeError):
            loop.set_exception_handler(12345)

        def dummy_handler(target_loop, context):
            pass

        loop.set_exception_handler(dummy_handler)
        loop.set_exception_handler(None)
    finally:
        loop.close()


def test_add_hook_validation() -> None:
    loop = talyn.Loop()
    try:
        with pytest.raises(TypeError):
            loop._add_hook(0, "not_callable")

        with pytest.raises(TypeError):
            loop._add_hook(0, 12345)
    finally:
        loop.close()


def test_loop_weakref_cleanup() -> None:
    loop = talyn.Loop()
    weak_loop = weakref.ref(loop)
    assert weak_loop() is loop
    loop.close()
    del loop
    gc.collect()
    assert weak_loop() is None
