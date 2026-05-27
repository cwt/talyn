import gc
import asyncio
import socket
import leviathan

# Install leviathan event loop policy
leviathan.install()

def find_unused_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

port = find_unused_port()

async def main():
    exc = None
    try:
        # Happy eyeballs connection attempt to unused port
        await asyncio.open_connection(
            host="localhost",
            port=port,
            happy_eyeballs_delay=0.25,
        )
    except* OSError as excs:
        exc = excs.exceptions[0]
    
    print("Exception occurred:", exc)
    
    # Trace referrers of the exception object
    referrers = gc.get_referrers(exc)
    print("Referrers of exception:", referrers)
    
    # We expect only main_coro to refer to it.
    # If there is a leak, a leviathan.Future object might also refer to it.
    found_future_leak = False
    for ref in referrers:
        if "Future" in str(type(ref)):
            print("⚠️ Leak found! Future object still refers to exception:", ref)
            found_future_leak = True
            
    if not found_future_leak:
        print("✅ No Future object refers to the exception. No leak detected!")

main_coro = main()
asyncio.run(main_coro)
