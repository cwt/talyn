"""BUG-369 regression tests.

``Future`` teardown and zombie states were reachable from Python with
UB outcomes:

- A ``Future`` created via ``tp_new`` without ``__init__`` (the state
  ``future_set_initial_values`` guards with ``released = true``) had
  undefined ``loop``/``callbacks_queue`` fields; pre-fix,
  ``set_result()``/``cancel()`` ran the done-callback machinery on the
  garbage-armed future (NULL/undefined deref — guaranteed SIGSEGV
  through ``loop.initialized`` / ``loop.reserved_slots`` for the
  zero-filled tp_alloc memory). Post-fix, the ``released`` guards make
  these mutations inert/InvalidStateError.
- ``Future.release()`` fenced ``released`` on its last line, detached
  ``result`` *after* the finalizer-triggering decrefs, and
  ``get_result`` unwrapped ``result.?`` for a GC-cleared finished
  Future (a mid-teardown finalizer could double-free the callbacks
  queue or hand back the dying pointer). The fence and the
  detach-before-decref ordering are exercised here only as
  crash-smoke (CPython clears closure cells, weakrefs and instance
  dicts *before* finalizers run, so a finalizer cannot hold a strong
  handle into its own teardown) and validated at the code level in
  the bug write-up.
"""

import asyncio
import gc

import pytest

import talyn


@pytest.fixture
def zombie_future():
    """A talyn_zig Future created via tp_new without __init__: never
    armed with a loop (``released == true`` from birth), so its
    ``loop`` / ``callbacks_queue`` / ``exceptions_queue`` fields are the
    zero-filled tp_alloc defaults (NULL / undefined)."""
    from talyn.talyn_zig import Future as ZigFuture

    return ZigFuture.__new__(ZigFuture)


def test_bug369_zombie_set_result_raises_invalid_state(zombie_future):
    with pytest.raises(asyncio.InvalidStateError):
        zombie_future.set_result(1)


def test_bug369_zombie_cancel_returns_false(zombie_future):
    assert zombie_future.cancel() is False


def test_bug369_zombie_set_exception_raises_invalid_state(zombie_future):
    with pytest.raises(asyncio.InvalidStateError):
        zombie_future.set_exception(ValueError("x"))


def test_bug440_zombie_get_loop_raises_instead_of_null_return(zombie_future):
    """BUG-440: get_loop() on a tp_new-only Future (py_loop == null).

    Pre-fix the method returned py_newref(NULL) — NULL-safe in CPython, so
    it returned NULL *without setting an exception* and Python raised
    SystemError: "... returned NULL without setting an error". It now
    raises a proper RuntimeError instead.
    """
    with pytest.raises(RuntimeError):
        zombie_future.get_loop()


def test_bug440_zombie_task_get_name_returns_none():
    """BUG-440 sibling: Task.__new__(Task).get_name() unwrapped
    fut.py_loop.? when no explicit name was set, crashing with SIGSEGV.
    Match CPython _CTask.__new__(_CTask).get_name() -> None."""
    from talyn.talyn_zig import Task as ZigTask

    zombie_task = ZigTask.__new__(ZigTask)
    assert zombie_task.get_name() is None


def test_bug446_task_awaiting_zombie_future_raises_instead_of_crash(zombie_future):
    """BUG-446: handle_talyn_future_object unwrapped future.py_loop.? with
    no released/null guard — awaiting a tp_new-only Future from a task
    panicked inside the task-stepping path (unwrap panic in
    Debug/ReleaseSafe, UB in ReleaseFast) instead of raising."""
    async def main():
        async def waiter():
            await zombie_future

        task = asyncio.create_task(waiter())
        outcome = await asyncio.gather(task, return_exceptions=True)
        assert isinstance(outcome[0], RuntimeError), outcome

    talyn.run(main())


def test_bug369_gc_cycle_with_del_partner_collects_cleanly():
    """The report's reproduction skeleton: a cycle containing a finished
    Future and a __del__-bearing partner. CPython clears every cycle
    member before running the finalizers, so the finalizer cannot
    re-enter the Future with a strong handle — after BUG-369 the
    teardown is fence-safe regardless (released fences first, result
    detached before decref). Observable: the cycle is fully collected
    and the interpreter survives."""
    ran = []

    class Partner:
        def __del__(self):
            ran.append(True)

    async def main():
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        partner = Partner()
        partner.fut = fut  # cycle edge: partner -> fut
        fut.set_result(partner)  # cycle edge: fut -> partner
        del fut, partner
        gc.collect()

    talyn.run(main())

    assert ran == [True]
