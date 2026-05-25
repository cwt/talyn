from .future import Future
from .task import Task
from .loop import Loop, EventLoopPolicy
from .runner import run, Runner

from .leviathan_zig import StreamTransport

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
