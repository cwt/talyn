[⬅️ Back to Index](todo.md)

# ✅ Completed Next Steps

1.  **`create_server` DNS** — ✅ Already implemented with async state machine (same callback pattern as `create_connection`). Added `host=None` support (binds to all interfaces: IPv4 + IPv6).
2.  **Universal Sockaddr Handling** — ✅ Already in place. Address resolution uses `std.net.Address` throughout; family is detected dynamically from `address.any.family`.
3.  **`getnameinfo`** — ✅ Already implemented at `src/loop/python/io/socket/getnameinfo.zig`. Registered as `loop.getnameinfo`.

---

# 🛠 Scripts

- `scripts/test_all.sh` — Automated build+test for all 4 Python versions (3.13, 3.14, 3.13t, 3.14t). Auto-detects free-threading, runs zig unit tests, and verifies standard `test.test_asyncio` modules.

---

# Reference

- **uvloop source:** https://github.com/MagicStack/uvloop
- **Test results (2026-05-21):** 7 project SSL tests PASS. Standard asyncio suite: `test_futures` (181), `test_transports` (7), `test_protocols` (5), `test_runners` (29) all PASS. `test_streams`: 73/75 pass, 2 TLS-related tests hang (`test_start_tls_buffered_data`, `test_open_connection_no_loop_ssl`). See [Priority 20](priorities/20-tls-ssl-completion-2026-05.md).

---

