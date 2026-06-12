import asyncio
import socket

import pytest

import talyn


def test_getaddrinfo_literal_ipv4() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        result = await loop.getaddrinfo("127.0.0.1", 80)
        assert len(result) == 1
        fam, typ, proto, canon, sockaddr = result[0]
        assert fam == socket.AF_INET
        assert typ == socket.SOCK_STREAM
        assert sockaddr == ("127.0.0.1", 80)

    talyn.run(main())


def test_getaddrinfo_multiple() -> None:
    """Multiple calls should work."""

    async def main() -> None:
        loop = asyncio.get_running_loop()
        r1 = await loop.getaddrinfo("127.0.0.1", 80)
        r2 = await loop.getaddrinfo("127.0.0.1", 443)
        assert len(r1) == 1
        assert len(r2) == 1
        assert r1[0][4] == ("127.0.0.1", 80)
        assert r2[0][4] == ("127.0.0.1", 443)

    talyn.run(main())


def test_getaddrinfo_different_port() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        result = await loop.getaddrinfo("127.0.0.1", 443)
        sockaddr = result[0][4]
        assert sockaddr[1] == 443

    talyn.run(main())


def test_getaddrinfo_missing_host() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises((ValueError, TypeError)):
            await loop.getaddrinfo(None, 80)

    talyn.run(main())


def test_getaddrinfo_returns_tuple() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        result = await loop.getaddrinfo("127.0.0.1", 80)
        assert isinstance(result, tuple)
        assert len(result) > 0
        entry = result[0]
        assert isinstance(entry, tuple)
        assert len(entry) == 5

    talyn.run(main())


def test_getaddrinfo_localhost_hostname() -> None:
    """Regression test for e1db5b9: ControlData.record_evicted uninitialized.

    In ReleaseSafe (--starburst) builds the field-by-field initialization of
    ControlData in prepare_data left record_evicted as garbage bytes.  When
    those bytes were non-zero the DNS resolution callback skipped writing the
    resolved addresses into the cache record, so the second dns.lookup() call
    (inside host_resolved_callback) found no resolved data and raised
    "Failed to resolve host".

    This test resolves "localhost" through getaddrinfo, which follows the full
    async DNS code path (unlike a raw IP which is handled synchronously).
    """

    async def main() -> None:
        loop = asyncio.get_running_loop()
        # getaddrinfo("localhost", ...) goes through the async resolver path
        # because "localhost" must be looked up (via /etc/hosts or DNS).
        result = await loop.getaddrinfo("localhost", 80, type=socket.SOCK_STREAM)
        assert result, "getaddrinfo returned empty list — DNS resolution failed"
        fam, typ, proto, canon, sockaddr = result[0]
        assert fam in (socket.AF_INET, socket.AF_INET6)
        host_addr = sockaddr[0]
        assert host_addr in ("127.0.0.1", "::1"), (
            f"Expected loopback address, got {host_addr!r}"
        )

    talyn.run(main())


def test_getaddrinfo_repeated_resolution_same_hostname() -> None:
    """DNS resolution must succeed on repeated calls for the same hostname.

    Regression: if record_evicted is garbage-true, only the first call
    succeeds (or both fail).  After the fix the cache is written correctly
    and the second call can be served from cache.
    """

    async def main() -> None:
        loop = asyncio.get_running_loop()
        r1 = await loop.getaddrinfo("localhost", 80, type=socket.SOCK_STREAM)
        r2 = await loop.getaddrinfo("localhost", 443, type=socket.SOCK_STREAM)
        assert r1, "First getaddrinfo call returned empty — DNS failed"
        assert r2, (
            "Second getaddrinfo call returned empty — DNS failed (regression e1db5b9)"
        )
        # Both should resolve to a loopback address
        assert r1[0][4][0] in ("127.0.0.1", "::1")
        assert r2[0][4][0] in ("127.0.0.1", "::1")

    talyn.run(main())


def test_getaddrinfo_shorthand_ipv6() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        # Test standard IPv6 shorthand notation "1::2"
        # Since it's a numeric IP, getaddrinfo will parse it synchronously.
        result = await loop.getaddrinfo("1::2", 80)
        assert len(result) > 0
        fam, typ, proto, canon, sockaddr = result[0]
        assert fam == socket.AF_INET6
        assert sockaddr[0] == "1::2"
        assert sockaddr[1] == 80

        # Test "::1"
        result = await loop.getaddrinfo("::1", 80)
        assert len(result) > 0
        assert result[0][4][0] == "::1"

        # Test "2001:db8::ff00:42:8329"
        result = await loop.getaddrinfo("2001:db8::ff00:42:8329", 80)
        assert len(result) > 0
        assert result[0][4][0] == "2001:db8::ff00:42:8329"

    talyn.run(main())

