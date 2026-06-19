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

As of changeset 566, our preliminary benchmark results on Python [3.14](benchmarks/core-ultra-7-265/benchmarks-566-3.14.txt) and [3.14t](benchmarks/core-ultra-7-265/benchmarks-566-3.14t.txt) were promising. But there was a massive catch: those benchmarks were run on a **Debug** build!

When I finally compiled a **ReleaseSafe** build (our `--starburst` mode), everything broke. The optimized build exposed severe, hidden concurrency bugs, especially under free-threading. I tried to isolate the bugs by compiling only the `io` module in `Debug` mode while keeping the rest of the modules in `ReleaseSafe`. While this hybrid approach worked well for a while, it still wasn't 100% stable under high stress. 

At that point, I suspected that my main development machine (an Intel Core Ultra 7 265) was simply too powerful. Its sheer speed and fast core switching were effectively hiding real, subtle race conditions and timing-dependent deadlocks. 

To flush these bugs out, I switched my development environment to my mini PC powered by a much slower Intel N6000 CPU. The resource-constrained processor immediately exposed the race conditions, deadlocks, and scheduling issues. I spent days debugging and iterating on this mini PC until we resolved every single crash, hang, and deadlock, finally bringing us to a rock-solid, production-grade **v0.5.0**.

Here are the fresh, fully optimized benchmark results in `ReleaseSafe` mode for v0.5.0:
- Python [3.14](benchmarks/n6000/benchmarks-v0.5.0-3.14.txt)
- Python [3.14t](benchmarks/n6000/benchmarks-v0.5.0-3.14t.txt)

**Key observations:**
- Talyn performs very close to standard `asyncio` in many real-world-like workloads (Chat, Food Delivery, Subprocess, etc.).
- It shows great scaling and stability on free-threaded Python (3.14t) even under high concurrency.
- It is still noticeably behind `uvloop` in raw socket-heavy and task-spawning workloads under standard GIL Python, but is highly competitive and stable under free-threading.

## Performance & Stability: Reaching v0.6.0

With **v0.5.0** fully stable in `ReleaseSafe` mode, we turned our attention to the final barrier: **`ReleaseFast`** optimizations. For a long time, the project suffered from regressions when compiled with `ReleaseFast`—specifically failing standard Python AsyncIO test suites (`test_streams`). 

Through rigorous investigation, we uncovered three core compiler and optimization-related issues that only surfaced under the aggressive code reordering of `ReleaseFast`:
1. **Strict C-Struct Memory Alignment**: The LLVM optimizer vectorized memory operations aggressively. Structs matching Python C-mappings (such as `FutureObject.data`) lacked explicit alignment declarations, causing memory faults during vectorized operations.
2. **Aggressive Const-Folding**: Essential type descriptors (like `loop_spec`) were folded away as compile-time constants by the optimizer, losing runtime type check guarantees.
3. **Shutdown re-arming races**: By removing asynchronous queuing (`IOSQE_ASYNC`) to maximize speed, active event watchers (like test readers) registered synchronously and re-armed themselves instantly, creating an infinite loop during stopping iterations.

By correcting alignments, declaring type specs as mutable `var` instances to prevent folding, and adhering to strict Python AsyncIO stop semantics (exiting at the end of the iteration), we fully resolved all `ReleaseFast` stability bugs. 

Consequently, we updated **Starburst mode (`--starburst`) to point to `ReleaseFast` by default** and added a `--safe` flag for `ReleaseSafe`. The results speak for themselves, delivering massive performance gains—such as doubling throughput on **TCP Echo** and turning a **Socket Ops** deficit into a victory over standard `asyncio`—all while maintaining the exact same 100% stability.

Here are the benchmark results for v0.6.0 across both platforms:
- **Intel Core Ultra 7 265**:
  - Python 3.14: [Debug](benchmarks/core-ultra-7-265/benchmarks-v0.6.0-3.14-debug.txt) | [Safe](benchmarks/core-ultra-7-265/benchmarks-v0.6.0-3.14-safe.txt) | [Starburst (ReleaseFast)](benchmarks/core-ultra-7-265/benchmarks-v0.6.0-3.14-starburst.txt)
  - Python 3.14t: [Debug](benchmarks/core-ultra-7-265/benchmarks-v0.6.0-3.14t-debug.txt) | [Safe](benchmarks/core-ultra-7-265/benchmarks-v0.6.0-3.14t-safe.txt) | [Starburst (ReleaseFast)](benchmarks/core-ultra-7-265/benchmarks-v0.6.0-3.14t-starburst.txt)
- **Intel N6000**:
  - Python 3.14: [Debug](benchmarks/n6000/benchmarks-v0.6.0-3.14-debug.txt) | [Safe](benchmarks/n6000/benchmarks-v0.6.0-3.14-safe.txt) | [Starburst (ReleaseFast)](benchmarks/n6000/benchmarks-v0.6.0-3.14-starburst.txt)
  - Python 3.14t: [Debug](benchmarks/n6000/benchmarks-v0.6.0-3.14t-debug.txt) | [Safe](benchmarks/n6000/benchmarks-v0.6.0-3.14t-safe.txt) | [Starburst (ReleaseFast)](benchmarks/n6000/benchmarks-v0.6.0-3.14t-starburst.txt)

## Releasing v0.6.1: Starburst Mode for Binary Packages

With the release of **v0.6.1**, we have decided, based on our benchmark outcomes and comprehensive testing (including passing 100% of the standard `asyncio` test suite across four distinct Python interpreters), that it is safe to publish the official binary packages (wheels) with **Starburst mode** (Zig code built with `ReleaseFast`) enabled by default.

Through meticulous optimization of struct layouts and memory boundaries, we resolved the alignment and race-condition concerns that previously made aggressive compile-time optimizations unstable. We can now deliver maximum throughput safely to all end-users.

## Releasing v0.6.4: Deep Audit, Model Swarms & The Socket Ops Leap

After the release of **v0.6.3**, we took a step back and instructed our coding agents to conduct a deep, comprehensive audit of the entire codebase. The goal was to identify and fix any patterns that violated our accumulated [lessons-learned.md](lessons-learned.md). 

During this phase, we established a highly effective multi-model workflow. Because different AI models exhibit different strengths, weaknesses, and blindspots, we leveraged a split-model approach:
1. **Bug Hunting**: We deployed expensive, high-reasoning models (with large thinking quotas) to scrutinize the code, identify subtle bugs, and document their findings in meticulous detail in [BUGS.md](BUGS.md).
2. **Bug Fixing**: We then passed these detailed specifications from [BUGS.md](BUGS.md) to cheaper, faster models to execute the fixes quickly and precisely.

This audit successfully resolved several critical reference-counting issues, double-frees, ghost reference cycles, and potential use-after-free bugs (including BUG-108 through BUG-115).

However, this rigorous application of defensive programming introduced a severe regression on the **Socket Ops** benchmark. To find the root cause, we analyzed the performance path again. We traced the slowdown to a defensive cancellation mechanism (BUG-116)—unconditional `CancelByFd` calls and queue flushes executing on every socket close. By optimizing the teardown sequence to bypass `CancelByFd` when no reads or writes are pending, we removed the system call overhead entirely. 

The result was a stunning breakthrough: Socket Ops performance didn't just recover—it leaped to its highest benchmark scores yet, proving that correctness and extreme performance can go hand-in-hand.

You can view the detailed benchmark results here:
- **Intel Core Ultra 7 265**: Python 3.14 [Starburst (ReleaseFast)](benchmarks/core-ultra-7-265/benchmarks-v0.6.4-3.14-starburst.txt)

## Releasing v0.7.0: macOS Apple Silicon Dev Suite, AARCH64 Alignment & Link-Time Optimization (LTO)

With the release of **v0.7.0**, we focused on broadening developer access, making the codebase cross-platform compile-friendly, and adopting advanced link-time optimizations.

1. **macOS Apple Silicon & Podman Dev Suite**:
   Because Talyn relies on Linux-specific `io_uring` kernel primitives, it cannot run directly on the macOS/XNU kernel or BSD-based stack. To support developers on Apple Silicon, we reorganized and grouped containerized tooling into [scripts/macos/](../scripts/macos/). This suite leverages Podman/Podman-machine and Apple's Hypervisor.framework to run a full Linux kernel (Fedora 44) virtualized on macOS, hosting the test and benchmark wrappers (`run_tests.sh`, `benchmark.sh`) inside the container.
2. **Multi-Architecture Wheel Compilation**:
   We added a wrapper script, `build_all_wheels.sh`, which compiles both native `aarch64` and emulated `x86_64` wheels in a single command on Apple Silicon using Podman. The script is designed to safely isolate builds so that building for one architecture doesn't overwrite wheels of the other in the final `./dist/` folder.
3. **Strict AARCH64 Alignment & Compiler Fixes**:
   Compiling for `aarch64` Linux exposed strict memory alignment constraints that do not exist on `x86_64`. We resolved compiler faults by introducing `@alignCast` to pointer casts across all core Zig modules. Additionally, we pinned `aarch64` targets to a `generic` CPU configuration to guarantee standard, portable wheels across ARM machines.
4. **Link-Time Optimization (ThinLTO)**:
   To squeeze out extra performance and enable inter-procedural optimization across Zig modules and auxiliary C files (like atomic stubs and execution trampolines), we configured ThinLTO (`lib.lto = .thin`) and section garbage collection (`lib.link_gc_sections = true`) for all release builds. This ensures leaner, faster binaries without significantly bloating compile times.

These compiler and build improvements yielded impressive outcomes in our comprehensive benchmark sweep. We verified Talyn v0.7.0's performance across all three targeted hardware profiles:
* **Intel Core Ultra 7 265**: Socket Ops reached a peak speedup of **3.47x** over standard `asyncio`, outpacing `uvloop` (**3.05x**). Free-threaded (Python 3.14t) task spawning also saw a clean **2.10x** improvement.
* **Macbook Neo (ARM64)**: Apple Silicon validation was performed under Fedora 44 virtualized via Podman on macOS. Socket Ops ran **2.57x** faster than asyncio under the GIL, and **2.66x** faster in free-threaded mode (serving as a key high-performance loop since `uvloop` was unsupported on free-threaded containerized environments).
* **Intel Celeron N6000**: Edge scaling remained solid, delivering a **2.62x** Socket Ops speedup and dropping coroutine execution times by up to 55%.

For a complete breakdown of the results, see [BENCHMARKS-v0.7.0.md](benchmarks/BENCHMARKS-v0.7.0.md). The raw execution logs are also available:
- **Intel Core Ultra 7 265**: [Python 3.14](benchmarks/core-ultra-7-265/benchmarks-v0.7.0-3.14-starburst.txt) | [Python 3.14t](benchmarks/core-ultra-7-265/benchmarks-v0.7.0-3.14t-starburst.txt)
- **Macbook Neo (ARM64)**: [Python 3.14](benchmarks/macbook-neo/benchmarks-v0.7.0-3.14-starburst.txt) | [Python 3.14t](benchmarks/macbook-neo/benchmarks-v0.7.0-3.14t-starburst.txt)
- **Intel N6000**: [Python 3.14](benchmarks/n6000/benchmarks-v0.7.0-3.14-starburst.txt) | [Python 3.14t](benchmarks/n6000/benchmarks-v0.7.0-3.14t-starburst.txt)

---

This project has been a long, humbling, and incredibly rewarding journey. From an inactive, crash-prone prototype to a stable, fully test-suite-passing event loop built with the help of a swarm of AI agents.

And that’s how Talyn came to life.
