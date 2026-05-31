from .future import Future
from .loop import EventLoopPolicy, Loop
from .runner import Runner, run
from .talyn_zig import StreamTransport
from .task import Task

__all__ = ["Future", "Task", "Loop", "EventLoopPolicy", "run", "Runner", "StreamTransport"]


def install():
    import asyncio
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        asyncio.set_event_loop_policy(EventLoopPolicy())
    
    import sys
    is_ft = not sys._is_gil_enabled() if hasattr(sys, "_is_gil_enabled") else False
    if is_ft:
        import gc
        gc.disable()
