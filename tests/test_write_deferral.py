import asyncio
import socket

import talyn


def test_write_deferral():
    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        addr = server_sock.getsockname()

        def run_server():
            client, _ = server_sock.accept()
            data = b""
            while len(data) < 10:
                chunk = client.recv(1024)
                if not chunk:
                    break
                data += chunk
            assert data == b"abcdefghij"
            client.close()

        server_task = loop.run_in_executor(None, run_server)

        reader, writer = await asyncio.open_connection(*addr)

        # Call write multiple times in the same iteration
        writer.write(b"abc")
        writer.write(b"def")
        writer.write(b"ghij")

        transport = writer.transport
        # At this point, no writev should have been queued yet
        # because we haven't reached the end of the iteration.
        # Wait, writer.write() in asyncio might call transport.write()
        # but since we deferred it, writev_count should be 0 or previous value.

        count_before = transport.get_extra_info("writev_count")

        # Now yield to the loop so the prepare hook can run
        await asyncio.sleep(0)

        count_after = transport.get_extra_info("writev_count")

        # All three writes should have been coalesced into a single writev call
        assert count_after == count_before + 1

        writer.close()
        await writer.wait_closed()
        await server_task
        server_sock.close()

    talyn.run(main())


def test_write_deferral_with_drain():
    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        addr = server_sock.getsockname()

        def run_server():
            client, _ = server_sock.accept()
            try:
                client.recv(1024)
            finally:
                client.close()

        server_task = loop.run_in_executor(None, run_server)

        reader, writer = await asyncio.open_connection(*addr)
        transport = writer.transport

        count0 = transport.get_extra_info("writev_count")
        writer.write(b"a" * 100)
        await asyncio.sleep(0.1)  # Wait for it to flush and complete
        count1 = transport.get_extra_info("writev_count")
        assert count1 >= count0 + 1

        writer.write(b"b" * 100)
        await asyncio.sleep(0.1)  # Wait for it to flush and complete
        count2 = transport.get_extra_info("writev_count")
        assert count2 >= count1 + 1

        writer.close()
        await writer.wait_closed()
        await server_task
        server_sock.close()

    talyn.run(main())


def test_write_abort_refcount_underflow():
    async def main():
        asyncio.get_running_loop()

        async def handle_client(reader, writer):
            writer.close()
            await writer.wait_closed()

        server = await asyncio.start_server(handle_client, "127.0.0.1", 0)
        addr = server.sockets[0].getsockname()

        reader, writer = await asyncio.open_connection(*addr)
        transport = writer.transport

        # Queue a write
        writer.write(b"a" * 100)

        # Immediately abort (this cancels pending writes and triggers decref)
        transport.abort()

        # Wait for close
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass

        server.close()
        await server.wait_closed()

        # Trigger GC to verify no segfault/double-free occurs
        import gc

        gc.collect()

    talyn.run(main())


def test_stream_transport_gc():
    transport_id = None

    async def main():
        nonlocal transport_id
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        addr = server_sock.getsockname()

        def run_server():
            client, _ = server_sock.accept()
            client.close()

        server_task = loop.run_in_executor(None, run_server)

        reader, writer = await asyncio.open_connection(*addr)
        transport = writer.transport
        transport_id = id(transport)

        writer.close()
        await writer.wait_closed()
        await server_task
        server_sock.close()

    talyn.run(main())

    import gc

    gc.collect()

    assert not any(id(obj) == transport_id for obj in gc.get_objects())
