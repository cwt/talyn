#!/usr/bin/env bash
set -euo pipefail

# This script runs the Talyn test suite inside a Fedora AARCH64 Podman container on macOS (Apple Silicon).
# It automatically starts the Podman machine if needed, builds/caches the container image,
# and executes the test script with the correct seccomp/SELinux flags for io_uring.

IMAGE_NAME="talyn-test-env-macos-aarch64"
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

# 3. Build the container image if it doesn't exist, or if forced
REBUILD=false
for arg in "$@"; do
    if [[ "$arg" == "--rebuild-image" ]]; then
        REBUILD=true
        break
    fi
done

# Check if image exists
IMAGE_EXISTS=$(podman images -q "$IMAGE_NAME" 2>/dev/null || true)

if [ -z "$IMAGE_EXISTS" ] || [ "$REBUILD" = true ]; then
    echo "Building Fedora AARCH64 testing environment image (${IMAGE_NAME})..."
    BUILD_OPTS=()
    if [ "$REBUILD" = true ]; then
        BUILD_OPTS+=("--no-cache")
    fi
    podman build "${BUILD_OPTS[@]}" -t "$IMAGE_NAME" -f "${SCRIPT_DIR}/Containerfile" "${ROOT_DIR}"
    echo "Build completed successfully."
fi

# 4. Remove --rebuild-image from the arguments before passing to test_all.sh
PASS_ARGS=()
for arg in "$@"; do
    if [[ "$arg" != "--rebuild-image" ]]; then
        PASS_ARGS+=("$arg")
    fi
done

# 5. Run the tests in the container
# Note:
# - --security-opt seccomp=unconfined is critical to allow the containerized
#   processes to call io_uring system calls (io_uring_setup, io_uring_enter, etc.)
#   which are blocked by default Podman/Docker seccomp filters.
# - --security-opt label=disable is required to prevent SELinux in the VM from
#   blocking io_uring_setup.
echo "Running test suite inside the Fedora container..."
podman run --rm -it \
    --security-opt seccomp=unconfined \
    --security-opt label=disable \
    -v "${ROOT_DIR}:/workspace:z" \
    -w /workspace \
    "$IMAGE_NAME" \
    bash scripts/test_all.sh "${PASS_ARGS[@]}"
