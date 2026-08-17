import asyncio

import talyn


def test_loop_hooks():
    async def main():
        loop = asyncio.get_running_loop()

        results = []

        def prepare_cb():
            results.append("prepare")

        def check_cb():
            results.append("check")

        def idle_cb():
            results.append("idle")

        h_prepare = loop._add_hook(0, prepare_cb)
        h_check = loop._add_hook(1, check_cb)
        h_idle = loop._add_hook(2, idle_cb)

        # Initial run
        await asyncio.sleep(0)

        # We expect:
        # call_once (main continues)
        # idle_hooks
        # prepare_hooks
        # poll_blocking_events (sleep timer)
        # check_hooks

        assert "idle" in results
        assert "prepare" in results
        assert "check" in results

        results.clear()
        h_idle.cancel()

        await asyncio.sleep(0)
        assert "idle" not in results
        assert "prepare" in results

        h_prepare.cancel()
        h_check.cancel()

    talyn.run(main())


def test_idle_prevents_blocking():
    async def main():
        loop = asyncio.get_running_loop()

        count = 0

        def idle_cb():
            nonlocal count
            count += 1

        h_idle = loop._add_hook(2, idle_cb)

        # Even without timers or I/O, loop should iterate because of idle hook
        for _ in range(5):
            await asyncio.sleep(0)

        assert count >= 5
        h_idle.cancel()

    talyn.run(main())


def test_hook_multiple_cancel_no_crash():
    async def main():
        loop = asyncio.get_running_loop()

        def dummy():
            pass

        h = loop._add_hook(0, dummy)
        h.cancel()
        h.cancel()
        h.cancel()

    talyn.run(main())


def test_hook_temporary_handle_no_uaf():
    executed = []

    def dummy():
        executed.append(1)

    async def main():
        loop = asyncio.get_running_loop()
        # Add hook without storing the return handle
        loop._add_hook(0, dummy)
        await asyncio.sleep(0)
        assert len(executed) > 0

    talyn.run(main())


def test_hook_gc_cycle_collection():
    import gc
    import weakref

    loop = talyn.Loop()

    class Holder:
        def __init__(self, l):
            self.loop = l
            self.handle = None

        def on_prepare(self):
            pass

    holder = Holder(loop)
    handle = loop._add_hook(0, holder.on_prepare)
    holder.handle = handle

    loop_ref = weakref.ref(loop)
    holder_ref = weakref.ref(holder)

    del loop
    del holder
    del handle

    gc.collect()

    assert loop_ref() is None
    assert holder_ref() is None




