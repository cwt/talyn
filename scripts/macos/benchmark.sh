#!/usr/bin/env bash
set -euo pipefail

# This script runs the Talyn benchmark suite inside a Fedora AARCH64 Podman container on macOS (Apple Silicon).
# It automatically starts the Podman machine if needed, builds/caches the container image,
# compiles the Talyn extension for the selected python executable in ReleaseFast mode,
# and executes benchmark.py.

IMAGE_NAME="talyn-test-env-macos-aarch64"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Parse python executable argument
PYTHON_EXE=""
REBUILD=false
PASS_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --python=*)
            PYTHON_EXE="${arg#--python=}"
            ;;
        --rebuild-image)
            REBUILD=true
            ;;
        *)
            PASS_ARGS+=("$arg")
            ;;
    esac
done

if [ -z "$PYTHON_EXE" ]; then
    echo "Error: --python={executable} is required."
    echo "Usage: ./scripts/macos/benchmark.sh --python=python3.13 [benchmark_options]"
    echo "Examples:"
    echo "  ./scripts/macos/benchmark.sh --python=python3.13"
    echo "  ./scripts/macos/benchmark.sh --python=python3.13t --bench=task_spawn,chat"
    exit 1
fi

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

# 4. Ensure the output directory for plots exists
mkdir -p "${ROOT_DIR}/benchmarks/output"

# 5. Run the benchmarks in the container
# We run `pip install -e .` with TALYN_OPTIMIZE=ReleaseFast to compile the binary extension
# in optimized mode for the specific python version before running benchmark.py.
echo "Running benchmark inside the Fedora container using ${PYTHON_EXE}..."
podman run --rm -it \
    --security-opt seccomp=unconfined \
    --security-opt label=disable \
    -v "${ROOT_DIR}:/workspace:z" \
    -w /workspace \
    "$IMAGE_NAME" \
    bash -c 'TALYN_OPTIMIZE=ReleaseFast '"${PYTHON_EXE}"' -m pip install -e . --break-system-packages && exec '"${PYTHON_EXE}"' benchmark.py "$@"' -- "${PASS_ARGS[@]}"
