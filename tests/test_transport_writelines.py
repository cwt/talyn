"""BUG-377 regression test.

``transport_write_lines`` iterates with ``PyIter_Next``, which returns
``null`` both for an exhausted iterator and for a RAISING one. The
pre-fix code broke out of the loop on ``null`` without checking
``PyErr_Occurred()`` and returned ``Py_None`` with the generator's
exception still live on the thread state — raising ``SystemError``
(``... returned a result with an exception set``) at the C-API call
boundary instead of the generator's own exception (BUG-298 revisited).
"""

import pytest

import talyn

talyn.install()

import asyncio


class EchoProtocol(asyncio.Protocol):
    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        self.transport.write(data)

    def connection_lost(self, exc):
        pass


@pytest.mark.asyncio
async def test_bug377_writelines_iter_exception_propagates():
    loop = asyncio.get_running_loop()
    server = await loop.create_server(EchoProtocol, "127.0.0.1", 0)
    addr = server.sockets[0].getsockname()

    transport, protocol = await loop.create_connection(
        EchoProtocol, addr[0], addr[1]
    )
    try:
        def raising_iterable():
            yield b"chunk"
            raise ValueError("generator blew up")

        # Post-fix the generator's exception propagates from the C method;
        # pre-fix the boundary turned it into SystemError("... returned a
        # result with an exception set").
        with pytest.raises(ValueError):
            transport.writelines(raising_iterable())
    finally:
        transport.close()
        server.close()
