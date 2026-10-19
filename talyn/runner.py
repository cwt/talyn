import asyncio
from logging import getLogger
from typing import Any, Coroutine, TypeVar

from .loop import Loop

logger = getLogger(__package__)

_T = TypeVar("_T")


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

    def run(self, coro: Coroutine[Any, Any, _T], *, context: Any = None) -> _T:
        return self._loop.run_until_complete(
            self._loop.create_task(coro, context=context)
        )

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        loop = self._loop
        if loop is not None and not loop.is_closed():
            try:
                to_cancel = asyncio.all_tasks(loop)
                if to_cancel:
                    for task in to_cancel:
                        task.cancel()

                    async def wait_cancelled() -> None:
                        await asyncio.gather(*to_cancel, return_exceptions=True)

                    loop.run_until_complete(wait_cancelled())
                loop.run_until_complete(loop.shutdown_asyncgens())
                loop.run_until_complete(loop.shutdown_default_executor())
            except BaseException:
                logger.exception("Runner.close: teardown failed")
            finally:
                loop.close()


def run(coro_or_future: Coroutine[Any, Any, _T]) -> _T:
    return asyncio.run(coro_or_future, loop_factory=Loop)
