"""Repro for BUG-120: use-after-free of the happy-eyeballs ``mcs``.

Connects to "localhost" (dual-stack, so the happy-eyeballs timer is scheduled)
with a short delay and immediate cancellation. The first connect wins well
before the timer fires; with the regression, the success path frees ``mcs``
while the pending timer callback still references it. Prints DONE on success,
crashes (SIGSEGV/SIGABRT) if the regression is present.
"""
import asyncio
import socket
import threading

import talyn

try:
    srv = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    srv.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    srv.bind(("::", 0))
    srv.listen(256)
except OSError:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(256)
port = srv.getsockname()[1]


def serve() -> None:
    while True:
        try:
            c, _ = srv.accept()
        except OSError:
            break
        try:
            while True:
                c.settimeout(0.2)
                d = c.recv(1024)
                if not d:
                    break
                c.sendall(d)
        except Exception:
            pass
        finally:
            c.close()


threading.Thread(target=serve, daemon=True).start()


async def main() -> None:
    loop = asyncio.get_running_loop()
    for _ in range(60):
        tasks = []
        for i in range(80):
            t = asyncio.ensure_future(
                loop.create_connection(
                    asyncio.Protocol,
                    "localhost",
                    port,
                    happy_eyeballs_delay=0.25,
                    interleave=1,
                )
            )
            if i % 2 == 0:
                loop.call_soon(t.cancel)
            tasks.append(t)
        await asyncio.gather(*tasks, return_exceptions=True)


talyn.run(main())
print("DONE")
