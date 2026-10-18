"""BUG-375 regression tests.

SSL transport data-loss bugs in talyn/loop.py:

- ``_SSLTransportWrapper.write`` dropped application plaintext on
  ``SSLWantReadError`` / ``SSLWantWriteError`` (TLS 1.3
  post-handshake traffic) and ignored the partial-write return of
  ``_sslobj.write``.
- ``_flush_write_buffer`` (and the ``SP`` state machines in
  ``_create_ssl_connection``) wrote ciphertext straight into the
  socket with ``os.write()`` when the raw transport was paused: the
  tail was lost on ``BlockingIOError`` (truncated TLS records —
  peer-side ``BAD_RECORD_MAC``) and the raw syscalls interleaved with
  queued ``io_uring`` writes.
- ``resume_writing()`` did not drain the wrapper's stranded plaintext
  write buffer.
- a failed handshake raised out of ``await waiter`` (``ssl.SSLError``
  or cancellation) without closing the raw transport when
  ``ssl_handshake_timeout`` was configured — the error path only
  closed the transport when the timeout itself fired.
"""

import ssl
import time

import pytest

import talyn

talyn.install()

import asyncio

from talyn.loop import _SSLTransportWrapper

pytestmark = pytest.mark.filterwarnings("ignore::DeprecationWarning")


class _FakeSSLObj:
    """Scriptable stand-in for ssl.SSLSocket/MemoryBIO outputs."""

    def __init__(self, outcomes):
        self._outcomes = list(outcomes)
        self.consumed = []

    def write(self, data):
        self.consumed.append(bytes(data))
        if not self._outcomes:
            return len(data)
        outcome = self._outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


class _FakeSSP:
    def __init__(self, outcomes):
        self._ssl_writing_paused = False
        self._write_wants_read = False
        self._write_wants_write = False
        self._sslobj = _FakeSSLObj(outcomes)
        self.flushed = 0

    def _f(self):
        self.flushed += 1


class _PausedRawTransport:
    """Raw transport whose write() raises the paused error.

    ``get_extra_info`` raises so that any surviving os.write() bypass
    (the pre-fix fallback) fails loudly instead of silently losing the
    tail bytes.
    """

    def write(self, data):
        raise RuntimeError("Writing operations are paused")

    def get_extra_info(self, name, default=None):
        raise AttributeError("no sockets behind a paused fake transport")

    def close(self):
        pass


def test_bug375_write_buffers_plaintext_on_sslwant_read():
    ssp = _FakeSSP([ssl.SSLWantReadError()])
    wrapper = _SSLTransportWrapper(ssp, object(), ssl)

    wrapper.write(b"payload")

    assert ssp._sslobj.consumed == [b"payload"]
    # Pre-fix the want-path DROPPED the plaintext: the buffer stayed empty.
    assert wrapper._write_buffer == [memoryview(b"payload")]
    assert ssp.flushed == 1


def test_bug375_write_buffers_plaintext_on_sslwant_write():
    ssp = _FakeSSP([ssl.SSLWantWriteError()])
    wrapper = _SSLTransportWrapper(ssp, object(), ssl)

    wrapper.write(b"payload")

    assert ssp._sslobj.consumed == [b"payload"]
    assert wrapper._write_buffer == [memoryview(b"payload")]


def test_bug375_write_buffers_unconsumed_partial_plaintext():
    ssp = _FakeSSP([5])  # only 5 of 10 bytes consumed by _sslobj.write
    wrapper = _SSLTransportWrapper(ssp, object(), ssl)

    wrapper.write(b"0123456789")

    assert ssp._sslobj.consumed == [b"0123456789"]
    # Pre-fix the return value was ignored: nothing was buffered.
    assert len(wrapper._write_buffer) == 1
    assert bytes(wrapper._write_buffer[0]) == b"56789"


def test_bug375_flush_requeues_cipher_when_raw_paused():
    ssp = _FakeSSP([])
    outgoing = ssl.MemoryBIO()
    ssp._outgoing = outgoing
    wrapper = _SSLTransportWrapper(ssp, _PausedRawTransport(), ssl)

    outgoing.write(b"cipher-record")
    wrapper._flush_write_buffer()

    # Pre-fix this was an os.write() bypass: either the tail was lost on
    # EAGAIN or (with no socket behind the fake) everything vanished.
    assert outgoing.read() == b"cipher-record"


def test_bug375_flush_write_buffer_requeues_partial_remainder():
    # First call consumes 3 of 6 bytes; the immediate retry of the
    # remainder then blocks (want-write) and must stop the drain with
    # the remainder requeued.
    ssp = _FakeSSP([3, ssl.SSLWantWriteError()])
    wrapper = _SSLTransportWrapper(ssp, object(), ssl)

    wrapper._write_buffer.append(b"abcdef")
    wrapper._flush_write_buffer()

    assert ssp._sslobj.consumed == [b"abcdef", b"def"]
    assert len(wrapper._write_buffer) == 1
    assert bytes(wrapper._write_buffer[0]) == b"def"
    assert ssp._write_wants_write is True


class _BareClientProtocol(asyncio.BaseProtocol):
    def connection_made(self, transport):
        pass

    def connection_lost(self, exc):
        pass


class _StallServerProtocol(asyncio.Protocol):
    """Plain server: accepts but never answers the TLS handshake."""

    def __init__(self):
        self.lost = False

    def connection_made(self, transport):
        self.transport = transport

    def connection_lost(self, exc):
        self.lost = True


class _EchoGarbageServerProtocol(asyncio.Protocol):
    """Plain server that mirrors the ClientHello back.

    The client's do_handshake() reads its own ClientHello as ServerHello
    and fails with an ssl.SSLError long before any handshake timeout.
    """

    def __init__(self):
        self.lost = False

    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        self.transport.write(data)

    def connection_lost(self, exc):
        self.lost = True


def _make_bare_client():
    return _BareClientProtocol()


def _run_client_ssl_connect(server, host, port, handshake_timeout):
    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE
    return asyncio.get_running_loop().create_connection(
        _make_bare_client,
        host,
        port,
        ssl=client_ctx,
        ssl_handshake_timeout=handshake_timeout,
    )


async def _assert_raw_closed(served_protocols):
    # Post-fix the failed handshake closed the RAW client transport:
    # the server side must observe connection_lost. Pre-fix the raw
    # transport leaked and the socket stayed open forever.
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        if served_protocols and served_protocols[0].lost:
            return
        await asyncio.sleep(0.05)
    pytest.fail(
        "the server never saw the connection close: the failed "
        "handshake leaked the raw transport socket"
    )


@pytest.mark.asyncio
async def test_bug375_handshake_ssl_error_closes_raw_transport():
    served_protocols = []

    def make_echo_garbage():
        protocol = _EchoGarbageServerProtocol()
        served_protocols.append(protocol)
        return protocol

    loop = asyncio.get_running_loop()
    server = await loop.create_server(make_echo_garbage, "127.0.0.1", 0)
    host, port = server.sockets[0].getsockname()[:2]

    got = None
    try:
        # A long timeout so the branch is active but never fires: the
        # handshake fails fast on its own instead.
        await _run_client_ssl_connect(server, host, port, 5.0)
    except BaseException as exc:
        got = exc

    server.close()
    await asyncio.sleep(0)
    assert got is not None, "the mirrored-ClientHello handshake must fail"
    await _assert_raw_closed(served_protocols)


@pytest.mark.asyncio
async def test_bug375_handshake_cancel_closes_raw_transport():
    served_protocols = []

    def make_stall():
        protocol = _StallServerProtocol()
        served_protocols.append(protocol)
        return protocol

    loop = asyncio.get_running_loop()
    server = await loop.create_server(make_stall, "127.0.0.1", 0)
    host, port = server.sockets[0].getsockname()[:2]

    task = asyncio.ensure_future(_run_client_ssl_connect(server, host, port, 5.0))
    # Cancel mid-handshake (the server stalls, so the handshake is still
    # in progress).
    await asyncio.sleep(0.1)
    task.cancel()
    cancelled = False
    try:
        await task
    except asyncio.CancelledError:
        cancelled = True

    server.close()
    await asyncio.sleep(0)
    assert cancelled, "the cancelled handshake task must raise CancelledError"
    await _assert_raw_closed(served_protocols)
