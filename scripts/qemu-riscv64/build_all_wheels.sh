#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
GUEST_SSH="ssh -p 2222 ${SSH_OPTS} root@localhost"

# Verify connection
if ! ${GUEST_SSH} "echo 'Connection OK'" &>/dev/null; then
    echo "Error: Cannot connect to the VM."
    echo "Please start the VM using './scripts/qemu/boot.sh' first."
    exit 1
fi

echo "Cleaning host dist/ directory..."
rm -rf "${ROOT_DIR}/dist"
mkdir -p "${ROOT_DIR}/dist"

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

echo "Compiling riscv64 wheels inside the Fedora RISC-V VM..."
${GUEST_SSH} "cd /workspace && bash scripts/build.sh"

echo "Copying compiled wheels back to host dist/ directory..."
rsync -avz -e "ssh -p 2222 ${SSH_OPTS}" \
    root@localhost:/workspace/dist/ "${ROOT_DIR}/dist/"

echo "=========================================="
echo "Built RISC-V distributions in ./dist:"
ls -lh "${ROOT_DIR}/dist"
