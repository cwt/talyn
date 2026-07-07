---
type: lessons_learned
title: Security & Input Validation Lessons
description: Network payload parsing, validation rules, buffer boundaries, and secure coding practices.
tags: [security, input-validation, parsing, safety]
timestamp: 2026-07-07T15:35:00Z
---

[⬅️ Back to Lessons Index](./index.md)

# Security & Input Validation

Lessons about DNS security, protocol input validation, parser strictness, and preventing cache poisoning.

---

### DNS Security

**Lesson 29 — Predictable DNS Transaction IDs**
In `build_queries`, the DNS query transaction ID was set by casting the loop iteration index (`0, 1, 2, ...`) directly to `u16`. Sequential and predictable transaction IDs make DNS cache poisoning and domain spoofing trivial for an on-path attacker.
- **Fix:** Replaced `@intCast(index)` with `std.os.linux.getrandom` to generate a cryptographically secure random transaction ID for each query.
- **Lesson:** Network protocols relying on transaction IDs for security (like DNS) must use **unpredictable random values**, not sequential counters. Always use a CSPRNG (e.g., the `getrandom` Linux syscall) for security-sensitive identifiers. Sequential counters in DNS queries are a well-known vulnerability (CVE-2008-1447 and related).

**Lesson 34 — DNS Response Transaction ID Validation**
`process_dns_response` read the transaction ID from the response header but never validated it against query IDs that were actually sent. Any DNS response arriving on the socket was accepted, making DNS cache poisoning trivial.
- **Fix:** Added `query_ids` field to `ServerQueryData`. In `build_queries`, each generated query ID is stored. In `process_dns_response`, the response transaction ID is checked against all stored query IDs; responses with no match are rejected.
- **Lesson:** Network protocols using transaction IDs for request/response matching **must** validate that incoming responses correspond to outstanding requests. Without validation, attackers can inject forged responses. This is especially critical for DNS where cache poisoning can redirect traffic to malicious servers.

---

### Parser Strictness

**Core rule:** Be strict in what you accept. "Be liberal in what you accept" (Postel's law) leads to security vulnerabilities and interoperability bugs in modern systems.

**Lesson 33 — DNS Parser Out-of-Bounds Read on Compression Pointer**
In `parse_name`, when encountering a DNS compression pointer, the code read `full_data[offset + 1]` without checking if `offset + 1` was within bounds. If the compression pointer byte was the last byte, this was an out-of-bounds read.
- **Fix:** Added bounds check: `if (offset + 1 >= full_data.len) return error.MalformedDnsResponse;`
- **Lesson:** When parsing network protocols with pointer-like structures (offsets, indices, compression pointers), always validate the referenced location is within bounds **before** dereferencing. DNS compression pointers are particularly tricky — they can point anywhere in the message, including to themselves (creating loops) or beyond the end.

**Lesson 58 — Zero-Padding is a Silent Bug for Parsers**
In `Address.parseIp6`, the "no `::` in address" branch didn't check that `group_i == 8`. Given `2001:db8:1` (3 groups, no `::`), the parser wrote 3 groups and left the remaining 10 bytes as zero — silently interpreting `2001:db8:1` as `2001:0db8:0001::`.
- **Fix:** Added check: `if (group_i != 8) return error.IncompleteAddress;`
- **Lesson:** **Zero-padding is a silent bug for parsers.** The most dangerous kind of bug is silently accepting a malformed input by filling in "reasonable defaults". The fix: make the parser **strict by default**. If the input doesn't match the expected structure exactly, reject it. This is especially important for:
  - Network addresses (wrong connection target = security issue)
  - File paths (wrong path = data loss)
  - Protocol headers (wrong field = misinterpretation)
  - Date/time formats (wrong timezone = logic bug)

**Lesson 91 — Reject Ambiguous Numeric Formats**
In `parseIp4`, octets with leading zeros (e.g., `010`) were parsed as decimal 10. Some system parsers (notably older glibc) treat them as octal 8, causing address mismatches with system tools.
- **Fix:** Reject octets with leading zeros (except for the single digit `0`). Matches the behavior of `inet_pton` and Python's `ipaddress` module.
- **Lesson:** **Reject ambiguous numeric formats.** When different parsers disagree on the meaning of a format (leading zeros → decimal vs octal), reject the ambiguous form. The "be lenient" approach leads to SSRF vulnerabilities (URL parsing), injection attacks (JSON), XSS (HTML), and path traversal (filenames).

**Lesson 92 — Validate Invariants After Parsing**
In `parseIp6`, the `::` branch didn't validate that the total number of groups was at most 8. An address like `1:2:3:4:5:6:7::8` was accepted; the `::` expansion computed `target_i = 8` and wrote bytes at offset 16+, corrupting the byte layout.
- **Fix:** Added check: `if (group_i >= 8) return error.InvalidIPAddressFormat;`
- **Lesson:** **Validate invariants after parsing, not just during parsing.** Pattern:
  - During parsing: check individual tokens, character classes, length bounds.
  - After parsing: check that the overall structure makes sense.
  "Individual token checks are enough" misses cases where each token is valid but the combination is not (URL components valid but combination is SSRF, HTML tags valid but nesting is wrong).

---

### Configuration & Resource Management Security

**Lesson 96 — Make Every Timeout Configurable**
`_create_ssl_unix_connection` used a hardcoded 60s timeout and didn't accept `ssl_handshake_timeout` as a parameter — callers had no way to override it.
- **Fix:** Added `ssl_handshake_timeout: float | None = None` parameter, threaded it through from the public wrapper.
- **Lesson:** **Make every timeout configurable.** Hardcoded timeouts cause flakiness on slow networks and make libraries unusable in constrained environments. Provide a sensible default but always expose the parameter. A configurable parameter costs 1 line; a non-configurable timeout costs hours of debugging.
