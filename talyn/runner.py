from .loop import Loop

from typing import Any, Coroutine, TypeVar, Optional
import asyncio

_T = TypeVar("_T")


class Runner:
    def __init__(self, *, debug: bool | None = None,
                 loop_factory: type[asyncio.AbstractEventLoop] | None = None) -> None:
        self._loop = (loop_factory or Loop)()
        self._debug = debug
        self._closed = False

    def __enter__(self) -> "Runner":
        return self

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        self.close()

    def run(self, coro: Coroutine[Any, Any, _T], *, context: Any = None) -> _T:
        return self._loop.run_until_complete(
            asyncio.ensure_future(coro, loop=self._loop)
        )

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self._loop.run_until_complete(
                self._loop.shutdown_default_executor()
            )
        except RuntimeError:
            pass
        self._loop.close()


def run(coro_or_future: Coroutine[Any, Any, _T]) -> _T:
    return asyncio.run(coro_or_future, loop_factory=Loop)
