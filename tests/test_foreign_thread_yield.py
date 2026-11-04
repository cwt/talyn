"""BUG-415 regression gate: a parked runner must yield the GIL to foreign threads.

The v0.11.x BUG-399/BUG-410 watchdog rewrite let the blocking wait be
self-unblocked by the watchdog's own cancellation CQE (drain-first +
remove-after-wait fix in src/loop/runner.zig), degenerating an idle
run_forever into a ~3.2k iterations/s spin that freed and re-took the GIL
every cycle. Foreign Python threads (aiosqlite's worker thread, resolvers,
loggers) that must re-acquire the GIL per step were starved for that whole
idle window: wormhole's 150k-row aiosqlite executemany advanced ~16 KB in
30 s, while the v0.10.0 wheel (which still used submit_and_wait(1)) completed
the identical update in ~2 s. Timing correlates exactly with the watchdog
rewrite landing after rev 1173.

These tests pin both halves of the fix:

1. ``test_foreign_thread_computes_while_loop_parked`` — while the loop is
   parked (no callbacks, no reserved slots), a foreign thread's CPU-heavy
   Python work must complete at solo speed, not lockout speed.
2. ``test_call_soon_threadsafe_wakes_parked_loop`` — a foreign thread's
   cross-thread dispatch (which rides the persistent eventfd wake) must be
   executed promptly by the parked loop, well inside the BUG-410 watchdog
   bound (100 ms).
"""

from __future__ import annotations

import asyncio
import threading
import time

import pytest

import talyn

_COMPUTE_ROUNDS = 6
_COMPUTE_N = 2_000_000


def test_foreign_thread_computes_while_loop_parked() -> None:
    """BUG-415: the parked runner must not starve a foreign CPU thread.

    The thread waits for the loop to reach its parked state, then does
    GIL-heavy pure-Python work. Pre-fix, the runner's self-unblocking
    watchdog loop held/released the GIL ~3k times per second and the
    worker completed only a fraction of its solo rate.
    """
    solo_per_round = 0.0
    start = time.monotonic()
    for _ in range(2):
        sum(range(_COMPUTE_N))
    solo_per_round = (time.monotonic() - start) / 2

    result: dict[str, float] = {}

    async def main() -> float:
        loop = asyncio.get_running_loop()
        done: asyncio.Future[float] = loop.create_future()

        def worker() -> None:
            # Let the loop reach the parked state first.
            time.sleep(0.25)
            start = time.monotonic()
            for _ in range(_COMPUTE_ROUNDS):
                sum(range(_COMPUTE_N))
            result["took"] = time.monotonic() - start
            loop.call_soon_threadsafe(done.set_result, result["took"])

        thread = threading.Thread(target=worker, daemon=True)
        thread.start()
        try:
            return await done
        finally:
            thread.join(timeout=5)

    took = talyn.run(main())
    # The workload costs ~solo_per_round per round; the parked loop must not
    # stretch it by more than a small factor. Pre-fix shapes blow this out
    # by orders of magnitude.
    budget = solo_per_round * _COMPUTE_ROUNDS * 3 + 1.0
    assert took < budget, (
        f"foreign thread took {took:.3f}s (solo-per-round {solo_per_round:.3f}s) "
        f"while the loop was idle — the runner did not yield the GIL"
    )


def test_call_soon_threadsafe_wakes_parked_loop() -> None:
    """BUG-415: cross-thread dispatch must wake a parked loop promptly.

    The loop sits fully idle (no callbacks, no native IO in flight) while a
    foreign thread parks work via call_soon_threadsafe. With the drain-first
    park, the eventfd wake lands as a real CQE and the callback executes in
    microseconds; a watchdog-bound (100 ms) delivery would also be too slow
    for interactive command loops like aiosqlite's.
    """
    result: dict[str, float] = {}

    async def main() -> float:
        loop = asyncio.get_running_loop()
        done: asyncio.Future[float] = loop.create_future()

        def worker() -> None:
            time.sleep(0.25)
            stamp = time.monotonic()

            def record() -> None:
                result["latency"] = time.monotonic() - stamp
                done.set_result(None)

            loop.call_soon_threadsafe(record)

        thread = threading.Thread(target=worker, daemon=True)
        thread.start()
        try:
            await done
        finally:
            thread.join(timeout=5)

        return result["latency"]

    latency = talyn.run(main())
    assert latency < 0.05, f"parked-loop wake latency {latency*1000:.1f} ms exceeds 50 ms"


def test_parked_loop_consumes_sequential_worker_commands() -> None:
    """BUG-415 end-to-end: a foreign command loop (the aiosqlite shape) that
    pipes results back through call_soon_threadsafe must see all 20 replies
    consumed promptly while the loop is otherwise idle."""
    result: dict[str, float] = {}

    async def main() -> float:
        loop = asyncio.get_running_loop()
        done: asyncio.Future[float] = loop.create_future()
        counter = {"n": 0}

        def worker() -> None:
            time.sleep(0.25)
            start = time.monotonic()
            for _ in range(20):
                loop.call_soon_threadsafe(counter.__setitem__, "n", counter["n"] + 1)
                time.sleep(0.002)
            result["took"] = time.monotonic() - start
            loop.call_soon_threadsafe(done.set_result, counter["n"])

        thread = threading.Thread(target=worker, daemon=True)
        thread.start()
        try:
            return await done
        finally:
            thread.join(timeout=5)

    delivered = talyn.run(main())
    assert delivered == 20, delivered
    assert result["took"] < 1.0, (
        f"20 sequential cross-thread dispatches took {result['took']:.3f}s "
        f"while the loop was parked"
    )
