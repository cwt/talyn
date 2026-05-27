from talyn import Loop, Runner

import pytest, asyncio


def test_runner_context_manager() -> None:
    async def coro():
        return "ok"

    with Runner() as runner:
        result = runner.run(coro())
        assert result == "ok"


def test_runner_double_close() -> None:
    runner = Runner()
    runner.close()
    runner.close()


def test_runner_with_loop_factory() -> None:
    class CustomLoop(Loop):
        pass

    runner = Runner(loop_factory=CustomLoop)
    try:
        assert isinstance(runner._loop, CustomLoop)
    finally:
        runner.close()


def test_runner_run_returns_result() -> None:
    async def coro():
        return 42

    runner = Runner()
    try:
        result = runner.run(coro())
        assert result == 42
    finally:
        runner.close()


def test_runner_close_closed_loop() -> None:
    import warnings
    runner = Runner()
    runner._loop.close()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        runner.close()
