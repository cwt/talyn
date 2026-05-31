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
