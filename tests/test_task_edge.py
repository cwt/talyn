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



