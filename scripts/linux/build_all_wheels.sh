#!/usr/bin/env bash
set -euo pipefail

# Builds all 8 wheels (x86_64 + aarch64 x 4 Python variants) natively on a
# Linux host. Zig's native cross-compiler produces the foreign-architecture
# wheels at full host speed - no QEMU, no containers.
# The wheels are collected in ./dist, ready for publication to PyPI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT_DIR}"

HOST_ARCH="$(uname -m)"

# 1. Check prerequisites
for tool in zig; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: '$tool' not found."
        echo "Please install Zig 0.16.0 on this host."
        exit 1
    fi
done
for py in python3.13 python3.13t python3.14 python3.14t; do
    if ! command -v "$py" &>/dev/null; then
        echo "Error: '$py' not found."
        echo "Please install python3.13/3.14, their free-threading variants, and -devel headers."
        exit 1
    fi
done

# 2. Clean old wheels
echo "Cleaning old build distributions in ./dist..."
rm -rf dist
mkdir -p dist

# 3. Build native-arch wheels
echo "Building ${HOST_ARCH} wheels (native)..."
bash scripts/build.sh

# 4. Cross-compile the other architecture's wheels (Zig cross-compiler)
case "$HOST_ARCH" in
    x86_64)
        echo "Cross-compiling aarch64 wheels (Zig native cross-compile)..."
        TALYN_WANT_ARCH=aarch64 bash scripts/build.sh
        ;;
    aarch64)
        echo "Cross-compiling x86_64 wheels (Zig native cross-compile)..."
        TALYN_WANT_ARCH=x86_64 bash scripts/build.sh
        ;;
    *)
        echo "Error: unsupported host architecture: $HOST_ARCH"
        exit 1
        ;;
esac

echo "=========================================="
echo "Built distributions in ./dist:"
ls -lh dist
echo ""
echo "You can now run './scripts/publish.sh' to upload all wheels to PyPI!"
