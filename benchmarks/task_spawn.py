import asyncio

from benchmarks import Benchmark

BENCHMARK = Benchmark(
    "Task Spawn",
    lambda loop, n: loop.run_until_complete(_main(n)),
)

async def noop():
    pass

async def _main(m):
    tasks = [asyncio.create_task(noop()) for _ in range(m)]
    await asyncio.gather(*tasks)
