"""Regression tests for BUG-268: default-factory tasks invisible to
asyncio.all_tasks().

talyn's own Task type never registered with asyncio's task registries, so
``asyncio.all_tasks()`` (and ``_py_all_tasks``, the pure-Python WeakSet
variant) could not see tasks created via ``loop.create_task()`` without a
custom task factory. Registration happens at creation; both registries are
weak/self-cleaning on completion.
"""

from __future__ import annotations

import asyncio

import talyn


def test_default_task_visible_in_all_tasks() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()

        async def wait_forever() -> None:
            await asyncio.Event().wait()

        task = loop.create_task(wait_forever(), name="REGISTRY")

        # Default registry (C-accelerated) and, on 3.14+, the pure-Python
        # WeakSet variant (asyncio.tasks._py_all_tasks only exists there).
        py_all_tasks = getattr(asyncio.tasks, "_py_all_tasks", None)
        assert task in asyncio.all_tasks()
        if py_all_tasks is not None:
            assert task in py_all_tasks(loop)
        assert any(t.get_name() == "REGISTRY" for t in asyncio.all_tasks())

        task.cancel()
        await asyncio.gather(task, return_exceptions=True)

        # Completed tasks disappear from the registries (weak/self-cleaning).
        assert task not in asyncio.all_tasks()
        if py_all_tasks is not None:
            assert task not in py_all_tasks(loop)

    talyn.run(main())


def test_taskgroup_sees_default_tasks() -> None:
    """TaskGroup depends on all_tasks-style bookkeeping via the registries."""

    async def main() -> None:
        async def coro() -> int:
            await asyncio.sleep(0)
            return 7

        async with asyncio.TaskGroup() as tg:
            task = tg.create_task(coro())
            assert task in asyncio.all_tasks()
        assert task.result() == 7
        assert task not in asyncio.all_tasks()

    talyn.run(main())
