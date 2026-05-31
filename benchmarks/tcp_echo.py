import asyncio

from benchmarks import Benchmark

BENCHMARK = Benchmark(
    "TCP Echo",
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
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        data = b"x" * size
        writer.write(data)
        await writer.drain()
        await reader.readexactly(len(data))
        writer.close()
        await writer.wait_closed()

    server = await asyncio.start_server(echo_handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    async with server:
        for _ in range(n):
            await one_client()
