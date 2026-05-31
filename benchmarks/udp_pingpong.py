import asyncio

from benchmarks import Benchmark

BENCHMARK = Benchmark(
    "UDP Ping-Pong",
    lambda loop, n: loop.run_until_complete(_main(n)),
)


class EchoServerProtocol(asyncio.DatagramProtocol):
    def datagram_received(self, data, addr):
        self.transport.sendto(data, addr)

    def connection_made(self, transport):
        self.transport = transport


class ClientProtocol(asyncio.DatagramProtocol):
    def __init__(self, on_done, n):
        self.on_done = on_done
        self.n = n
        self.received = 0

    def datagram_received(self, data, addr):
        self.received += 1
        if self.received >= self.n:
            self.on_done.set_result(True)

    def connection_made(self, transport):
        self.transport = transport
        self.transport.sendto(b"x" * 64)


async def _main(m):
    loop = asyncio.get_event_loop()
    n = max(1, min(m, 200))

    server_transport, server_proto = await loop.create_datagram_endpoint(
        EchoServerProtocol,
        local_addr=("127.0.0.1", 0),
    )
    port = server_transport.get_extra_info("socket").getsockname()[1]

    on_done = loop.create_future()
    client_transport, client_proto = await loop.create_datagram_endpoint(
        lambda: ClientProtocol(on_done, n),
        remote_addr=("127.0.0.1", port),
    )

    for _ in range(n - 1):
        client_transport.sendto(b"x" * 64)

    await on_done
    client_transport.close()
    server_transport.close()
