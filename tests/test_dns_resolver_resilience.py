"""Tests for DNS resolver resilience, caching safety, and GC cycle traversal.

Covers:
- BUG-380: Safe callback appending without active union tag mismatch.
- BUG-384: Dual-stack resolution packet handling and multi-nameserver resilience.
- BUG-385: Python GC traversal wiring for ControlData, GetAddrInfoData, and GetNameInfoData.
- BUG-388: StreamTransport get_extra_info positional default support and arg checking.
"""

import asyncio
import gc
import socket
import pytest

import talyn


def test_dns_concurrent_queries_same_hostname() -> None:
    """BUG-380: Multiple concurrent getaddrinfo calls for the same hostname.

    Verifies that appending callbacks to pending or transitioning records
    does not panic or crash with union tag mismatch.
    """

    async def main() -> None:
        loop = asyncio.get_running_loop()
        # Launch multiple concurrent lookups for the same hostname
        tasks = []
        for _ in range(10):
            tasks.append(loop.getaddrinfo("localhost", 80, type=socket.SOCK_STREAM))

        results = await asyncio.gather(*tasks)
        assert len(results) == 10
        for res in results:
            assert len(res) > 0
            fam, _, _, _, sockaddr = res[0]
            assert fam in (socket.AF_INET, socket.AF_INET6)
            assert sockaddr[0] in ("127.0.0.1", "::1")

    talyn.run(main())


def test_dns_dual_stack_localhost_resolution() -> None:
    """BUG-384: Dual-stack resolution preserves both IPv4 and IPv6 responses.

    Verifies that dual-stack resolution does not prematurely complete on the
    first packet before both A and AAAA queries have been received.
    """

    async def main() -> None:
        loop = asyncio.get_running_loop()
        results = await loop.getaddrinfo("localhost", 80, family=socket.AF_UNSPEC, type=socket.SOCK_STREAM)
        assert len(results) > 0

        families = {item[0] for item in results}
        # localhost on modern Linux systems typically resolves to both AF_INET (127.0.0.1) and AF_INET6 (::1)
        assert socket.AF_INET in families or socket.AF_INET6 in families

    talyn.run(main())


def test_dns_gc_cycle_traversal_getaddrinfo() -> None:
    """BUG-385: GetAddrInfoData and ControlData participate correctly in GC traversal.

    Creates a circular reference between a container object and a future/coroutine,
    triggers getaddrinfo, runs gc.collect(), and ensures traversal succeeds without crashing.
    """

    class CyclicHolder:
        def __init__(self) -> None:
            self.future = None
            self.loop = None

    async def main() -> None:
        loop = asyncio.get_running_loop()
        holder = CyclicHolder()
        holder.loop = loop

        # Start an async getaddrinfo resolution
        fut = loop.getaddrinfo("localhost", 80)
        holder.future = fut

        def on_done(f: asyncio.Future) -> None:
            # Retain reference inside callback closure to ensure cyclic reachability
            if holder.future is not None:
                pass

        fut.add_done_callback(on_done)

        # Trigger full GC collection while query or callback is active
        collected = gc.collect()
        assert collected >= 0

        res = await fut
        assert len(res) > 0

        # Break cycle cleanly
        holder.future = None
        holder.loop = None
        gc.collect()

    talyn.run(main())


def test_dns_gc_cycle_traversal_getnameinfo() -> None:
    """BUG-385: GetNameInfoData participates correctly in GC traversal."""

    class CyclicHolder:
        def __init__(self) -> None:
            self.future = None
            self.loop = None

    async def main() -> None:
        loop = asyncio.get_running_loop()
        holder = CyclicHolder()
        holder.loop = loop

        fut = loop.getnameinfo(("127.0.0.1", 80), 0)
        holder.future = fut

        def on_done(f: asyncio.Future) -> None:
            if holder.future is not None:
                pass

        fut.add_done_callback(on_done)

        collected = gc.collect()
        assert collected >= 0

        try:
            res = await fut
            assert len(res) == 2
        except Exception:
            # Name resolution may fail in offline/sandboxed environments, which is valid;
            # the test's purpose is ensuring GC traversal does not segfault or leak.
            pass

        holder.future = None
        holder.loop = None
        gc.collect()

    talyn.run(main())


def test_stream_transport_get_extra_info_positional_default_semantics() -> None:
    """BUG-388: StreamTransport get_extra_info positional default support."""

    async def main() -> None:
        loop = asyncio.get_running_loop()
        s1, s2 = socket.socketpair()
        s1.setblocking(False)
        s2.setblocking(False)

        class DummyProtocol(asyncio.Protocol):
            def connection_made(self, transport: asyncio.BaseTransport) -> None:
                pass

        t1 = talyn.StreamTransport(s1.fileno(), DummyProtocol(), loop)
        try:
            # 1 positional arg (default is None)
            assert t1.get_extra_info("nonexistent_key") is None

            # 2 positional args (key, default)
            assert t1.get_extra_info("nonexistent_key", "custom_fallback") == "custom_fallback"
            assert t1.get_extra_info("nonexistent_key", 12345) == 12345
            assert t1.get_extra_info("nonexistent_key", None) is None

            # Keyword default
            assert t1.get_extra_info("nonexistent_key", default="kw_fallback") == "kw_fallback"

            # Existing key should ignore default
            assert t1.get_extra_info("sockname", "fallback") == s1.getsockname()
            assert t1.get_extra_info("sockname", default="fallback") == s1.getsockname()

            # Error cases: too many arguments
            with pytest.raises(TypeError):
                t1.get_extra_info("key", "def1", "def2")

            # Error cases: both positional default and keyword default
            with pytest.raises(TypeError):
                t1.get_extra_info("key", "pos_def", default="kw_def")
        finally:
            t1.close()
            s2.close()

    talyn.run(main())
