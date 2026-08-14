import asyncio
from typing import Any, Coroutine, Generic, TypeVar

from .talyn_zig import Task as _Task

_T = TypeVar("_T")


class Task(_Task, Generic[_T]):
    def __init__(
        self,
        coro: Coroutine[Any, Any, _T],
        *,
        loop: asyncio.AbstractEventLoop | None = None,
        name: Any | None = None,
        context: Any | None = None,
        eager_start: bool = False,
    ) -> None:
        if eager_start:
            raise RuntimeError("eager_start is not supported")

        if loop is None:
            loop = asyncio.get_running_loop()

        _Task.__init__(self, coro, loop, name=name, context=context)
