from .future import Future
from .loop import EventLoopPolicy, Loop
from .runner import Runner, run
from .talyn_zig import StreamTransport
from .task import Task

__all__ = [
    "Future",
    "Task",
    "Loop",
    "EventLoopPolicy",
    "run",
    "Runner",
    "StreamTransport",
]


def install():
    import asyncio
    import warnings
    import os
    import re

    # HARD-01: Minimum Kernel Version Guard pre-flight check
    if os.name == 'posix':
        try:
            release = os.uname().release
            match = re.match(r'^(\d+)\.(\d+)', release)
            if match:
                major, minor = map(int, match.groups())
                if major < 6:
                    raise RuntimeError("Talyn requires Linux kernel 6.0 or newer (found older version).")
        except (AttributeError, ValueError):
            # AttributeError can occur if uname() or release is missing; ValueError if parsing fails.
            # It is safe to ignore these here because a strict native validation check is still
            # performed inside the native library (IO.init) during loop initialization.
            pass

    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        asyncio.set_event_loop_policy(EventLoopPolicy())

    import sys

    is_ft = not sys._is_gil_enabled() if hasattr(sys, "_is_gil_enabled") else False
    if is_ft:
        import gc

        gc.disable()
