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
- **Test results:** 268 internal tests + standard asyncio suite modules PASS on all 4 versions (3.13, 3.14, 3.13t, 3.14t). UDP Ping-Pong matches standard asyncio.

---

