import asyncio
from typing import Any


class Server:
    """An asyncio.Server-compatible wrapper for talyn stream servers."""

    def __init__(self, loop: asyncio.AbstractEventLoop, servers: list[Any]) -> None:
        self._loop = loop
        self._servers = servers
        self._active_count = 0
        self._waiters: list[asyncio.Future[None]] = []

    def _attach(self) -> None:
        self._active_count += 1

    def _detach(self) -> None:
        self._active_count -= 1
        if self._active_count == 0 and self._servers is not None:
            self._wakeup()

    def _wakeup(self) -> None:
        for waiter in self._waiters:
            if not waiter.done():
                waiter.set_result(None)
        self._waiters.clear()

    def close(self) -> None:
        if self._servers is None:
            return
        servers = self._servers
        self._servers = None
        for srv in servers:
            srv.close()
        self._active_count = 0
        self._wakeup()

    def is_serving(self) -> bool:
        return self._servers is not None and len(self._servers) > 0

    async def wait_closed(self) -> None:
        if self._servers is None and self._active_count == 0:
            return
        waiter: asyncio.Future[None] = self._loop.create_future()
        self._waiters.append(waiter)
        await waiter

    async def start_serving(self) -> None:
        pass

    async def serve_forever(self) -> None:
        if self._servers is None:
            return
        try:
            await self._loop.create_future()
        except asyncio.CancelledError:
            self.close()
            raise

    def get_loop(self) -> asyncio.AbstractEventLoop:
        return self._loop

    @property
    def sockets(self) -> list[Any]:
        if self._servers is None:
            return []
        result = []
        for srv in self._servers:
            result.append(srv._get_socket())
        return result

    async def __aenter__(self) -> "Server":
        return self

    async def __aexit__(self, *args: Any, **kwargs: Any) -> None:
        self.close()
        await self.wait_closed()
