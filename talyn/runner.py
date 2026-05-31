import asyncio
from typing import Any, Coroutine

from .loop import Loop


class Runner:
    def __init__(
        self,
        *,
        debug: bool | None = None,
        loop_factory: type[asyncio.AbstractEventLoop] | None = None,
    ) -> None:
        self._loop = (loop_factory or Loop)()
        self._debug = debug
        self._closed = False

    def __enter__(self) -> "Runner":
        return self

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        self.close()

    def run[T](self, coro: Coroutine[Any, Any, T], *, context: Any = None) -> T:
        return self._loop.run_until_complete(
            asyncio.ensure_future(coro, loop=self._loop)
        )

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self._loop.run_until_complete(self._loop.shutdown_default_executor())
        except RuntimeError:
            pass
        self._loop.close()


def run[T](coro_or_future: Coroutine[Any, Any, T]) -> T:
    return asyncio.run(coro_or_future, loop_factory=Loop)
