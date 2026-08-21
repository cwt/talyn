"""Regression tests for BUG-267: run_forever from a non-creator thread.

io_uring rings created with COOP_TASKRUN/SINGLE_ISSUER are bound to the
thread that created them; polling from a foreign thread used to fail with
EEXIST → error.InvalidThread → RuntimeError in the run_forever thread,
leaving callers blocked forever on run_coroutine_threadsafe().result().

The fix hands a never-used ring over to the thread that actually runs the
loop (asyncio's documented "loop in a background thread" pattern), and
raises a clear RuntimeError if the loop already performed I/O elsewhere.

Note: these tests use talyn.Loop() directly (pytest does not install talyn
globally), so new_event_loop() would return a stdlib loop.
"""

from __future__ import annotations

import asyncio
import threading

import talyn


def _run_loop_in_thread(loop: talyn.Loop) -> tuple[threading.Thread, list[BaseException]]:
    errors: list[BaseException] = []

    def runner() -> None:
        try:
            loop.run_forever()
        except BaseException as exc:  # capture cross-thread exceptions
            errors.append(exc)

    thread = threading.Thread(target=runner)
    thread.start()
    return thread, errors


def test_run_forever_in_background_thread() -> None:
    """A freshly-created loop must be runnable from a different thread."""

    async def coro(value: int) -> int:
        await asyncio.sleep(0)
        return value

    loop = talyn.Loop()
    thread, errors = _run_loop_in_thread(loop)
    try:
        future = asyncio.run_coroutine_threadsafe(coro(42), loop)
        assert future.result(timeout=10) == 42
        assert not errors, f"run_forever thread raised: {errors!r}"
    finally:
        loop.call_soon_threadsafe(loop.stop)
        thread.join(timeout=10)
        assert not thread.is_alive()
        loop.close()


def test_loop_rerun_in_different_thread_raises_clear_error() -> None:
    """Once the loop has performed I/O in one thread, re-running it in a
    different thread must raise a clear RuntimeError instead of dying
    inside the io_uring poll path (which would leave callers hanging)."""

    async def do_work() -> None:
        await asyncio.sleep(0)

    loop = talyn.Loop()
    try:
        # First run in the creating (main) thread: submits operations.
        loop.run_until_complete(do_work())

        thread, errors = _run_loop_in_thread(loop)
        thread.join(timeout=10)
        assert not thread.is_alive()
        assert errors and len(errors) == 1, f"expected exactly one exception, got {errors!r}"
        assert isinstance(errors[0], RuntimeError)
        assert "another thread" in str(errors[0])

        # The loop remains usable in its original thread.
        assert loop.run_until_complete(do_work()) is None
    finally:
        loop.close()
