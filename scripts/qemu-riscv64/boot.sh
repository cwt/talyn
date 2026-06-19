#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VM_DIR="${SCRIPT_DIR}/.vm"

FW_URL="https://github.com/LekKit/RVVM/releases/download/v0.5/fw_payload.bin"
IMAGE_URL="https://dl.fedoraproject.org/pub/alt/risc-v/release/44/Server/riscv64/images/Fedora-Server-Host-Generic-44-20260604.0.riscv64.raw.xz"

# Check if QEMU is installed
if ! command -v qemu-system-riscv64 &>/dev/null; then
    echo "Error: 'qemu-system-riscv64' command not found."
    echo "Please install QEMU on your Mac using Homebrew:"
    echo "  brew install qemu"
    exit 1
fi

mkdir -p "$VM_DIR"

# Download firmware if missing
if [ ! -f "${VM_DIR}/fw_payload.bin" ]; then
    echo "Downloading U-Boot/OpenSBI firmware payload..."
    curl -L -o "${VM_DIR}/fw_payload.bin" "$FW_URL"
fi

# Download image if missing
if [ ! -f "${VM_DIR}/fedora.qcow2" ]; then
    if [ ! -f "${VM_DIR}/fedora.raw.xz" ]; then
        echo "Downloading Fedora 44 RISC-V raw image (approx. 1.3GB)..."
        curl -L -o "${VM_DIR}/fedora.raw.xz" "$IMAGE_URL"
    fi
    echo "Extracting Fedora 44 RISC-V raw image..."
    unxz -v "${VM_DIR}/fedora.raw.xz"
    
    echo "Expanding disk image size to 15GB to allow build workspace..."
    # Grow the raw file (sparse image)
    dd if=/dev/zero of="${VM_DIR}/fedora.raw" bs=1M count=0 seek=15360 2>/dev/null
    # Convert disk image to compressed qcow2
    qemu-img convert -O qcow2 -c -p "${VM_DIR}/fedora.raw" "${VM_DIR}/fedora.qcow2"
    rm "${VM_DIR}/fedora.raw" 
fi

echo "Booting Fedora 44 RISC-V in QEMU..."
echo "------------------------------------------------------"
echo "Instructions:"
echo "1. Port forwarding configured: localhost:2222 -> Guest:22 (SSH)"
echo "2. On the first boot, complete the initial setup prompts in the console"
echo "   (set your root password and/or create a user)."
echo "3. Once logged in, run: sudo systemctl enable --now sshd"
echo "4. After that, run './scripts/qemu/setup_guest.sh' from your host Mac."
echo "------------------------------------------------------"

# Boot the VM in QEMU
# -nographic: Redirect console to terminal
# -machine virt: Standard RISC-V QEMU board
# -m 4G -smp 4: System resources
# -bios fw_payload.bin: OpenSBI + U-Boot
# -device virtio-blk-device: Attach storage
# -netdev user: Enable network with port forwarding
# -device virtio-rng-device: Fast entropy to prevent boot hangs
# -cpu rv64,v=true,vlen=128  # Don't enable RVV for Talyn
qemu-system-riscv64 \
    -accel tcg,thread=multi \
    -nographic \
    -machine virt \
    -smp 4 \
    -m 4G \
    -bios "${VM_DIR}/fw_payload.bin" \
    -drive file="${VM_DIR}/fedora.qcow2",format=qcow2,id=hd0,if=none \
    -device virtio-blk-device,drive=hd0 \
    -device virtio-net-device,netdev=usernet \
    -netdev user,id=usernet,hostfwd=tcp:127.0.0.1:2222-:22 \
    -object rng-random,filename=/dev/urandom,id=rng0 \
    -device virtio-rng-device,rng=rng0

