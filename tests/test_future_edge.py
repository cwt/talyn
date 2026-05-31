

from talyn import Future, Loop


def test_future_without_loop_inside_running_loop() -> None:
    loop = Loop()
    try:
        async def test():
            fut = Future()
            assert isinstance(fut.get_loop(), Loop)
            return True

        assert loop.run_until_complete(test())
    finally:
        loop.close()
