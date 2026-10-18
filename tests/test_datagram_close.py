"""BUG-367 regression tests.

``DatagramTransport.close()`` violated the asyncio contract two ways:
it never scheduled ``protocol.connection_lost(None)`` (the callback was
cached by ``set_protocol`` but never dispatched anywhere), and it left
``instance.fixed_file_index`` registered in io_uring's fixed-file table.
The table holds a kernel-level fget reference on the struct file, so
closing the userspace fd alone kept the kernel UDP socket alive — and
the UDP port bound — until the Python transport was garbage-collected:
an immediate re-bind of the same port failed with ``EADDRINUSE``.
"""

import asyncio

import talyn


def _udp_port_bound(port: int) -> bool:
    """Whether /proc/net/udp (v4) currently lists ``port`` as bound —
    a socket kept alive only by io_uring's fixed-file table is still
    listed, which is exactly what close() must have released."""
    with open("/proc/net/udp") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            try:
                _, local_port_hex = parts[1].split(":")
            except ValueError:
                continue
            if int(local_port_hex, 16) == port:
                return True
    return False


def test_bug367_datagram_close_dispatches_connection_lost():
    lost_results = []

    def run_once() -> None:
        async def main() -> None:
            loop = asyncio.get_running_loop()
            lost = loop.create_future()

            class Protocol(asyncio.DatagramProtocol):
                def connection_made(self, transport) -> None:
                    self.transport = transport

                def datagram_received(self, data, addr) -> None:
                    pass

                def error_received(self, exc) -> None:
                    pass

                def connection_lost(self, exc) -> None:
                    if not lost.done():
                        lost.set_result(exc)

            transport, protocol = await loop.create_datagram_endpoint(
                Protocol, local_addr=("127.0.0.1", 0)
            )
            port = transport.get_extra_info("sockname")[1]
            transport.close()

            # asyncio contract: close() must deliver connection_lost(None)
            # via call_soon, within the same running loop.
            exc = await asyncio.wait_for(lost, 5.0)
            assert exc is None, f"expected None, got {exc!r}"
            lost_results.append(port)

        talyn.run(main())

    run_once()
    assert lost_results, "connection_lost never reached the protocol"


def test_bug367_datagram_close_releases_fixed_file_port():
    ports: list = []

    async def main():
        loop = asyncio.get_running_loop()

        class Protocol(asyncio.DatagramProtocol):
            def connection_made(self, transport) -> None:
                self.transport = transport

            def datagram_received(self, data, addr) -> None:
                pass

            def error_received(self, exc) -> None:
                pass

            def connection_lost(self, exc) -> None:
                pass

        transport, _ = await loop.create_datagram_endpoint(
            Protocol, local_addr=("127.0.0.1", 0)
        )
        port = transport.get_extra_info("sockname")[1]
        transport.close()
        # BUG-366-free control: the run returns the (still referenced!)
        # protocol-side transport so the Python object outlives the loop:
        # only an io_uring fixed-file unregistration can free the kernel
        # socket in that window; a deferred dealloc cleanup would not.
        return (transport, port)

    transport, port = talyn.run(main())
    ports.append(port)

    # Pre-fix the kernel socket stayed alive through the fixed-file table
    # (the userspace fd was closed, the fget reference was not): the port
    # still shows in /proc/net/udp while the transport object is alive.
    assert not _udp_port_bound(port), (
        f"UDP port {port} still bound after transport.close(): the "
        f"fixed-file table held the kernel socket until GC dealloc"
    )
    _ = transport  # keep the Python object alive through the assertion


def test_bug367_datagram_close_then_rebind_same_port():
    """The strongest contract check: closing the transport while the
    Python object is still referenced must release the port so a new
    datagram endpoint can bind the same ephemeral port."""

    async def main():
        loop = asyncio.get_running_loop()

        class Protocol(asyncio.DatagramProtocol):
            def connection_made(self, transport) -> None:
                self.transport = transport

            def datagram_received(self, data, addr) -> None:
                pass

            def error_received(self, exc) -> None:
                pass

            def connection_lost(self, exc) -> None:
                pass

        transport, _ = await loop.create_datagram_endpoint(
            Protocol, local_addr=("127.0.0.1", 0)
        )
        port = transport.get_extra_info("sockname")[1]
        transport.close()
        return (transport, port)

    old_transport, port = talyn.run(main())
    _ = old_transport  # still referenced in Python: no dealloc cleanup yet

    # A fresh exclusive bind reusing the exact port must succeed once the
    # fixed-file reference is gone (no daemon processes involved).
    import socket

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(("127.0.0.1", port))
    finally:
        sock.close()
