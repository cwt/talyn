import asyncio
import logging
import weakref
from typing import Any

logger = logging.getLogger(__name__)


class Server:
    """An asyncio.Server-compatible wrapper for talyn stream servers."""

    def __init__(
        self,
        loop: asyncio.AbstractEventLoop,
        servers: list[Any],
        start_serving: bool = True,
    ) -> None:
        self._loop = loop
        self._servers = servers
        self._serving = start_serving
        self._active_count = 0
        self._clients: set[Any] = set()
        self._waiters: list[asyncio.Future[None]] = []
        # BUG-376: every underlying StreamServer must know its Python-level
        # wrapper (through a weakref — a strong ref here would form a
        # Server -> _servers -> server_ref -> Server cycle) so accepted
        # connections call _attach() and _detach() on us. Without this,
        # _active_count stayed 0 for every TCP and SSL server and
        # Server.wait_closed() resolved immediately while client
        # connections were still active.
        for srv in servers or []:
            srv.set_server_ref(weakref.ref(self))

    def _attach(self, transport: Any = None) -> None:
        self._active_count += 1
        if transport is not None:
            self._clients.add(transport)

    def _detach(self, transport: Any = None) -> None:
        self._active_count -= 1
        if transport is not None:
            self._clients.discard(transport)
        if self._active_count <= 0 and (self._servers is None or not self.is_serving()):
            self._wakeup()

    def close_clients(self) -> None:
        for transport in list(self._clients):
            try:
                transport.close()
            except Exception:
                logger.debug("exception in close_clients", exc_info=True)

    def abort_clients(self) -> None:
        for transport in list(self._clients):
            try:
                transport.abort()
            except Exception:
                logger.debug("exception in abort_clients", exc_info=True)

    def _wakeup(self) -> None:
        for waiter in self._waiters:
            if not waiter.done():
                waiter.set_result(None)
        self._waiters.clear()

    def close(self) -> None:
        if self._servers is None:
            return
        self._serving = False
        servers = self._servers
        self._servers = None
        for srv in servers:
            srv.close()
        if self._active_count <= 0:
            self._wakeup()

    def is_serving(self) -> bool:
        return self._serving and self._servers is not None and len(self._servers) > 0

    async def wait_closed(self) -> None:
        if self._servers is None and self._active_count <= 0:
            return
        waiter: asyncio.Future[None] = self._loop.create_future()
        self._waiters.append(waiter)
        await waiter

    async def start_serving(self) -> None:
        if self._servers is None:
            return
        self._serving = True
        for srv in self._servers:
            if hasattr(srv, "start_serving"):
                srv.start_serving()

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
