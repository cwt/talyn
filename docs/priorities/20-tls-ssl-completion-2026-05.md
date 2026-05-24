[⬅️ Back to Index](../todo.md)

# 🔴 PRIORITY 20: TLS/SSL Completion (2026-05-21)

Make Leviathan's SSL wrapper fully compatible with the standard `test_streams`
test suite. The core architecture — Python `ssl.MemoryBIO` over raw Zig transport —
is sound and mirrors uvloop's proven approach. The remaining work is incremental
bug fixes in the Python-layer protocol shim.

## Current Status

| Suite | Result |
|-------|--------|
| `tests/test_ssl.py` (7 tests) | ✅ ALL PASS |
| `test.test_asyncio.test_streams.test_start_tls` | ✅ PASS |
| `test.test_asyncio.test_streams.test_start_tls_buffered_data` | 🔴 HANGS |
| `test.test_asyncio.test_streams.test_open_connection_no_loop_ssl` | 🔴 HANGS |
| Other std test modules (futures, transports, protocols, runners) | ✅ ALL PASS |

**Root cause:** Every failing test involves TLS over the standard `asyncio`
high-level streams API (StreamReader/StreamWriter), which exercises edge
cases our current implementation doesn't handle:
- Buffered data from old protocol not fed to new SSL protocol during `start_tls`
- `_SSLTransportWrapper.close()` not performing proper SSL shutdown sequence
- No `pause_writing`/`resume_writing` backpressure for SSL writes

## Architecture (Mirrors uvloop)

```
Application Protocol
        ↑
_SSLTransportWrapper  (user-facing transport, encrypts writes)
        ↑
_SP (BufferedProtocol)  ← ssl.MemoryBIO + sslobj.wrap_bio → decrypts/encrypts
        ↑
StreamTransport (Zig/io_uring)  ← raw encrypted bytes only
```

uvloop uses exactly the same pattern in `sslproto.pyx` (1007 lines of Cython):
`ssl.MemoryBIO` + `wrap_bio` + protocol wrapping. **Zero** SSL in the native
transport layer. Our approach is correct — we just need to finish the edge cases.

## Sub-Tasks (Incremental, One at a Time)

### ✅ Prerequisite: `set_protocol` (DONE)
Zig `StreamTransport.set_protocol()` at `src/transports/stream/main.zig:115`
allows swapping the protocol at runtime for `start_tls`. Already in working copy.

---

### ✅ Task 1: Feed Buffered Data to SSL Handshake in `start_tls` (DONE)

**Problem:** When `start_tls()` is called via `StreamWriter.start_tls()`, the
StreamReader may have already buffered incoming TLS ClientHello bytes. Our
`_SP.connection_made()` calls `do_handshake()` → `SSLWantReadError`, but the
buffered data is in the old StreamReaderProtocol, not the transport. Deadlock.

**What `test_start_tls_buffered_data` does:**
1. Client starts TLS → sends ClientHello
2. Server's StreamReader buffers ClientHello
3. Server calls `StreamWriter.start_tls()` → our `start_tls` swaps protocol
4. New `_SP` protocol needs ClientHello for handshake but it's in old reader

**Fix needed in `leviathan/loop.py:start_tls()`:**
- Before swapping protocol, extract any buffered data from the old protocol
- Feed it to the `_incoming` MemoryBIO before starting handshake
- Or: re-register the `data_received` callback to replay buffered data

**Files:** `leviathan/loop.py`

---

### ✅ Task 2: Proper SSL Shutdown in `_SSLTransportWrapper.close()` (DONE)

**Problem:** `close()` calls `sslobj.unwrap()` to send `close_notify`, but
doesn't wait for the peer's `close_notify` response. Standard asyncio expects
the transport to complete the TLS shutdown handshake before closing the
underlying socket.

**Fix needed in `leviathan/loop.py:_SSLTransportWrapper.close()`:**
- After `unwrap()`, read any remaining data from `_outgoing` bio and write it
- Wait for incoming `close_notify` (or timeout) before calling `_raw_t.close()`
- Handle `ssl_ssl_shutdown_timeout` parameter

**Files:** `leviathan/loop.py`

---

### ✅ Task 3: Flow Control (`pause_writing`/`resume_writing`) (DONE)

**Problem:** `_SSLTransportWrapper` delegates writes to the raw transport via
`_sslobj.write()` + `_f()`, but doesn't participate in asyncio's flow control.
If the underlying transport's write buffer is full, we need to propagate
backpressure up to the application protocol.

**Fix needed in `leviathan/loop.py:_SSLTransportWrapper`:**
- Proxy `pause_writing()` and `resume_writing()` from raw transport
- Ensure `write()` checks buffer state and returns appropriate control

**Files:** `leviathan/loop.py`

---

### ✅ Task 4: Fix `open_connection` with `ssl` Parameter (DONE)

**Problem:** `test_open_connection_no_loop_ssl` hangs. The `open_connection()`
high-level function with `ssl=True` creates an `_SSLProtocol` flow that may not
correctly return the wrapped transport to the StreamReader/StreamWriter pair.

**Fix needed in `leviathan/loop.py:_create_ssl_connection()`:**
- Audit the transport wrapping chain: raw transport → `_SP` → `_SSLTransportWrapper`
- Ensure `StreamWriter` receives `_SSLTransportWrapper`, not raw transport
- Ensure `StreamReader` receives decrypted data from `_SP`

**Files:** `leviathan/loop.py`

---

### ✅ Task 5: Full `test_streams` Pass (DONE)

Once tasks 1–4 are done, verify all 75 `test_streams` tests pass without hangs.
Run `scripts/test_all.sh` to confirm across all 4 Python variants.

**Files:** `scripts/test_all.sh`

---

## Files Involved

| File | Role |
|------|------|
| `leviathan/loop.py` | All SSL logic (`start_tls`, `_create_ssl_connection`, `_create_ssl_server`, `_SSLTransportWrapper`, `_SP`) |
| `src/transports/stream/main.zig` | `set_protocol` method (already done) |
| `src/transports/stream/constructors.zig` | `stream_set_protocol` C export (already done) |
| `tests/test_ssl.py` | 7 project tests covering SSL basics (all pass) |

## Reference

- **uvloop SSL:** `uvloop/sslproto.pyx` (1007 lines Cython) — same architecture
- **uvloop `start_tls`:** `uvloop/loop.pyx:1580-1633` — pause → swap protocol → connection_made → resume
- **Python stdlib:** `asyncio.sslproto.SSLProtocol` — CPython's reference implementation
