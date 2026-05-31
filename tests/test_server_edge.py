import asyncio

import pytest

from talyn import Loop
from talyn.server import Server


def test_server_attach_detach() -> None:
    loop = Loop()
    try:
        server = Server(loop, [])
        assert server._active_count == 0

        server._attach()
        assert server._active_count == 1

        server._detach()
        assert server._active_count == 0
    finally:
        loop.close()


def test_server_is_serving_no_servers() -> None:
    loop = Loop()
    try:
        server = Server(loop, None)
        assert not server.is_serving()
        assert server.sockets == []
    finally:
        loop.close()


def test_server_sockets_empty() -> None:
    loop = Loop()
    try:
        server = Server(loop, [])
        assert server.sockets == []
    finally:
        loop.close()


def test_server_close_idempotent() -> None:
    loop = Loop()
    try:
        server = Server(loop, [])
        server.close()
        server.close()
    finally:
        loop.close()


def test_server_wait_closed_already_closed() -> None:
    loop = Loop()
    try:
        server = Server(loop, None)
        loop.run_until_complete(server.wait_closed())
    finally:
        loop.close()


def test_server_serve_forever_cancelled() -> None:
    loop = Loop()
    try:
        server = Server(loop, [])
        async def test():
            task = asyncio.ensure_future(server.serve_forever())
            await asyncio.sleep(0.05)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
            assert server._servers is None

        loop.run_until_complete(test())
    finally:
        loop.close()


@pytest.mark.asyncio
async def test_server_async_context_manager() -> None:
    loop = Loop()
    try:
        server = Server(loop, [])
        async with server as s:
            assert s is server
        assert server._servers is None
    finally:
        loop.close()


def test_server_start_serving() -> None:
    loop = Loop()
    try:
        server = Server(loop, [])
        loop.run_until_complete(server.start_serving())
    finally:
        loop.close()


def test_server_get_loop() -> None:
    loop = Loop()
    try:
        server = Server(loop, [])
        assert server.get_loop() is loop
    finally:
        loop.close()


def test_server_wakeup() -> None:
    loop = Loop()
    try:
        server = Server(loop, [])
        waiter = loop.create_future()
        server._waiters.append(waiter)
        server._wakeup()
        assert waiter.done()
        assert waiter.result() is None
    finally:
        loop.close()


def test_server_wait_closed_with_active() -> None:
    loop = Loop()
    try:
        server = Server(loop, [])
        server._active_count = 1
        async def test():
            loop.call_soon(server._detach)
            await server.wait_closed()
        loop.run_until_complete(test())
    finally:
        loop.close()



