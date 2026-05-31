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
