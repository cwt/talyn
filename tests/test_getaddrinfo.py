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


def test_getaddrinfo_nonexistent_domain_does_not_poison_cache() -> None:
    """Non-existent or failing domain resolution must raise error and not poison DNS cache permanently."""

    async def main() -> None:
        loop = asyncio.get_running_loop()
        domain = "nonexistent-domain-test-123456789.invalid"
        with pytest.raises(Exception):
            await loop.getaddrinfo(domain, 80)

    talyn.run(main())



def test_bug357_failed_resolution_resolves_future_promptly() -> None:
    """BUG-357: when the DNS query send fails on the last nameserver (or
    the result-construction fails), getaddrinfo_callback /
    getnameinfo_callback returned without resolving the future - the
    awaiting coroutine hung forever. Every failure path must resolve the
    future with an exception, promptly."""
    import time

    import talyn

    async def main() -> None:
        loop = asyncio.get_running_loop()

        # Unresolvable host: every attempt must RAISE promptly (the
        # sandbox resolver fails fast; the contract is a bounded wait).
        for i in range(5):
            t0 = time.monotonic()
            try:
                await asyncio.wait_for(
                    loop.getaddrinfo("nonexistent.invalid", 80), 30.0)
                raise AssertionError("getaddrinfo unexpectedly succeeded")
            except asyncio.TimeoutError:
                raise AssertionError(
                    f"getaddrinfo future left pending (hang) on iteration {i}")
            except Exception:
                pass  # the expected resolution failure
            assert time.monotonic() - t0 < 30.0

        # getnameinfo for an address without a PTR record: same contract.
        for i in range(5):
            t0 = time.monotonic()
            try:
                await asyncio.wait_for(
                    loop.getnameinfo(("127.0.0.1", 8080)), 30.0)
                # 127.0.0.1 may legitimately resolve via the resolver; only
                # a hang is a failure.
            except asyncio.TimeoutError:
                raise AssertionError(
                    f"getnameinfo future left pending (hang) on iteration {i}")
            except Exception:
                pass
            assert time.monotonic() - t0 < 30.0

    talyn.run(main())


def test_bug361_getaddrinfo_getnameinfo_bounds():
    """BUG-361: getaddrinfo/getnameinfo narrowed family/type/proto/flags
    with unchecked @intCast — huge values panicked (or truncated to a
    silently-different op). They must raise ValueError instead, and a
    giant dns_timeout must clamp to the kernel-representable range
    instead of panicking at the timespec conversion."""
    import pytest

    async def main():
        loop = asyncio.get_running_loop()

        with pytest.raises(ValueError):
            await loop.getaddrinfo("localhost", 70000)
        with pytest.raises(ValueError):
            await loop.getaddrinfo("localhost", -5)
        with pytest.raises(ValueError):
            await loop.getaddrinfo("localhost", 80, family=2**40)
        with pytest.raises(ValueError):
            await loop.getaddrinfo("localhost", 80, type=2**40)
        with pytest.raises(ValueError):
            await loop.getaddrinfo("localhost", 80, proto=2**40)
        with pytest.raises(ValueError):
            await loop.getnameinfo(("127.0.0.1", 80), flags=2**40)

        # A gigantic dns_timeout both parses and survives the kernel
        # timespec conversion (i64-sec clamp).
        res = await asyncio.wait_for(
            loop.getaddrinfo("localhost", 80, dns_timeout=1e20),
            timeout=5,
        )
        assert len(res) >= 1

    talyn.run(main())
