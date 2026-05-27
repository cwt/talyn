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

PYTHONS=("python3.13" "python3.14" "python3.13t" "python3.14t")
BUILT_COUNT=0

for py in "${PYTHONS[@]}"; do
    if ! command -v "$py" >/dev/null 2>&1; then
        printf "${YELLOW}[%s]${NC} not found in PATH — skipping\n" "$py"
        continue
    fi

    printf "${YELLOW}[%s]${NC} Checking build requirements...\n" "$py"
    if ! "$py" -I -c "import build" >/dev/null 2>&1; then
        printf "  Installing 'build' dependency...\n"
        "$py" -m pip install --upgrade build || {
            printf "${RED}[%s]${NC} Failed to install 'build' package\n" "$py"
            continue
        }
    fi

    printf "${YELLOW}[%s]${NC} Cleaning intermediate cache directories...\n" "$py"
    # Ensure a completely clean build between target environments to avoid caching incorrect headers or ABI suffixes
    rm -rf build/ zig-cache/ .zig-cache/ zig-out/
    find . -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
    find . -name '*.pyc' -delete 2>/dev/null || true

    printf "${GREEN}[%s]${NC} Compiling and building binary wheel...\n" "$py"
    if "$py" -m build --wheel --outdir "$DIST_DIR"; then
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
