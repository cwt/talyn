import pytest

from talyn import Loop, Task


def test_task_eager_start_raises() -> None:
    loop = Loop()

    async def dummy():
        pass

    coro = dummy()
    try:
        with pytest.raises(RuntimeError, match="eager_start"):
            Task(coro, loop=loop, eager_start=True)
    finally:
        coro.close()
        loop.close()


def test_task_without_loop_inside_running_loop() -> None:
    loop = Loop()
    try:

        async def test():
            async def dummy():
                pass

            coro2 = dummy()
            task = Task(coro2)
            assert isinstance(task.get_loop(), Loop)
            coro2.close()
            return True

        assert loop.run_until_complete(test())
    finally:
        loop.close()


def test_task_bad_yield_exception_refcount() -> None:
    import gc

    loop = Loop()
    try:
        class BadYieldObj:
            _asyncio_future_blocking = 123

        class BadAwaitable:
            def __await__(self):
                yield BadYieldObj()

        async def bad_coro():
            await BadAwaitable()

        task = Task(bad_coro(), loop=loop)
        with pytest.raises(RuntimeError, match="got bad yield"):
            loop.run_until_complete(task)

        gc.collect()
    finally:
        loop.close()


def test_task_failed_execution_exception_refcount() -> None:
    import gc
    import sys

    exc = ValueError("test_error_refcount")
    initial_refcnt = sys.getrefcount(exc)

    loop = Loop()
    try:
        async def failing():
            raise exc

        task = Task(failing(), loop=loop)
        with pytest.raises(ValueError):
            loop.run_until_complete(task)
    finally:
        del task
        loop.close()
        del loop

    exc.__traceback__ = None
    gc.collect()
    assert sys.getrefcount(exc) == initial_refcnt





@pytest.mark.parametrize("exc_cls", [SystemExit, KeyboardInterrupt])
def test_task_failed_execution_fatal_exception_not_freed(exc_cls) -> None:
    """BUG-271: the fatal-signal branch of failed_execution used to decref
    the raised exception twice (manual + errdefer), freeing the object while
    it was installed as the thread state's current exception."""
    import gc
    import sys

    exc = exc_cls("fatal_probe")

    loop = Loop()
    try:
        async def failing():
            raise exc

        task = Task(failing(), loop=loop)
        with pytest.raises(exc_cls):
            loop.run_until_complete(task)
    finally:
        del task
        loop.close()
        del loop

    # The instance must have survived: pre-fix it could be freed while it
    # was installed as the thread state's raised exception.
    assert str(exc) == "fatal_probe"
    assert type(exc) is exc_cls
    gc.collect()


def test_task_cancellederror_completes_without_leak() -> None:
    """BUG-292: every exit path of failed_execution releases the owned
    exception exactly once via a single scope-exit defer; the cancelled
    arm must finalize cleanly and leave the loop operational."""
    import asyncio

    from talyn import loop as talyn_loop

    async def main():
        loop = asyncio.get_running_loop()

        async def raises_cancelled():
            raise asyncio.CancelledError()

        t1 = loop.create_task(raises_cancelled())
        with pytest.raises(asyncio.CancelledError):
            await t1

        # The loop must remain fully operational afterwards.
        t2 = loop.create_task(asyncio.sleep(0))
        await t2
        assert t2.done()

    talyn = talyn_loop.Loop()
    try:
        talyn.run_until_complete(main())
    finally:
        talyn.close()


def test_repeated_failing_tasks_keep_loop_healthy() -> None:
    """BUG-273/BUG-293 stress: many sequential task failures exercise the
    execute_task_send/throw error unwinding and the enter/leave-task
    trampolines; the loop must stay fully operational throughout."""
    loop = Loop()
    try:
        for i in range(200):
            async def boom(idx=i):
                raise ValueError(f"boom {idx}")

            task = Task(boom(), loop=loop)
            with pytest.raises(ValueError, match=f"boom {i}"):
                loop.run_until_complete(task)

        async def ok():
            return 7

        assert loop.run_until_complete(Task(ok(), loop=loop)) == 7
    finally:
        loop.close()


def test_create_task_on_closed_loop_raises_runtimeerror() -> None:
    """BUG-303: scheduling a task onto an already-closed loop must raise
    RuntimeError('Event loop is closed') instead of pushing the start
    callback into a deinitialized ready ring (segfault). Mirrors CPython
    test_base_events.test_create_task_error_closes_coro."""
    import asyncio

    loop = Loop()
    loop.close()

    async def dummy():
        pass

    coro = dummy()
    try:
        with pytest.raises(RuntimeError, match="closed"):
            loop.create_task(coro)
    finally:
        coro.close()


def test_failed_tasks_leave_asyncio_tasks_set():
    """BUG-279: tasks completing by exception or cancellation must be
    discarded from the loop's _asyncio_tasks set (a STRONG reference);
    previously only completion-by-result removed them, pinning every
    failed/cancelled task until loop close."""
    import asyncio

    from talyn import loop as talyn_loop

    async def main():
        loop = asyncio.get_running_loop()

        async def boom():
            raise ValueError("gone")

        t1 = loop.create_task(boom())
        with pytest.raises(ValueError):
            await t1

        async def cancelled_sleep():
            await asyncio.sleep(30)

        t2 = loop.create_task(cancelled_sleep())
        t2.cancel()
        with pytest.raises(asyncio.CancelledError):
            await t2

        tasks_set = getattr(loop, "_asyncio_tasks", None)
        if tasks_set is not None:
            assert t1 not in tasks_set
            assert t2 not in tasks_set

        gc.collect()

        # Loop stays healthy and registry does not accumulate.
        async def ok():
            return 5

        assert await loop.create_task(ok()) == 5

    import gc

    talyn = talyn_loop.Loop()
    try:
        talyn.run_until_complete(main())
    finally:
        talyn.close()
