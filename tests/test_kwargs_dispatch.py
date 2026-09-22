"""BUG-331 regression: keyword dispatch for the remaining fixed methods.

The socket-op coroutines are covered in ``test_socket_ops.py``. These tests
cover the other ``METH_FASTCALL`` registrations that previously lacked
``METH_KEYWORDS`` and therefore raised
``TypeError: takes no keyword arguments`` on keyword calls.
"""

import asyncio
import os
import signal
import subprocess
import time

import talyn


def test_add_reader_and_writer_accept_keywords():
    async def main():
        loop = asyncio.get_running_loop()
        read_fd, write_fd = os.pipe()
        read_seen = []
        write_seen = []

        def on_readable():
            read_seen.append(os.read(read_fd, 1))

        def on_writable():
            write_seen.append(True)

        try:
            loop.add_reader(fd=read_fd, callback=on_readable)
            loop.add_writer(fd=write_fd, callback=on_writable)

            os.write(write_fd, b"x")
            start = time.time()
            while (not read_seen or not write_seen) and time.time() - start < 2.0:
                await asyncio.sleep(0.01)

            assert read_seen == [b"x"]
            assert write_seen
        finally:
            loop.remove_reader(read_fd)
            loop.remove_writer(write_fd)
            os.close(read_fd)
            os.close(write_fd)

    talyn.run(main())


def test_add_signal_handler_accepts_keywords():
    async def main():
        loop = asyncio.get_running_loop()
        fired = asyncio.Event()

        def on_signal():
            fired.set()

        try:
            loop.add_signal_handler(sig=signal.SIGUSR1, callback=on_signal)
            os.kill(os.getpid(), signal.SIGUSR1)
            await asyncio.wait_for(fired.wait(), 5)
        finally:
            assert loop.remove_signal_handler(signal.SIGUSR1) is True

    talyn.run(main())


def test_child_handler_accepts_keywords():
    async def main():
        loop = asyncio.get_running_loop()
        proc = subprocess.Popen(["sleep", "0.1"])
        pid = proc.pid
        result = []

        def callback(child_pid, returncode):
            result.append((child_pid, returncode))

        loop.add_child_handler(pid=pid, callback=callback)

        start = time.time()
        while not result and time.time() - start < 2.0:
            await asyncio.sleep(0.01)

        assert result == [(pid, 0)]
        proc.wait()

        assert loop.remove_child_handler(pid=pid) is False

    talyn.run(main())


def test_datagram_transport_accepts_keywords():
    class Protocol(asyncio.DatagramProtocol):
        def __init__(self):
            self.received = []

        def datagram_received(self, data, addr):
            self.received.append(data)

    async def main():
        loop = asyncio.get_running_loop()
        transport, protocol = await loop.create_datagram_endpoint(
            Protocol, local_addr=("127.0.0.1", 0)
        )
        try:
            port = transport.get_extra_info("sockname")[1]

            transport.set_write_buffer_limits(high=4096, low=1024)
            assert transport.get_write_buffer_limits() == (1024, 4096)

            transport.sendto(data=b"kw", addr=("127.0.0.1", port))

            start = time.time()
            while not protocol.received and time.time() - start < 2.0:
                await asyncio.sleep(0.01)

            assert protocol.received == [b"kw"]
        finally:
            transport.close()

    talyn.run(main())
