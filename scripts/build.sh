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

# Start with a fresh dist directory
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Clean stale .so files left in the source tree by `pip install -e .` or `setup.py develop`
printf "${YELLOW}Cleaning stale .so files from source tree...${NC}\n"
find talyn/ -name '*.so' -delete 2>/dev/null || true

PYTHONS=("python3.13" "python3.14" "python3.13t" "python3.14t")
BUILT_COUNT=0

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

    printf "${GREEN}[%s]${NC} Compiling and building binary wheel...\n" "$py"
    if TALYN_OPTIMIZE=ReleaseSafe "$py" setup.py bdist_wheel --dist-dir "$DIST_DIR" --plat-name manylinux_2_36_x86_64; then
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
