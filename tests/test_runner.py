import asyncio

from talyn.loop import Loop
from talyn.runner import run


def test_run() -> None:
    async def test_coro() -> tuple[str, bool]:
        return "test result", isinstance(asyncio.get_running_loop(), Loop)

    result = run(test_coro())

    assert isinstance(result, tuple)
    assert len(result) == 2

    assert result[0] == "test result"
    assert result[1]
