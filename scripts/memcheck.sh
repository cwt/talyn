#!/usr/bin/env bash
#
# Memory-safety ("ASAN") test target for talyn.
#
# Zig 0.16 has NO true AddressSanitizer (only -fsanitize-c / UBSan and
# -fsanitize-thread / TSan). This script builds talyn with the Zig-native heap
# checker so connection-creation regressions such as BUG-118 / BUG-119
# (double-free) and BUG-120 (use-after-free) are caught at runtime.
#
# Strategies:
#   -Ddebug-alloc : std.heap.DebugAllocator(.{ .safety = true }) — detects
#                   double-free / invalid free / leaks (the closest Zig
#                   equivalent to ASAN). This is the default for this script.
#   -Dasan        : Zig 0.16 -fsanitize-c (UBSan) — catches a subset of UB.
#
# Usage:
#   scripts/memcheck.sh                 # build with DebugAllocator + run
#   TALYN_ASAN=1 scripts/memcheck.sh    # build with UBSan instead
#   TALYN_OPTIMIZE=Debug scripts/memcheck.sh
#
# Exit code is non-zero if any repro crashes (the regression is present).
set -euo pipefail

cd "$(dirname "$0")/.."

OPTIMIZE="${TALYN_OPTIMIZE:-Debug}"
ASAN="${TALYN_ASAN:-0}"
DEBUG_ALLOC="${TALYN_DEBUG_ALLOC:-1}"

PY_BIN="${PY_BIN:-$(command -v python3.14 || command -v python3)}"

BUILD_FLAGS=(-Doptimize="${OPTIMIZE}")
if [ "${ASAN}" = "1" ]; then
    BUILD_FLAGS+=(-Dasan)
    echo ">> memcheck: building with UBSan (-Dasan)"
else
    BUILD_FLAGS+=(-Ddebug-alloc)
    echo ">> memcheck: building with DebugAllocator (-Ddebug-alloc)"
fi

echo ">> memcheck: building extension"
"${PY_BIN}" setup.py build_ext --inplace "${BUILD_FLAGS[@]}"

SO_SRC="$(ls talyn/talyn_zig*.so | head -n1)"
# Best-effort: also copy into an active venv if one is configured.
if [ -n "${TALYN_VENV:-}" ]; then
    cp "${SO_SRC}" "${TALYN_VENV}/lib64/python3.14/site-packages/talyn/" 2>/dev/null || \
    cp "${SO_SRC}" "${TALYN_VENV}/lib/python3.14/site-packages/talyn/" 2>/dev/null || true
fi

# Repro drivers that exercise the failure modes end-to-end.
REPROS=(
    tests/resources/repro_submit_fail.py
    tests/resources/repro_uaf.py
)

STATUS=0
for repro in "${REPROS[@]}"; do
    [ -f "${repro}" ] || continue
    echo ">> memcheck: running ${repro}"
    if PYTHONPATH="$(pwd)" "${PY_BIN}" "${repro}"; then
        echo "   OK: ${repro} exited clean"
    else
        echo "   FAIL: ${repro} crashed (memory-safety regression present)"
        STATUS=1
    fi
done

if [ "${STATUS}" -eq 0 ]; then
    echo ">> memcheck: PASSED (no memory-safety regressions detected)"
else
    echo ">> memcheck: FAILED"
fi
exit "${STATUS}"
