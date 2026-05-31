import asyncio
import sys

from benchmarks import Benchmark

BENCHMARK = Benchmark(
    "Subprocess",
    lambda loop, n: loop.run_until_complete(_main(n)),
)


async def _main(m):
    n = max(1, min(m, 50))

    async def spawn_one():
        proc = await asyncio.create_subprocess_exec(
            sys.executable,
            "-c",
            "import sys; sys.exit(0)",
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()

    for _ in range(n):
        await spawn_one()
