"""Test socket connect/accept/shutdown correctness without IOSQE_ASYNC.

These exercises the exact code paths affected by PRIORITY 16:
- sock_connect (was IOSQE_ASYNC, now deferred)
- sock_accept (was IOSQE_ASYNC, now deferred)
- sock_shutdown (was IOSQE_ASYNC, now deferred)

Without IOSQE_ASYNC the kernel handles these inline for localhost sockets.
The test verifies correctness is preserved after the flag removal.
"""

import asyncio
import os
import shutil
import socket
import tempfile

import talyn


def test_many_sequential_connections():
    """Mimic Socket Ops benchmark: many sequential connect/accept/close cycles."""

    async def main():
        async def handler(reader, writer):
            try:
                data = await reader.read(256)
                if data:
                    writer.write(data)
                    await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        async def one_shot(port):
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            writer.write(b"x" * 64)
            await writer.drain()
            data = await reader.readexactly(64)
            assert data == b"x" * 64
            writer.close()
            await writer.wait_closed()

        server = await asyncio.start_server(handler, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        async with server:
            for _ in range(100):
                await one_shot(port)

    talyn.run(main())


def test_raw_socket_connect_accept():
    """Test low-level loop.sock_connect/sock_accept/sock_sendall/sock_recv."""

    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(5)
        server_sock.setblocking(False)
        addr = server_sock.getsockname()

        results = []

        async def accept_loop():
            for _ in range(20):
                client, client_addr = await loop.sock_accept(server_sock)
                try:
                    data = await loop.sock_recv(client, 1024)
                    await loop.sock_sendall(client, data.upper())
                finally:
                    client.close()
                results.append(data)

        server_task = loop.create_task(accept_loop())

        for i in range(20):
            client_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            client_sock.setblocking(False)
            await loop.sock_connect(client_sock, addr)
            msg = f"hello-{i}".encode()
            await loop.sock_sendall(client_sock, msg)
            data = await loop.sock_recv(client_sock, 1024)
            assert data == msg.upper()
            client_sock.close()

        await server_task
        server_sock.close()
        assert len(results) == 20

    talyn.run(main())


def test_shutdown_variants():
    """Test that socket shutdown works correctly in all variants."""

    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        server_sock.setblocking(False)
        addr = server_sock.getsockname()

        async def server_side():
            client, _ = await loop.sock_accept(server_sock)
            try:
                data = await loop.sock_recv(client, 1024)
                assert data == b"before-shutdown"
                await loop.sock_sendall(client, b"ack")
                await loop.sock_recv(client, 1024)
            finally:
                client.close()

        server_task = loop.create_task(server_side())

        client_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client_sock.setblocking(False)
        await loop.sock_connect(client_sock, addr)
        await loop.sock_sendall(client_sock, b"before-shutdown")
        data = await loop.sock_recv(client_sock, 1024)
        assert data == b"ack"

        client_sock.shutdown(socket.SHUT_WR)
        await server_task
        client_sock.close()
        server_sock.close()

    talyn.run(main())


def test_concurrent_connect_accept_stress():
    """Multiple concurrent connections to stress connect/accept without IOSQE_ASYNC."""

    async def main():
        async def handler(reader, writer):
            try:
                data = await reader.read(100)
                writer.write(data)
                await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        server = await asyncio.start_server(handler, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        async with server:

            async def one_shot(i):
                reader, writer = await asyncio.open_connection("127.0.0.1", port)
                msg = f"msg-{i}".encode()
                writer.write(msg)
                await writer.drain()
                data = await reader.readexactly(len(msg))
                assert data == msg
                writer.close()
                await writer.wait_closed()

            tasks = [one_shot(i) for i in range(50)]
            await asyncio.gather(*tasks)

    talyn.run(main())


def test_unix_socket_connect_accept():
    """Unix domain sockets also exercise connect/accept/shutdown paths."""
    import os
    import tempfile

    async def main():
        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, "test.sock")

            async def handler(reader, writer):
                data = await reader.read(256)
                writer.write(data)
                await writer.drain()
                writer.close()
                await writer.wait_closed()

            server = await asyncio.start_unix_server(handler, path)
            async with server:
                for _ in range(20):
                    reader, writer = await asyncio.open_unix_connection(path)
                    writer.write(b"unix-echo")
                    await writer.drain()
                    data = await reader.readexactly(9)
                    assert data == b"unix-echo"
                    writer.close()
                    await writer.wait_closed()

    talyn.run(main())


def test_sock_ops_future_refcount_stability():
    """BUG-310 companion: every socket-op initiator stores py_newref'd
    future/loop references in its op data and releases them via the
    completion cleanup (or, since BUG-310, the io.queue-failure errdefer).
    Cycling the ops must show zero net reference drift - a double-decref
    in any cleanup path shows up as negative drift, a missed decref as
    positive drift."""
    import sys

    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(16)
        addr = server_sock.getsockname()[1]

        async def cycle(n: int) -> None:
            for _ in range(n):
                # Connect first (the listen backlog holds the connection),
                # then pick it up with sock_accept.
                client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                client.setblocking(False)
                await loop.sock_connect(client, ("127.0.0.1", addr))
                server, _ = await loop.sock_accept(server_sock)
                await loop.sock_sendall(client, b"ping")
                await loop.sock_recv(server, 4)
                client.close()
                server.close()

        # Warm-up
        await cycle(2)
        await asyncio.sleep(0.05)
        base = sys.getrefcount(asyncio.BaseProtocol)
        await cycle(10)
        await asyncio.sleep(0.1)
        delta = sys.getrefcount(asyncio.BaseProtocol) - base
        server_sock.close()
        assert delta == 0, f"future/loop reference drift over 10 cycles: {delta}"

    talyn.run(main())


def test_sock_methods_accept_keyword_arguments():
    """BUG-331: every sock_* coroutine must accept keyword arguments.

    CPython asyncio (and uvloop) declare these parameters as
    positional-or-keyword, and python-socks (aiohttp-socks) calls
    ``loop.sock_connect(sock=..., address=...)``. talyn registered the
    methods with METH_FASTCALL only, so any keyword call raised
    ``TypeError: takes no keyword arguments``.
    """

    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(5)
        server_sock.setblocking(False)
        addr = server_sock.getsockname()

        client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client.setblocking(False)
        try:
            await loop.sock_connect(sock=client, address=addr)
            conn, _ = await loop.sock_accept(sock=server_sock)
            try:
                await loop.sock_sendall(sock=client, data=b"ping")
                assert await loop.sock_recv(sock=conn, n=4) == b"ping"

                buf = bytearray(16)
                await loop.sock_sendall(sock=client, data=b"pong")
                n = await loop.sock_recv_into(sock=conn, buf=buf)
                assert bytes(buf[:n]) == b"pong"
            finally:
                conn.close()

            udp_recv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            udp_recv.setblocking(False)
            udp_recv.bind(("127.0.0.1", 0))
            udp_send = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            udp_send.setblocking(False)
            try:
                await loop.sock_sendto(
                    sock=udp_send,
                    data=b"dgram",
                    address=udp_recv.getsockname(),
                )
                data, _sender = await loop.sock_recvfrom(sock=udp_recv, bufsize=64)
                assert data == b"dgram"
            finally:
                udp_send.close()
                udp_recv.close()
        finally:
            client.close()
            server_sock.close()

    talyn.run(main())


def test_getnameinfo_accepts_keyword_arguments():
    """BUG-331: loop.getnameinfo must accept keyword arguments.

    A negative dns_timeout is rejected before any DNS query is queued, so
    keyword dispatch is asserted without depending on resolver state.
    """

    async def main():
        loop = asyncio.get_running_loop()
        try:
            await loop.getnameinfo(
                sockaddr=("127.0.0.1", 80),
                flags=0,
                dns_timeout=-1.0,
            )
        except ValueError:
            pass
        else:
            raise AssertionError("negative dns_timeout was not rejected")

    talyn.run(main())


def test_bug353_no_result_reference_leaks():
    """BUG-353: sock_sendto/sock_recv_into leaked each PyLong result object
    (PyLong_FromLong never decref'd) and sock_connect/sock_sendall leaked
    one Py_None per call (get_py_none() + future_fast_set_result's own
    incref)."""
    import gc
    import sys

    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(8)
        server_sock.setblocking(False)
        addr = server_sock.getsockname()

        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.bind(("127.0.0.1", 0))
        udp_addr = udp.getsockname()
        udp.setblocking(False)

        async def echo_server():
            for _ in range(301):  # 1 warmup + 300 measured iterations
                client, _ = await loop.sock_accept(server_sock)
                try:
                    data = await loop.sock_recv(client, 1024)
                    if data:
                        await loop.sock_sendall(client, data)
                finally:
                    client.close()

        server_task = loop.create_task(echo_server())

        payload = b"x" * 300  # 300 > small-int cache: fresh PyLong per op
        buf = bytearray(1024)

        # Warmup: one full iteration so lazy machinery reaches steady
        # state, then measure.
        async def one_iteration() -> None:
            c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            c.setblocking(False)
            await loop.sock_connect(c, addr)          # Py_None result
            await loop.sock_sendall(c, payload)       # Py_None result
            n = await loop.sock_recv(c, 1024)
            assert n == payload
            c.close()
            await loop.sock_sendto(udp, payload, udp_addr)   # PyLong(300) result
            got = await loop.sock_recv_into(udp, buf)        # PyLong result
            assert got == 300

        await one_iteration()
        await asyncio.sleep(0.05)
        gc.collect()

        none_before = sys.getrefcount(None)
        blocks_before = sys.getallocatedblocks()

        for _ in range(300):
            await one_iteration()

        await server_task
        server_sock.close()
        udp.close()
        # Free-threaded GC sweeps deallocations over multiple rounds —
        # flush them all before measuring.
        for _ in range(5):
            await asyncio.sleep(0.02)
            gc.collect()

        none_after = sys.getrefcount(None)
        blocks_after = sys.getallocatedblocks()

        # Py_None is immortal on 3.12+ (increfs are no-ops), so the None
        # leak is invisible to refcounts there — kept as a canary only.
        assert none_after == none_before, (
            f"Py_None leaked: {none_before} -> {none_after}"
        )
        # Pre-fix, every iteration leaked the PyLong result objects of
        # sock_sendto and sock_recv_into (~2 blocks/iter; calibrated at
        # +196 blocks for 100 iterations vs ~0 with the fix). 300
        # iterations leak ~590 blocks pre-fix; free-threaded deferred-
        # dealloc noise stays below ~300, so 450 separates them.
        assert blocks_after - blocks_before < 450, (
            f"result PyLong objects leaked: {blocks_before} -> {blocks_after} blocks"
        )

    talyn.run(main())


def test_bug356_accept_recvfrom_no_leak():
    """BUG-356: the socket completion callbacks used
    `var success = false; defer if (success) cleanup(d)` — every
    `orelse return set_future_exception(...)` branch returned void with
    success == false, bypassing cleanup AND the manager's .cleanup,
    leaking the callback struct, its heap buffer, and references. The
    callbacks now clean up unconditionally; repeated accept/recvfrom
    flows must leave the allocator flat."""
    import gc
    import sys

    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(8)
        server_sock.setblocking(False)
        addr = server_sock.getsockname()

        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.bind(("127.0.0.1", 0))
        udp.setblocking(False)

        payload = b"y" * 300

        async def echo_server():
            for _ in range(101):
                client, _ = await loop.sock_accept(server_sock)  # cleanup_accept path
                try:
                    data = await loop.sock_recv(client, 1024)
                    if data:
                        await loop.sock_sendall(client, data)
                finally:
                    client.close()

        server_task = loop.create_task(echo_server())

        async def one_cycle():
            # accept/recv echo through the stream socket
            c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            c.setblocking(False)
            await loop.sock_connect(c, addr)
            await loop.sock_sendall(c, payload)
            n = await loop.sock_recv(c, 1024)
            assert n == payload
            c.close()
            # recvfrom through the UDP socket
            await loop.sock_sendto(udp, payload, udp.getsockname())
            buf = bytearray(1024)
            data, _sender = await loop.sock_recvfrom(udp, bufsize=1024)
            assert data == payload

        # Warmup, then measure.
        await one_cycle()
        await asyncio.sleep(0.05)
        gc.collect()
        blocks_before = sys.getallocatedblocks()

        for _ in range(100):
            await one_cycle()

        await server_task
        await asyncio.sleep(0.05)
        for _ in range(5):
            await asyncio.sleep(0.02)
            gc.collect()
        blocks_after = sys.getallocatedblocks()

        assert blocks_after - blocks_before < 150, (
            f"callback state leaked: {blocks_before} -> {blocks_after} blocks"
        )

        server_sock.close()
        udp.close()

    talyn.run(main())


def test_bug360_unnamed_unix_accept_and_unbound_recvfrom():
    """BUG-360: AcceptData.addr/SockRecvFromData.addr were `undefined` and
    the kernel may write far fewer bytes than sizeof(sockaddr.storage) —
    an unnamed AF_UNIX accept client writes just the 2-byte family (the
    path kept stale allocator bytes) and an unbound AF_UNIX datagram
    sender writes nothing at all (namelen = 0). The storages are now
    zero-filled and the callbacks honour the written length with
    CPython's semantics: sock_accept of an unnamed client yields '',
    sock_recvfrom from an unnamed sender yields None."""

    async def main():
        loop = asyncio.get_running_loop()

        # --- sock_accept of an unnamed AF_UNIX client must yield '' ---
        tmpdir = tempfile.mkdtemp()
        try:
            path = os.path.join(tmpdir, "bug360.sock")

            server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server_sock.bind(path)
            server_sock.listen(4)
            server_sock.setblocking(False)

            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            # Leave the client unnamed (default, never bind() it).
            client.connect(path)
            conn, addr = await loop.sock_accept(server_sock)
            assert addr == "", f"unnamed AF_UNIX accept yielded {addr!r}"
            client.close()
            conn.close()
            server_sock.close()
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

        # --- sock_recvfrom from an unbound AF_UNIX sender must yield None ---
        tmpdir = tempfile.mkdtemp()
        try:
            rx_path = os.path.join(tmpdir, "bug360recv.sock")

            server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            server_sock.bind(rx_path)
            server_sock.setblocking(False)

            sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            # Unbound sender — the kernel leaves msg.namelen at 0.
            await loop.sock_sendto(sender, b"bug360", rx_path)
            data, sender_addr = await loop.sock_recvfrom(server_sock, bufsize=1024)
            assert data == b"bug360"
            assert sender_addr is None, (
                f"unnamed AF_UNIX recvfrom yielded {sender_addr!r}, expected None"
            )
            sender.close()
            server_sock.close()
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    talyn.run(main())


def test_bug360_empty_buffer_socket_ops():
    """BUG-360: an empty bytearray() carries pbuf.buf == null; casting it
    to [*]u8 tripped the null-pointer safety check in sock_sendall,
    sock_sendto and sock_recv_into. sock_sendall/sock_sendto now tolerate
    empty buffers, and sock_recv_into mirrors CPython by resolving 0
    without a syscall (leaving already-queued data untouched)."""

    async def main():
        loop = asyncio.get_running_loop()

        # Stream pair: empty sendall resolves None (CPython performs no
        # syscall for sendall(b''); io_uring rejects zero-length write
        # SQEs with EFAULT, so nothing is queued).
        srv, cli = socket.socketpair()
        srv.setblocking(False)
        cli.setblocking(False)
        result = await loop.sock_sendall(cli, bytearray())
        assert result is None
        # The stream keeps working after the empty sendall.
        srv.send(b"pong")
        buf = bytearray(16)
        n = await loop.sock_recv_into(cli, buf)
        assert n == 4 and bytes(buf[:4]) == b"pong"
        srv.close()
        cli.close()

        # Datagram pair over a real path: empty sendto mirrors CPython
        # and still delivers a zero-byte datagram (addressed sendmsg with
        # a zero-length iov — msg_iovlen is kept at 0 since io_uring's
        # send path rejects zero-length iovecs with EFAULT).
        tmpdir = tempfile.mkdtemp()
        try:
            dpath = os.path.join(tmpdir, "bug360dgram.sock")
            dsrv = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            dsrv.bind(dpath)
            dsrv.setblocking(False)
            dcli = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            dcli.setblocking(False)
            await loop.sock_sendto(dcli, bytearray(), dpath)
            data, sender_addr = await loop.sock_recvfrom(dsrv, bufsize=16)
            assert data == b"", f"empty datagram arrived as {data!r}"
            assert sender_addr is None, (
                f"unnamed AF_UNIX datagram sender yielded {sender_addr!r}, expected None"
            )
            dcli.close()
            dsrv.close()
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

        # Empty recv_into resolves 0 without a null-pointer panic and
        # without consuming the data the peer already queued.
        srv2, cli2 = socket.socketpair()
        srv2.setblocking(False)
        cli2.setblocking(False)
        srv2.send(b"x")
        n = await loop.sock_recv_into(cli2, bytearray())
        assert n == 0, f"empty recv_into yielded {n!r}, expected 0"
        buf2 = bytearray(16)
        n = await loop.sock_recv_into(cli2, buf2)
        assert n == 1 and buf2[0] == ord("x")
        srv2.close()
        cli2.close()

    talyn.run(main())


def test_bug361_socket_integer_bounds():
    """BUG-361: Python-supplied integers were narrowed with unchecked
    @intCast — out-of-range ports/ fds panicked (Debug/ReleaseSafe) or
    silently truncated (ReleaseFast). All socket entry points now raise
    ValueError instead (Mandate #1: no panics on untrusted input)."""
    import pytest

    async def main():
        loop = asyncio.get_running_loop()

        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.bind(("127.0.0.1", 0))
        srv.listen(4)
        srv.setblocking(False)

        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.bind(("127.0.0.1", 0))
        udp.setblocking(False)

        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setblocking(False)

        # Port accepted by PyLong but rejected by the u16 narrowing:
        for bad_port in (70000, -1):
            with pytest.raises(ValueError):
                await loop.sock_connect(sock, ("127.0.0.1", bad_port))
            with pytest.raises(ValueError):
                await loop.sock_sendto(udp, b"x", ("127.0.0.1", bad_port))

        # An out-of-range fd reported by a crafted fileno():
        class HugeFdSock:
            def fileno(self):
                return 2**40

        for op in ("sendall", "recv", "recv_into", "recvfrom", "connect", "accept"):
            with pytest.raises(ValueError):
                if op == "sendall":
                    await loop.sock_sendall(HugeFdSock(), b"x")
                elif op == "recv":
                    await loop.sock_recv(HugeFdSock(), 16)
                elif op == "recv_into":
                    await loop.sock_recv_into(HugeFdSock(), bytearray(16))
                elif op == "recvfrom":
                    await loop.sock_recvfrom(HugeFdSock(), bufsize=16)
                elif op == "connect":
                    await loop.sock_connect(HugeFdSock(), srv.getsockname())
                else:
                    await loop.sock_accept(HugeFdSock())

        srv.close()
        udp.close()
        sock.close()

    talyn.run(main())
