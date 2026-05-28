from typing import Callable, List, Tuple, Dict, Optional
from prettytable import PrettyTable
from benchmarks import Benchmark

import dataclasses
import uvloop, asyncio, time, talyn
import matplotlib.pyplot as plt
import sys, os, statistics, traceback, subprocess, json, signal, tempfile
import matplotlib

from benchmarks import (
    event_fiesta_factory,
    producer_consumer,
    food_delivery,
    task_workflow,
    chat,
    tcp_echo,
    unix_echo,
    udp_pingpong,
    subprocess_bench,
    task_spawn,
    socket_ops,
)

BENCHMARKS: List[Benchmark] = [
    event_fiesta_factory.BENCHMARK,
    producer_consumer.BENCHMARK,
    food_delivery.BENCHMARK,
    task_workflow.BENCHMARK,
    chat.BENCHMARK,
    tcp_echo.BENCHMARK,
    unix_echo.BENCHMARK,
    udp_pingpong.BENCHMARK,
    subprocess_bench.BENCHMARK,
    task_spawn.BENCHMARK,
    socket_ops.BENCHMARK,
]

matplotlib.use("Agg")

try:
    os.nice(-20)
except IOError as e:
    print(
        f"({e}):",
        "Couldn't set nice, running with default level",
        file=sys.stderr,
    )

N: int = 7
ITERATIONS = 3
BENCHMARK_TIMEOUT = 30

M_INITIAL: int = 1024
M_MULTIPLIER: int = 2

LOOPS: List[Tuple[str, str, Callable[[], asyncio.AbstractEventLoop]]] = [
    ("asyncio", "asyncio.new_event_loop()", lambda: asyncio.new_event_loop()),
    ("uvloop", "uvloop.new_event_loop()", uvloop.new_event_loop),
    ("talyn", "talyn.Loop()", talyn.Loop),
]

def make_script(modname, m, loop_type):
    imports = "import asyncio, sys, json, time, os"
    if "talyn" in loop_type:
        imports += ", talyn"
    if "uvloop" in loop_type:
        imports += ", uvloop"
    return f"""\
{imports}
sys.path.insert(0, os.path.abspath('.'))
from importlib import import_module
mod = import_module("{modname}")
loop = {loop_type}
asyncio.set_event_loop(loop)
results = []
m = {m}
for _ in range({ITERATIONS}):
    start = time.perf_counter()
    mod.BENCHMARK.function(loop, m)
    end = time.perf_counter()
    results.append(end - start)
try:
    loop.run_until_complete(asyncio.wait_for(loop.shutdown_asyncgens(), timeout=5))
except Exception:
    pass
loop.close()
print(json.dumps(results), flush=True)
"""

def benchmark_with_event_loops(
    loops: List[Tuple[str, str, Callable]],
    function: Callable,
) -> Dict[str, Optional[List[Tuple[int, List[float]]]]]:
    modname = function.__module__
    results: Dict[str, Optional[List[Tuple[int, List[float]]]]] = {}

    for loop_name, loop_type, _ in loops:
        print(f"  {loop_name}...", end=" ", flush=True)

        m = M_INITIAL
        all_times: List[Tuple[int, List[float]]] = []
        failed = False

        while m <= M_INITIAL * (2 ** (N - 1)):
            script = make_script(modname, m, loop_type)
            with tempfile.NamedTemporaryFile(
                mode="w", suffix=".py", delete=False, dir="."
            ) as f:
                f.write(script)
                tmppath = f.name
            try:
                out = subprocess.run(
                    [sys.executable, tmppath],
                    capture_output=True, text=True,
                    timeout=BENCHMARK_TIMEOUT,
                )
                if out.returncode != 0:
                    err = out.stderr.strip()
                    print(f"FAIL (m={m}): {err}", flush=True)
                    failed = True
                    break
                times = json.loads(out.stdout.strip().splitlines()[-1])
                all_times.append((m, times))
                print(f"{m}", end=" ", flush=True)
            except subprocess.TimeoutExpired:
                print(f"TIMEOUT (m={m})", flush=True)
                failed = True
                break
            finally:
                os.unlink(tmppath)
            m *= M_MULTIPLIER

        if failed:
            results[loop_name] = None
            print("SKIPPED", flush=True)
        else:
            results[loop_name] = all_times
            print("OK", flush=True)

    return results


def create_comparison_table(
    results: Dict[str, Optional[List[Tuple[int, List[float]]]]],
) -> None:
    if not results:
        print("No results")
        return

    table = PrettyTable()
    field_names = ["Loop", "M", "Min (s)", "Max (s)", "Avg (s)", "Stdev (s)", "Diff (s)", "Rel Speed"]
    table.field_names = field_names

    base_name = LOOPS[0][0]
    base_results = results.get(base_name) or []

    for loop_name, _, _ in LOOPS:
        loop_results = results.get(loop_name)
        if loop_results is None:
            for m, _ in base_results:
                table.add_row([loop_name, m] + ["N/A"] * 6)
            continue
        for i, (m, times) in enumerate(loop_results):
            if not times:
                continue
            mn = min(times)
            mx = max(times)
            avg = statistics.mean(times)
            std = statistics.stdev(times) if len(times) > 1 else 0.0
            if i < len(base_results):
                base_avg = statistics.mean(base_results[i][1])
                diff = avg - base_avg
                rel = base_avg / avg if avg > 0 else float("inf")
            else:
                diff = "-"
                rel = "-"
            table.add_row([loop_name, m, f"{mn:.6f}", f"{mx:.6f}", f"{avg:.6f}", f"{std:.6f}", f"{diff:.6f}", f"{rel:.4f}"])

    print(table)


def plot_results(
    results: Dict[str, Optional[List[Tuple[int, List[float]]]]],
    name: str
) -> None:
    plt.figure(figsize=(10, 6))
    plotted = False

    for loop_name, _, _ in LOOPS:
        loop_results = results.get(loop_name)
        if loop_results is None:
            continue
        x = [m for m, _ in loop_results]
        y = [statistics.mean(times) for _, times in loop_results]
        lows = [statistics.mean(times) - min(times) for _, times in loop_results]
        highs = [max(times) - statistics.mean(times) for _, times in loop_results]
        plt.errorbar(x, y, [lows, highs], marker="o", label=loop_name, capsize=5)
        plotted = True

    if not plotted:
        print("No data to plot")
        plt.close()
        return

    plt.xscale("log", base=2)
    plt.yscale("log")
    plt.xlabel("M (log scale)")
    plt.ylabel("Time (s, log scale)")
    plt.title(f"Benchmark: {name}")
    plt.legend()
    plt.grid(True, which="both", linestyle="--", linewidth=0.5)
    plt.tight_layout()
    safe_name = name.replace(" ", "_").replace("-", "_").lower()
    fname = f"benchmarks/output/benchmark_{safe_name}.png"
    plt.savefig(fname)
    print(f"Plot saved to {fname}")
    plt.close()


if __name__ == "__main__":
    for benchmark in BENCHMARKS:
        bname = benchmark.name
        print(f"\n=== {bname} ===")
        r = benchmark_with_event_loops(LOOPS, benchmark.function)
        create_comparison_table(r)
        plot_results(r, bname)
