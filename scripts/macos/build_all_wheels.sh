#!/usr/bin/env bash
set -euo pipefail

# This script builds both aarch64 and x86_64 wheels for all 4 Python versions
# on macOS (Apple Silicon) using Podman.
# The wheels are collected in the ./dist directory, ready for publication to PyPI.

IMAGE_AARCH64="talyn-test-env-macos-aarch64"
IMAGE_X86_64="talyn-test-env-macos-x86_64"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# 1. Check if podman is installed
if ! command -v podman &>/dev/null; then
    echo "Error: 'podman' command not found."
    echo "Please install Podman on your Mac using Homebrew:"
    echo "  brew install podman"
    exit 1
fi

# 2. Check and manage Podman VM status
echo "Checking Podman VM status..."
VM_STATUS=$(podman machine list --format "{{.Running}}" 2>/dev/null || true)

if [ -z "$VM_STATUS" ]; then
    echo "Error: No Podman machine initialized."
    echo "Please initialize the Podman machine first by running:"
    echo "  podman machine init"
    exit 1
fi

WAS_VM_RUNNING=true
if [[ "$VM_STATUS" != *"true"* ]]; then
    WAS_VM_RUNNING=false
    echo "Podman machine is not running. Starting it..."
    if ! podman machine start; then
        echo "Error: Failed to start Podman machine."
        exit 1
    fi
fi

# Stop Podman VM at exit if we started it
cleanup() {
    local rc=$?
    if [ "$WAS_VM_RUNNING" = false ]; then
        echo "Stopping Podman machine..."
        podman machine stop || true
    fi
    exit $rc
}
trap cleanup EXIT INT TERM

REBUILD=false
for arg in "$@"; do
    if [[ "$arg" == "--rebuild-image" ]]; then
        REBUILD=true
        break
    fi
done

# 3. Clean old wheels in dist/
echo "Cleaning old build distributions in ./dist..."
rm -rf "${ROOT_DIR}/dist"
mkdir -p "${ROOT_DIR}/dist"

# 4. Build/ensure both container images
# AARCH64 (Native ARM64)
IMAGE_AARCH64_EXISTS=$(podman images -q "$IMAGE_AARCH64" 2>/dev/null || true)
if [ -z "$IMAGE_AARCH64_EXISTS" ] || [ "$REBUILD" = true ]; then
    echo "Building native AARCH64 build image (${IMAGE_AARCH64})..."
    BUILD_OPTS=()
    if [ "$REBUILD" = true ]; then
        BUILD_OPTS+=("--no-cache")
    fi
    podman build "${BUILD_OPTS[@]}" -t "$IMAGE_AARCH64" -f "${SCRIPT_DIR}/Containerfile" "${ROOT_DIR}"
fi

# x86_64 (Emulated AMD64)
IMAGE_X86_64_EXISTS=$(podman images -q "$IMAGE_X86_64" 2>/dev/null || true)
if [ -z "$IMAGE_X86_64_EXISTS" ] || [ "$REBUILD" = true ]; then
    echo "Building emulated x86_64 build image (${IMAGE_X86_64})..."
    BUILD_OPTS=()
    if [ "$REBUILD" = true ]; then
        BUILD_OPTS+=("--no-cache")
    fi
    podman build --platform linux/amd64 "${BUILD_OPTS[@]}" -t "$IMAGE_X86_64" -f "${SCRIPT_DIR}/Containerfile" "${ROOT_DIR}"
fi

# 5. Build AARCH64 wheels
echo "Building AARCH64 wheels (Native)..."
podman run --rm \
    -v "${ROOT_DIR}:/workspace:z" \
    -w /workspace \
    "$IMAGE_AARCH64" \
    bash scripts/build.sh

# 6. Build x86_64 wheels
echo "Building x86_64 wheels (Emulated)..."
podman run --rm \
    --platform linux/amd64 \
    -v "${ROOT_DIR}:/workspace:z" \
    -w /workspace \
    "$IMAGE_X86_64" \
    bash scripts/build.sh

echo "=========================================="
echo "Built distributions in ./dist:"
ls -lh "${ROOT_DIR}/dist"
echo ""
echo "You can now run './scripts/publish.sh' to upload all wheels to PyPI!"
