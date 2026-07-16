"""Repro for BUG-118 / BUG-119: double-free on connect-submit failure.

Lowers RLIMIT_NOFILE so many concurrent connects fail at submit time, driving
``submit_connect_for_address`` errors through the error path that used to free
``connection_data`` twice. Prints DONE on success, crashes if the regression
is present. Run under a DebugAllocator / ASAN build for a precise report.
"""

import asyncio
import resource
import socket
import threading

import talyn

soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
resource.setrlimit(resource.RLIMIT_NOFILE, (256, hard))

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
    tasks = [
        loop.create_connection(asyncio.Protocol, "127.0.0.1", port) for _ in range(2000)
    ]
    await asyncio.gather(*tasks, return_exceptions=True)


talyn.run(main())
print("DONE")
