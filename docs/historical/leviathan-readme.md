---
type: historical_archive
title: "Leviathan Legacy README"
description: "Original README preserved from the Leviathan project prior to the Talyn migration."
status: deprecated
verified: human-reviewed
timestamp: "2026-05-01T00:00:00Z"
---

![Banner](media/banner.png)
From the depths of the sea, where darkness meets vastness, emerges Leviathan: an unyielding force of speed and power. In a world where the arcane and the agile intertwine, a loop forged in Python takes its dance. Leviathan, master of the journey, governs events with a steady hand—an **ultra-fast event loop** that deploys its bastion in **asyncio**, powered by the artistry of Zig. Between promises and futures, its path is clear: to rule swiftly where code is prepared.

## 🚀 Features

- **Ultra-fast speed**: Thanks to low-level optimizations enabled by Zig.
- **Full asyncio compatibility**: A drop-in replacement for the default event loop.
- **Efficient design**: Focused on maximizing performance and minimizing latency.
- **Simplicity**: Easy integration with existing Python projects.
- **Robust Safety**: Carefully engineered for critical systems with advanced error recovery and graceful degradation mechanisms.

## 📜 Requirements

- Python >= 3.13
- Zig >= 0.14.0 (for development or contributions)
- Linux >= 5.11

## 🔧 Installation

To install Leviathan, just execute:

```bash
python setup.py install
```

## 📦 Basic Usage

```python
import leviathan
import asyncio

async def main():
    print("Hello from Leviathan!")
    await asyncio.sleep(1)
    print("Goodbye from Leviathan!")

leviathan.run(main())
```

## 🧪 Benchmarks

Leviathan stands out for its speed and performance. Here is a preliminary chart illustrating its superiority over other event loops:

![Performance Benchmark](benchmark_results/chat.png)

For more information and additional tests, check the following file: [More benchmarks and details](leviathan-benchmark.md).

---

⚠️ **Warning**: Leviathan is still under active development. Some integrations, such as full networking support, are pending implementation.
