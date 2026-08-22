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
