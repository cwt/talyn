import asyncio
import talyn
import pytest
import socket

@pytest.mark.asyncio
async def test_create_server_localhost_multi():
    loop = asyncio.get_running_loop()
    
    class MyProto(asyncio.Protocol):
        pass

    # localhost should resolve to both IPv4 and IPv6 loopback
    server = await loop.create_server(MyProto, 'localhost', 0)
    try:
        sockets = server.sockets
        # Should be at least one, usually two on modern linux (127.0.0.1 and ::1)
        assert len(sockets) >= 1
        
        # Verify we can connect to one
        addr = sockets[0].getsockname()
        reader, writer = await asyncio.open_connection(addr[0], addr[1])
        writer.close()
        await writer.wait_closed()
        
    finally:
        server.close()
        await server.wait_closed()

@pytest.mark.asyncio
async def test_create_server_external_host_error():
    loop = asyncio.get_running_loop()
    
    class MyProto(asyncio.Protocol):
        pass

    # google.com should resolve to some public IPs
    # binding to them should fail with OSError (Cannot assign requested address)
    with pytest.raises(OSError) as excinfo:
        await loop.create_server(MyProto, 'google.com', 8888)
    
    # On Linux this is EADDRNOTAVAIL (99)
    # The message or errno might vary depending on how it's raised
    assert excinfo.value.errno == 99 or "any address" in str(excinfo.value) or "requested address" in str(excinfo.value)
