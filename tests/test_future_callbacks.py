"""BUG-370 regression tests.

``Future.remove_done_callback`` compared callbacks by pointer identity
(``@intFromPtr``). Every bound-method attribute access wraps a NEW
``PyMethodObject``, so ``fut.remove_done_callback(obj.method)`` never
matched and always returned 0 — Talyn's own
``Loop.run_until_complete`` relies on removing
``add_done_callback(self.__run_until_complete_cb)`` in its finally
block, so the stale callback fired on later completions and stopped
the loop prematurely. Additionally the removed entry kept strong
references to the callback (and its context) until the Future was
torn down, so long-lived futures with add/remove churn grew without
bound.
"""

import gc
import weakref

import talyn


def test_bug370_remove_bound_method_returns_count():
    async def main():
        import asyncio

        loop = asyncio.get_running_loop()
        fut = loop.create_future()

        class Handler:
            def on_done(self, f):
                pass

        handler = Handler()
        fut.add_done_callback(handler.on_done)

        # The second attribute lookup creates a DIFFERENT PyMethodObject:
        # identity comparison returned 0, equality must return 1.
        return fut.remove_done_callback(handler.on_done)

    assert talyn.run(main()) == 1


def test_bug370_removed_callback_does_not_fire():
    fired = []

    async def main():
        import asyncio

        loop = asyncio.get_running_loop()
        fut = loop.create_future()

        class Handler:
            def on_done(self, f):
                fired.append(True)

        handler = Handler()
        fut.add_done_callback(handler.on_done)
        assert fut.remove_done_callback(handler.on_done) == 1

        fut.set_result(None)
        # Tick: a removed callback must not fire on resolution.
        await asyncio.sleep(0)
        return fired

    fired_after = talyn.run(main())
    assert fired_after == []


def test_bug370_removed_callback_refs_released():
    async def main():
        import asyncio

        loop = asyncio.get_running_loop()
        fut = loop.create_future()

        class Handler:
            def on_done(self, f):
                pass

        handler = Handler()
        ref = weakref.ref(handler)
        fut.add_done_callback(handler.on_done)
        assert fut.remove_done_callback(handler.on_done) == 1

        # Only the (removed) queue entry still held the bound method via
        # its self reference: with the removed references released at
        # removal time, the handler dies immediately. Pre-fix the entry
        # kept the callback + context strong until Future teardown.
        del handler
        return ref()

    assert talyn.run(main()) is None, (
        "removed done-callback still referenced by the Future "
        "(cyan weakref alive): removal did not release its references"
    )
