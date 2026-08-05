#!/usr/bin/env bash
# Talyn Multi-Python Wheel Builder
# Usage: ./scripts/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DIST_DIR="./dist"

echo "=== Talyn Multi-Python Wheel Builder ==="
echo "Targeting Python environments: python3.13, python3.14, python3.13t, python3.14t"
echo ""

# Ensure the dist directory exists
mkdir -p "$DIST_DIR"

# Clean stale .so files left in the source tree by `pip install -e .` or `setup.py develop`
printf "${YELLOW}Cleaning stale .so files from source tree...${NC}\n"
find talyn/ -name '*.so' -delete 2>/dev/null || true

PYTHONS=("python3.13" "python3.14" "python3.13t" "python3.14t")
BUILT_COUNT=0

# Detect the host architecture and the requested build architecture.
# TALYN_WANT_ARCH overrides the target so cross-compiled wheels can be built
# on a different host (e.g. aarch64 wheels on an x86_64 PC, via Zig's
# native cross-compiler - no QEMU required).
HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" = "arm64" ]; then
    HOST_ARCH="aarch64"
fi
WANT_ARCH="${TALYN_WANT_ARCH:-$HOST_ARCH}"
if [ "$WANT_ARCH" = "arm64" ]; then
    WANT_ARCH="aarch64"
fi

if [ "$WANT_ARCH" = "x86_64" ]; then
    PLAT_NAME="manylinux_2_36_x86_64"
    TALYN_CPU="x86_64"
elif [ "$WANT_ARCH" = "aarch64" ]; then
    PLAT_NAME="manylinux_2_36_aarch64"
    TALYN_CPU="generic"
elif [ "$WANT_ARCH" = "riscv64" ]; then
    PLAT_NAME="manylinux_2_36_riscv64"
    # rv64gc baseline (I, M, A, F, D, C). Zig has no literal "rv64gc" CPU
    # model, so express it as feature additions over the generic rv64 model.
    TALYN_CPU="generic_rv64+m+a+f+d+c"
else
    printf "${RED}Unsupported build architecture: %s${NC}\n" "$WANT_ARCH"
    exit 1
fi

# For cross-compiles, tell setup.py the target triplet so Zig builds the
# native extension for the foreign architecture. setup.py then skips linking
# the host's libpython (wrong ELF architecture).
CROSS_ENV=()
if [ "$WANT_ARCH" != "$HOST_ARCH" ]; then
    printf "${YELLOW}Cross-compiling %s wheels on a %s host (Zig native cross-compile, no QEMU)${NC}\n" "$WANT_ARCH" "$HOST_ARCH"
    case "$WANT_ARCH" in
        x86_64)  CROSS_ENV=(TALYN_TARGET="x86_64-linux-gnu") ;;
        aarch64) CROSS_ENV=(TALYN_TARGET="aarch64-linux-gnu") ;;
        riscv64) CROSS_ENV=(TALYN_TARGET="riscv64-linux-gnu") ;;
    esac
fi

# Clean old wheels for the current platform target to avoid blowing away
# other architecture wheels in multi-arch builds.
rm -f "$DIST_DIR"/*"$PLAT_NAME"*.whl 2>/dev/null || true

for py in "${PYTHONS[@]}"; do
    if ! command -v "$py" >/dev/null 2>&1; then
        printf "${YELLOW}[%s]${NC} not found in PATH — skipping\n" "$py"
        continue
    fi

    printf "${YELLOW}[%s]${NC} Checking build requirements...\n" "$py"
    if ! "$py" -c "import setuptools" >/dev/null 2>&1; then
        printf "  Installing setuptools and wheel...\n"
        "$py" -m pip install --upgrade setuptools wheel || {
            printf "${RED}[%s]${NC} Failed to install setuptools/wheel\n" "$py"
            continue
        }
    fi

    printf "${YELLOW}[%s]${NC} Cleaning intermediate cache directories...\n" "$py"
    rm -rf build/ zig-cache/ .zig-cache/ zig-out/
    find . -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
    find . -name '*.pyc' -delete 2>/dev/null || true

    printf "${GREEN}[%s]${NC} Compiling and building binary wheel for %s...\n" "$py" "$PLAT_NAME"
    if env TALYN_OPTIMIZE=ReleaseFast TALYN_CPU="$TALYN_CPU" "${CROSS_ENV[@]}" "$py" setup.py bdist_wheel --dist-dir "$DIST_DIR" --plat-name "$PLAT_NAME"; then
        printf "${GREEN}[%s] Wheel successfully built!${NC}\n\n" "$py"
        BUILT_COUNT=$((BUILT_COUNT + 1))
    else
        printf "${RED}[%s] Build FAILED!${NC}\n\n" "$py"
    fi
done

# Cleanup temporary build dirs at the end
rm -rf build/ zig-cache/ .zig-cache/ zig-out/

echo "=========================================="
if [ "$BUILT_COUNT" -eq 0 ]; then
    printf "${RED}Failed to build any wheels.${NC}\n"
    exit 1
else
    printf "${GREEN}Successfully built %d wheel(s) in %s:${NC}\n" "$BUILT_COUNT" "$DIST_DIR"
    ls -lh "$DIST_DIR"
fi
