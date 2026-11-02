#!/usr/bin/env bash
set -euo pipefail

# This script runs the Talyn test suite inside a Fedora AARCH64 container on
# macOS (Apple Silicon). It prefers Apple's `container` runtime and falls back
# to Podman when `container` is unavailable.
#
# It builds/caches the container image and applies the runtime flags io_uring
# needs (Podman only: seccomp/SELinux exemptions).

IMAGE_NAME="talyn-test-env-macos-aarch64"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BACKEND=""
PODMAN_MACHINE_STARTED=false

# 1. Prefer Apple container; fall back to Podman.
if command -v container &>/dev/null; then
    if container system status >/dev/null 2>&1; then
        BACKEND="container"
        echo "Using Apple container runtime."
    else
        echo "Apple container services are not running. Starting them..."
        if container system start >/dev/null 2>&1; then
            BACKEND="container"
            echo "Using Apple container runtime."
        else
            echo "Warning: could not start Apple container services; trying Podman."
        fi
    fi
fi

if [ -z "$BACKEND" ]; then
    if ! command -v podman &>/dev/null; then
        echo "Error: neither Apple 'container' nor 'podman' is available."
        echo "Please install one of them with Homebrew:"
        echo "  brew install container"
        echo "  brew install podman"
        exit 1
    fi
    BACKEND="podman"
    echo "Using Podman runtime."
fi

# 2. Manage the Podman VM. Apple container needs no equivalent setup.
cleanup() {
    local rc=$?
    if [ "$PODMAN_MACHINE_STARTED" = true ]; then
        echo "Stopping Podman machine..."
        podman machine stop || true
    fi
    exit $rc
}
trap cleanup EXIT INT TERM

if [ "$BACKEND" = "podman" ]; then
    echo "Checking Podman VM status..."
    VM_STATUS=$(podman machine list --format "{{.Running}}" 2>/dev/null || true)

    if [ -z "$VM_STATUS" ]; then
        echo "Error: No Podman machine initialized."
        echo "Please initialize the Podman machine first by running:"
        echo "  podman machine init"
        exit 1
    fi

    if [[ "$VM_STATUS" != *"true"* ]]; then
        PODMAN_MACHINE_STARTED=true
        echo "Podman machine is not running. Starting it..."
        if ! podman machine start; then
            echo "Error: Failed to start Podman machine."
            exit 1
        fi
    fi
fi

# 3. Build the container image if it doesn't exist, or if forced.
REBUILD=false
for arg in "$@"; do
    if [[ "$arg" == "--rebuild-image" ]]; then
        REBUILD=true
        break
    fi
done

image_exists() {
    if [ "$BACKEND" = "container" ]; then
        container image inspect "$IMAGE_NAME" >/dev/null 2>&1
    else
        [ -n "$(podman images -q "$IMAGE_NAME" 2>/dev/null || true)" ]
    fi
}

if ! image_exists || [ "$REBUILD" = true ]; then
    echo "Building Fedora AARCH64 testing environment image (${IMAGE_NAME})..."
    BUILD_OPTS=""
    if [ "$REBUILD" = true ]; then
        BUILD_OPTS="--no-cache"
    fi
    if [ "$BACKEND" = "container" ]; then
        container build $BUILD_OPTS -t "$IMAGE_NAME" -f "${SCRIPT_DIR}/Containerfile" "${ROOT_DIR}"
    else
        podman build $BUILD_OPTS -t "$IMAGE_NAME" -f "${SCRIPT_DIR}/Containerfile" "${ROOT_DIR}"
    fi
    echo "Build completed successfully."
fi

# 4. Remove --rebuild-image from the arguments before passing to test_all.sh.
PASS_ARGS=()
for arg in "$@"; do
    if [[ "$arg" != "--rebuild-image" ]]; then
        PASS_ARGS+=("$arg")
    fi
done

# 5. Run the tests in the container.
# Note:
# - Under Podman, --security-opt seccomp=unconfined is critical to allow the
#   containerized processes to call io_uring system calls (io_uring_setup,
#   io_uring_enter, etc.), which are blocked by default Podman/Docker seccomp
#   filters. --security-opt label=disable prevents SELinux in the VM from
#   blocking io_uring_setup.
# - Apple container allows io_uring without those flags.
# - Allocate a TTY only when the caller has one, so the script also works in
#   non-interactive CI shells.
RUN_TTY=()
if [ -t 0 ] && [ -t 1 ]; then
    RUN_TTY=("-it")
fi

echo "Running test suite inside the Fedora container..."
if [ "$BACKEND" = "container" ]; then
    # Apple container defaults to ~1.1 GB of RAM, which is not enough for
    # ReleaseFast Zig builds. Match the 4 GB used by the Podman VM.
    container run --rm ${RUN_TTY[@]+"${RUN_TTY[@]}"} \
        --cpus 4 \
        --memory 4G \
        -v "${ROOT_DIR}:/workspace" \
        -w /workspace \
        "$IMAGE_NAME" \
        bash scripts/test_all.sh ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
else
    podman run --rm ${RUN_TTY[@]+"${RUN_TTY[@]}"} \
        --security-opt seccomp=unconfined \
        --security-opt label=disable \
        -v "${ROOT_DIR}:/workspace:z" \
        -w /workspace \
        "$IMAGE_NAME" \
        bash scripts/test_all.sh ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
fi
