import asyncio
import os
import tempfile

from benchmarks import Benchmark

BENCHMARK = Benchmark(
    "Unix Echo",
    lambda loop, n: loop.run_until_complete(_main(n)),
)

async def _main(m):
    n = max(1, m // 1024)
    size = max(1, m // n)

    async def echo_handler(reader, writer):
        try:
            while True:
                data = await reader.read(65536)
                if not data:
                    break
                writer.write(data)
                await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

    async def one_client():
        reader, writer = await asyncio.open_unix_connection(path)
        data = b"x" * size
        writer.write(data)
        await writer.drain()
        await reader.readexactly(len(data))
        writer.close()
        await writer.wait_closed()

    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, "echo.sock")
        server = await asyncio.start_unix_server(echo_handler, path)
        async with server:
            for _ in range(n):
                await one_client()
