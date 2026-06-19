#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
GUEST_SSH="ssh -p 2222 ${SSH_OPTS} root@localhost"

# Parse args
PYTHON_EXE=""
PASS_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --python=*)
            PYTHON_EXE="${arg#--python=}"
            ;;
        *)
            PASS_ARGS+=("$arg")
            ;;
    esac
done

if [ -z "$PYTHON_EXE" ]; then
    echo "Error: --python={executable} is required."
    echo "Usage: ./scripts/qemu/benchmark.sh --python=python3.13 [benchmark_options]"
    exit 1
fi

# Verify connection
if ! ${GUEST_SSH} "echo 'Connection OK'" &>/dev/null; then
    echo "Error: Cannot connect to the VM."
    echo "Please start the VM using './scripts/qemu/boot.sh' first."
    exit 1
fi

echo "Synchronizing workspace code to guest VM..."
rsync -avz -e "ssh -p 2222 ${SSH_OPTS}" \
    --exclude '.git' \
    --exclude '.hg' \
    --exclude 'build/' \
    --exclude 'zig-cache/' \
    --exclude '.zig-cache/' \
    --exclude 'zig-out/' \
    --exclude 'dist/' \
    --exclude 'scripts/qemu/.vm/' \
    "${ROOT_DIR}/" root@localhost:/workspace/

echo "Running benchmarks inside the Fedora RISC-V VM using ${PYTHON_EXE}..."
${GUEST_SSH} "cd /workspace && TALYN_OPTIMIZE=ReleaseFast ${PYTHON_EXE} -m pip install -e . --break-system-packages && ${PYTHON_EXE} benchmark.py ${PASS_ARGS[*]}"

echo "Copying benchmark results back to host..."
mkdir -p "${ROOT_DIR}/benchmarks/output"
rsync -avz -e "ssh -p 2222 ${SSH_OPTS}" \
    root@localhost:/workspace/benchmarks/output/ "${ROOT_DIR}/benchmarks/output/"
