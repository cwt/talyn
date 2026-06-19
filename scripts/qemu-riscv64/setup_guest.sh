#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
GUEST_SSH="ssh -p 2222 ${SSH_OPTS} root@localhost"

echo "Testing connection to guest VM (localhost:2222)..."
if ! ${GUEST_SSH} "echo 'Connected!'" &>/dev/null; then
    echo "Error: Cannot connect to VM."
    echo "Please ensure the VM is running (./scripts/qemu/boot.sh) and SSH is enabled:"
    echo "  sudo systemctl enable --now sshd"
    exit 1
fi

echo "Connected successfully. Installing package updates and development tools..."
# Execute the same setup steps as our Containerfile
${GUEST_SSH} bash -s <<'EOF'
set -euo pipefail

echo "Enabling systemd-growfs to resize partition to full disk..."
# Try to grow root filesystem if needed
if command -v growpart &>/dev/null; then
    ROOT_DISK=$(findmnt -n -o SOURCE /)
    # e.g., /dev/nvme0n1p4 or /dev/vda4
    if [[ "$ROOT_DISK" =~ ^(/dev/[a-z0-9]+)p([0-9]+)$ ]]; then
        growpart "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" || true
        resize2fs "$ROOT_DISK" || true
    fi
fi

echo "Updating repositories and packages..."
dnf -y update

echo "Installing Zig 0.16.0, compilers, Python environments, and test suites..."
dnf -y install \
    zig \
    gcc \
    gcc-c++ \
    freetype-devel \
    libpng-devel \
    python3.13 \
    python3.13-devel \
    python3.13-freethreading \
    python3.13-test \
    python3.14 \
    python3.14-devel \
    python3.14-freethreading \
    python3.14-freethreading-devel \
    python3-test \
    python3.14-freethreading-test \
    openssl \
    git \
    findutils \
    rsync

echo "Bootstrapping pip..."
python3.13 -m ensurepip --upgrade
python3.13t -m ensurepip --upgrade
python3.14 -m ensurepip --upgrade
python3.14t -m ensurepip --upgrade

echo "Pre-installing Python testing and benchmark dependencies..."
python3.13 -m pip install --no-cache-dir --break-system-packages pytest pytest-asyncio prettytable matplotlib pillow uvloop || true
python3.13t -m pip install --no-cache-dir --break-system-packages pytest pytest-asyncio prettytable matplotlib pillow || true
python3.14 -m pip install --no-cache-dir --break-system-packages pytest pytest-asyncio prettytable matplotlib pillow uvloop || true
python3.14t -m pip install --no-cache-dir --break-system-packages pytest pytest-asyncio prettytable matplotlib pillow || true

echo "------------------------------------------------------"
echo "Guest VM setup completed successfully!"
echo "------------------------------------------------------"
EOF
