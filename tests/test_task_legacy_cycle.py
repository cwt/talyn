"""BUG-374 regression test.

``handle_legacy_future_object`` (every Task-await of a foreign/stdlib
``asyncio.Future`` — e.g. via ``loop.run_in_executor``, which wraps a
``concurrent.futures.Future`` with ``asyncio.wrap_future``) leaked:

- the ``PyObject_GetAttrString`` reference of ``_asyncio_future_blocking``;
- an extra ``Py_False`` reference per await (``SetAttrString`` does not
  steal, but ``get_py_false()`` increfs); and
- created a permanent ``task -> wake_up_task_callback -> task`` cycle:
  the cached ``PyCFunction`` has ``m_self = task``, and completion
  cleared ``coro``/``fut_waiter`` without breaking that cycle, so a
  completed Task was only reclaimable by the cyclic GC (and never on
  free-threaded builds, where Talyn disables gc).
"""

import talyn


def test_bug374_completed_legacy_await_task_freed_without_gc():
    import weakref
    async def main():
        import asyncio
        import time

        loop = asyncio.get_running_loop()

        def executor_work():
            # Slow enough that the wrapped stdlib Future is guaranteed
            # pending at the yield — a fast worker resolves it before
            # the coroutine ever yields, and a resolved Future never
            # yields to the step machinery (it returns its result
            # synchronously), bypassing the legacy await path entirely.
            time.sleep(0.05)
            return 42

        async def awaits_legacy():
            # stdlib Future (asyncio.wrap_future path)
            return await loop.run_in_executor(None, executor_work)

        task = asyncio.create_task(awaits_legacy())
        await asyncio.sleep(0)  # let the task reach the legacy await
        ref = weakref.ref(task)
        await task
        del task  # drop the frame's strong reference
        # The leak/cycle is ref-count dieable: post-fix the completed
        # task holds nothing (and holds nothing through itself).
        return ref

    ref = talyn.run(main())
    assert ref() is None, (
        "completed Task that awaited a legacy Future is still alive: "
        "the wake_up_task_callback cycle was not broken at completion"
    )