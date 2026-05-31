import asyncio
import socket

import talyn


def test_sock_accept_connect():
    async def main():
        loop = asyncio.get_running_loop()
        
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(('127.0.0.1', 0))
        server_sock.listen(1)
        server_sock.setblocking(False)
        addr = server_sock.getsockname()
        
        async def run_server():
            try:
                client, client_addr = await loop.sock_accept(server_sock)
                try:
                    data = await loop.sock_recv(client, 1024)
                    assert data == b'hello'
                    await loop.sock_sendall(client, b'world')
                finally:
                    client.close()
            except Exception as e:
                print(f"SERVER ERROR: {e}")
                raise

        server_task = loop.create_task(run_server())
        
        client_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client_sock.setblocking(False)
        await loop.sock_connect(client_sock, addr)
        try:
            await loop.sock_sendall(client_sock, b'hello')
            data = await loop.sock_recv(client_sock, 1024)
            assert data == b'world'
        finally:
            client_sock.close()
            
        await server_task
        server_sock.close()

    talyn.run(main())

def test_sock_recvfrom_sendto():
    async def main():
        loop = asyncio.get_running_loop()
        
        sock1 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock1.bind(('127.0.0.1', 0))
        sock1.setblocking(False)
        addr1 = sock1.getsockname()
        
        sock2 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock2.bind(('127.0.0.1', 0))
        sock2.setblocking(False)
        addr2 = sock2.getsockname()
        
        async def run1():
            data, addr = await loop.sock_recvfrom(sock1, 1024)
            assert data == b'ping'
            assert addr == addr2
            await loop.sock_sendto(sock1, b'pong', addr)

        async def run2():
            await loop.sock_sendto(sock2, b'ping', addr1)
            data, addr = await loop.sock_recvfrom(sock2, 1024)
            assert data == b'pong'
            assert addr == addr1

        t1 = loop.create_task(run1())
        await run2()
        await t1
        sock1.close()
        sock2.close()

    talyn.run(main())

def test_sock_recv_into():
    async def main():
        loop = asyncio.get_running_loop()
        
        rsock, wsock = socket.socketpair()
        rsock.setblocking(False)
        wsock.setblocking(False)
        
        try:
            await loop.sock_sendall(wsock, b'hello')
            
            buf = bytearray(10)
            n = await loop.sock_recv_into(rsock, buf)
            assert n == 5
            assert buf[:5] == b'hello'
        finally:
            rsock.close()
            wsock.close()

    talyn.run(main())

def test_task_factory():
    async def main():
        loop = asyncio.get_running_loop()
        
        assert loop.get_task_factory() is None
        
        def my_factory(loop, coro, context=None):
            task = talyn.Task(coro, loop=loop, context=context)
            task.my_attr = "custom"
            return task
            
        loop.set_task_factory(my_factory)
        assert loop.get_task_factory() is my_factory
        
        async def dummy():
            return 42
            
        task = loop.create_task(dummy())
        assert task.my_attr == "custom"
        assert await task == 42
        
        loop.set_task_factory(None)
        assert loop.get_task_factory() is None
        
        task2 = loop.create_task(dummy())
        assert not hasattr(task2, "my_attr")
        await task2

    talyn.run(main())
