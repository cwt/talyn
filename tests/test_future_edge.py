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


def test_future_callbacks_after_loop_close_raises_runtime_error() -> None:
    """BUG-340: resolving/cancelling a Future with done callbacks or adding a
    done callback to a completed Future after loop.close() must raise
    RuntimeError('Event loop is closed') instead of dereferencing freed
    ready_tasks_queues."""
    import pytest

    def noop(_fut) -> None:
        pass

    loop = Loop()
    fut_with_cb = loop.create_future()
    fut_with_cb.add_done_callback(noop)

    done_fut = loop.create_future()
    done_fut.set_result(42)

    loop.close()

    with pytest.raises(RuntimeError, match="closed"):
        fut_with_cb.set_result(1)

    with pytest.raises(RuntimeError, match="closed"):
        done_fut.add_done_callback(noop)


def test_future_callback_exceptions_gc_traverse_and_release() -> None:
    """BUG-341: after Future done callbacks raise exceptions, exceptions_queue
    must be cleared so subsequent GC traversal (future_traverse) does not
    visit stale/freed pointers and no exception references leak."""
    import gc
    import sys

    exc = ValueError("callback-boom")
    initial_refcnt = sys.getrefcount(exc)

    loop = Loop()
    try:
        exceptions_caught = []

        def handler(_loop, context) -> None:
            exceptions_caught.append(context.get("exception"))

        loop.set_exception_handler(handler)

        fut = loop.create_future()

        def bad_cb(_f) -> None:
            raise exc

        fut.add_done_callback(bad_cb)
        fut.set_result("ok")

        async def tick() -> None:
            pass

        loop.run_until_complete(tick())
        assert len(exceptions_caught) == 1

        # Trigger GC while `fut` is still alive and tracked by GC
        gc.collect()
    finally:
        del fut
        del exceptions_caught
        loop.close()
        del loop

    exc.__traceback__ = None
    gc.collect()
    assert sys.getrefcount(exc) == initial_refcnt


