import asyncio
from typing import Any, Coroutine

from .talyn_zig import Task as _Task


class Task[T](_Task):
    def __init__(self, coro: Coroutine[Any, Any, T], *, loop: asyncio.AbstractEventLoop | None = None,
                 name: Any | None = None, context: Any | None = None, eager_start: bool = False) -> None:
        if eager_start:
            raise RuntimeError("eager_start is not supported")

        if loop is None:
            loop = asyncio.get_running_loop()

        _Task.__init__(self, coro, loop, name=name, context=context)

