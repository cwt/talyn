
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
