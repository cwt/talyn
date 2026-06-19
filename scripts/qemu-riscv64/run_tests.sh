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

echo "Synchronizing workspace code to guest VM..."
# We use rsync over SSH (port 2222) to efficiently copy the project files to /workspace in the VM
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

echo "Running tests inside the Fedora RISC-V VM..."
# Run the test suite in the workspace directory of the VM
${GUEST_SSH} "cd /workspace && bash scripts/test_all.sh $@"
