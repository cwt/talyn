"""BUG-372 regression tests.

A task raising ``KeyboardInterrupt`` / ``SystemExit`` must stop the
event loop and propagate out of the runner (CPython behavior). Pre-fix
the task-step catch blocks defused ``failed_execution``'s deliberate
fatal-propagation: ``PyErr_GetRaisedException`` cleared the re-installed
fatal from the thread state, a second
``future_fast_set_exception`` overwrote the future's payload (leaking
the first reference and re-arming the done-callback machinery), and the
catches returned success — so ``run_forever()`` never stopped and
``sys.exit(2)`` inside a task was silently swallowed.
"""

import sys

import pytest

import talyn


def test_bug372_system_exit_in_task_stops_loop():
    async def main():
        import asyncio

        async def exits():
            sys.exit(2)

        task = asyncio.create_task(exits())
        # The loop must abort on the tick that processes the task's
        # SystemExit — run() never returns normally.
        await asyncio.sleep(5)

    # Before the fix, the fatal was cleared and the loop kept running:
    # run() completed/raised some other state without SystemExit.
    with pytest.raises(SystemExit):
        talyn.run(main())


def test_bug372_keyboard_interrupt_in_task_stops_loop():
    async def main():
        import asyncio

        async def interrupted_msg():
            raise KeyboardInterrupt

        task = asyncio.create_task(interrupted_msg())
        await asyncio.sleep(5)

    with pytest.raises(KeyboardInterrupt):
        talyn.run(main())
