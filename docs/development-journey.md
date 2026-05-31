# Talyn Development Journey

I have been obsessed with Python's AsyncIO for many years. If you check my GitHub, you’ll see many projects built around it — [ananta](https://github.com/cwt/ananta), [aiosyslogd](https://github.com/cwt/aiosyslogd), [wormhole](https://github.com/cwt/wormhole), and others.

One day, I asked Gemini to do a deep research on AsyncIO and its equivalents in other languages. The report highlighted how promising Zig + `io_uring` could be. I then asked why no one had built an event loop using Zig and `io_uring` similar to `uvloop`. Gemini pointed me to the [original Leviathan project](https://github.com/kython28/leviathan), which had impressive benchmark results.

---

I wanted to try it right away, but I soon discovered that Leviathan was incomplete and had been inactive for about a year. That’s when I thought: “Hey, we’re in the AI coding era — why don’t I try to complete it myself?”

And so the fork began.

I cloned the [uvloop repository](https://github.com/MagicStack/uvloop) and had my AI agents study it thoroughly. My initial prompt was: “Study uvloop, list all the features Leviathan is missing, and create a TODO list.” This became the start of [docs/todo.md](todo.md) — which began as one giant monolithic markdown file.

To prevent hallucinations and maintain high standards, I created a strict validation script: [scripts/test_all.sh](../scripts/test_all.sh). It builds and tests against four Python versions (3.13, 3.14, 3.13t, and 3.14t), with a simple golden rule: **zero errors and zero warnings**.

The agents worked quickly and implemented most missing features. Once I felt we had enough, I added the full official Python AsyncIO test suite to the testing process. That’s when everything broke.

The Python AsyncIO test suite is **brutal**. We spent a long time fixing bug after bug. This phase became the foundation of [docs/lessons-learned.md](lessons-learned.md).

During this period, we hit one extremely stubborn “perma-bug” related to SSL/TLS and the `test_streams` suite ([Priority 20](priorities/20-tls-ssl-completion-2026-05.md)). It caused repeated crashes, segfaults, and hangs. For days and weeks, none of my AI models could solve it.

I refused to skip it. I told the agents: “No, we have to pass the entire standard test suite, or this project is just a waste of code.”

My Gemini CLI started degrading as Google was sunsetting it, so I switched to antigravity-cli with Gemini 3.5 flash (max - full thinking quota). I let it run overnight. My quota ran out around midnight, but I woke up, checked the machine, and continued in the morning when it reset. Hours later, the bug was finally fixed.

After that breakthrough, we eventually passed all tests.

---

Then came the next reality check: **benchmarks**.

Leviathan was slow — much slower than expected. So we entered a serious optimization phase. My agents analyzed bottlenecks deeply and we created many new priority documents. We optimized for days. Performance improved gradually, but we are still behind `uvloop` and in some cases even standard `asyncio`.

This experience led to an important shift in the project’s direction.

**Talyn is no longer trying to be an “ultra-fast event loop”.** Instead, it has become a **realistic fast and stable** alternative — one that prioritizes correctness, reliability, and production readiness over chasing benchmark records.

## Performance Journey to v0.5.0

As of changeset 566, our preliminary benchmark results on Python [3.14](benchmarks-566-3.14.txt) and [3.14t](benchmarks-566-3.14t.txt) were promising. But there was a massive catch: those benchmarks were run on a **Debug** build!

When I finally compiled a **ReleaseSafe** build (our `--starburst` mode), everything broke. The optimized build exposed severe, hidden concurrency bugs, especially under free-threading. I tried to isolate the bugs by compiling only the `io` module in `Debug` mode while keeping the rest of the modules in `ReleaseSafe`. While this hybrid approach worked well for a while, it still wasn't 100% stable under high stress. 

At that point, I suspected that my main development machine (an Intel Core Ultra 7 265) was simply too powerful. Its sheer speed and fast core switching were effectively hiding real, subtle race conditions and timing-dependent deadlocks. 

To flush these bugs out, I switched my development environment to my mini PC powered by a much slower Intel N6000 CPU. The resource-constrained processor immediately exposed the race conditions, deadlocks, and scheduling issues. I spent days debugging and iterating on this mini PC until we resolved every single crash, hang, and deadlock, finally bringing us to a rock-solid, production-grade **v0.5.0**.

Here are the fresh, fully optimized benchmark results in `ReleaseSafe` mode for v0.5.0:
- Python [3.14](benchmarks-v0.5.0-3.14.txt)
- Python [3.14t](benchmarks-v0.5.0-3.14t.txt)

**Key observations:**
- Talyn performs very close to standard `asyncio` in many real-world-like workloads (Chat, Food Delivery, Subprocess, etc.).
- It shows great scaling and stability on free-threaded Python (3.14t) even under high concurrency.
- It is still noticeably behind `uvloop` in raw socket-heavy and task-spawning workloads under standard GIL Python, but is highly competitive and stable under free-threading.

---

This project has been a long, humbling, and incredibly rewarding journey. From an inactive, crash-prone prototype to a stable, fully test-suite-passing event loop built with the help of a swarm of AI agents.

And that’s how Talyn came to life.
