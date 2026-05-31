import asyncio

from benchmarks import Benchmark

BENCHMARK = Benchmark(
    "Socket Ops",
    lambda loop, n: loop.run_until_complete(_main(n)),
)


async def _main(m):
    n = max(1, min(m, 512))

    async def handler(reader, writer):
        try:
            data = await reader.read(256)
            if data:
                writer.write(data)
                await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

    async def one_shot():
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.write(b"x" * 64)
        await writer.drain()
        await reader.readexactly(64)
        writer.close()
        await writer.wait_closed()

    server = await asyncio.start_server(handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    async with server:
        for _ in range(n):
            await one_shot()
