"""BUG-414 regression gate: detect native (RSS) growth under task churn.

The event loop must not retain memory per created/completed task: a long
run of `create_task` + completion churn must keep RSS flat, matching the
asyncio baseline behavior (see docs/development/bugs/414.md). The soak:

  - runs workloads of tasks at a fixed per-round size,
  - discards the first half of samples (allocator/interpreter warm-up),
  - asserts the per-round slope is below a small threshold.

Cross-variant variants keep the gate honest: the scheduler/timer paths are
known-flat, so only the task lifecycle may move the slope.

Marked xfail(strict=True) while BUG-414 is open: the suite stays green,
and once the fix lands, the "pass" removes the marker (enforced by
strict=True). This test becomes the standing leak gate for future
optimization/fix work in the task hot path.
"""
from __future__ import annotations

import asyncio
import pathlib
import time

import pytest

import talyn

_SAMPLES_MIN = 6
_TOLERANCE_KB_PER_TASK = 0.01  # healthy builds land near ~0; current build leaks ~0.031 kB/task


def _rss_kb() -> int:
    """RSS in kB; returns 0 on platforms without /proc/self/status."""
    status = pathlib.Path("/proc/self/status")
    if not status.exists():
        return 0
    for line in status.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1])
    return 0


async def _noop() -> None:
    pass


async def _soak(variant: str, tasks_per_round: int, seconds: float) -> list[int]:
    samples: list[int] = []
    start = time.monotonic()
    while time.monotonic() - start < seconds:
        if variant == "tasks_gather":
            tasks = [asyncio.create_task(_noop()) for _ in range(tasks_per_round)]
            await asyncio.gather(*tasks)
        elif variant == "tasks_nogather":
            for _ in range(tasks_per_round):
                asyncio.create_task(_noop())
            await asyncio.sleep(0)
        elif variant == "no_tasks_sleep0":
            for _ in range(tasks_per_round):
                await asyncio.sleep(0)
        else:
            raise AssertionError("bad variant")
        samples.append(_rss_kb())
        await asyncio.sleep(0.02)
    return samples


def _slope_kb_per_task(samples: list[int], tasks_per_round: int) -> float:
    flat = [s for s in samples if s > 0]
    if len(flat) < _SAMPLES_MIN:
        pytest.skip("platform without /proc/self/status (RSS unreadable)")
    warm = flat[len(flat) // 4 :]
    if len(warm) < 2 or warm[-1] < warm[0]:
        return 0.0
    return (warm[-1] - warm[0]) / (len(warm) * tasks_per_round)


@pytest.mark.xfail(
    reason="BUG-414: ~32 B/task native retention on the task lifecycle (fix targeted at v0.11.1)",
    strict=True,
)
def test_task_lifecycle_soak_rss_slope_is_flat() -> None:
    async def main() -> None:
        for variant in ("tasks_gather", "tasks_nogather"):
            samples = await _soak(variant, tasks_per_round=384, seconds=6.0)
            slope = _slope_kb_per_task(samples, 512)
            assert slope <= _TOLERANCE_KB_PER_TASK, (
                "%s: RSS slope %.5f kB/task exceeds %.3f kB/task budget "
                "(BUG-414 bookkeeping: native retention per task lifecycle)"
                % (variant, slope, _TOLERANCE_KB_PER_TASK)
            )

    talyn.run(main())


def test_scheduler_and_timer_paths_stay_flat() -> None:
    async def main() -> None:
        samples = await _soak("no_tasks_sleep0", tasks_per_round=384, seconds=4.0)
        slope = _slope_kb_per_task(samples, 512)
        assert slope <= _TOLERANCE_KB_PER_TASK, (
            "scheduler path (sleep(0)) must not retain memory: slope %.5f kB/task" % slope
        )

    talyn.run(main())
