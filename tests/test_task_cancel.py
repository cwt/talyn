"""BUG-371 regression tests.

Three Task-cancellation state machine bugs broke Python 3.11+
structured concurrency:

- ``fast_task_cancel`` returned the ``fut_waiter`` cancel result
  verbatim: when the awaited Future resolved in the same tick,
  ``cancel_future_waiter`` returned ``false`` (already finished) and
  the whole ``task.cancel()`` call was silently dropped instead of
  falling through to ``must_cancel`` (CPython behavior — the fix keeps
  the request increment that already happens before the waiter branch).

- ``task_uncancel`` re-armed ``must_cancel = (count > 0)``: after a
  caught ``CancelledError`` in nested ``asyncio.timeout()`` blocks
  (two requests), ``uncancel()`` must only CLEAR the flag at zero —
  re-arming injected a second unrequested CancelledError into the next
  cleanup/finally await.

- ``task_cancelling`` returned 0 for finished/cancelled tasks, but
  CPython 3.11+ reports the request count unconditionally;
  ``asyncio.TaskGroup`` inspects ``cancelling()`` from done callbacks
  (run AFTER the task finished).
"""

import talyn


def test_bug371_cancel_not_dropped_when_waiter_resolved_same_tick():
    observed = []

    async def main():
        import asyncio

        loop = asyncio.get_running_loop()
        fut = loop.create_future()

        async def waiter():
            return await fut

        task = asyncio.create_task(waiter())
        await asyncio.sleep(0)  # let the task start awaiting `fut`

        fut.set_result(42)
        cancelled = task.cancel()
        try:
            result = await task
        except asyncio.CancelledError:
            observed.append("cancelled")
        else:
            observed.append(("result", result))
        return cancelled

    cancelled = talyn.run(main())
    assert cancelled is True, (
        "task.cancel() returned False when the fut_waiter had already "
        "resolved in the same tick — the cancellation request was dropped"
    )
    assert observed == ["cancelled"], observed


def test_bug371_uncancel_does_not_rearm_must_cancel():
    async def main():
        import asyncio

        task = None

        async def survivor():
            # Two self-cancels while the coroutine is executing: the
            # step cleared fut_waiter long ago, so both go through the
            # no-waiter path — must_cancel armed twice,
            # cancel_requests = 2.
            task.cancel()
            task.cancel()
            try:
                await asyncio.sleep(0.02)
            except asyncio.CancelledError:
                # The inner cleanup calls uncancel() on the remaining
                # request; with the pre-fix re-arm, the SECOND await
                # below had an unrequested CancelledError injected.
                task.uncancel()
            await asyncio.sleep(0.02)
            return "survived"

        task = asyncio.create_task(survivor())
        return await task

    assert talyn.run(main()) == "survived"


def test_bug371_cancelling_reports_count_on_finished_task():
    seen = []

    async def main():
        import asyncio

        task = asyncio.create_task(asyncio.sleep(0.05))
        await asyncio.sleep(0)
        task.cancel()

        task.add_done_callback(lambda t: seen.append(t.cancelling()))
        try:
            await task
        except asyncio.CancelledError:
            pass
        return seen

    seen = talyn.run(main())
    assert seen == [1], (
        f"task.cancelling() returned {seen} from a done callback — "
        f"finished/cancelled tasks must still report the request count"
    )
