#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/test_all.sh inside a foreign-arch Fedora 44 VM WITHOUT the slow
# in-VM Zig build phase. The talyn extension is cross-compiled natively on the
# host by Zig (fast, same binary the wheels carry), then test_all.sh is invoked
# with --no-build so only the test suites execute under emulation.
#
# Requires the host to have zig 0.16.0 and the 4 Python devel header sets
# (python3.13/3.14 + free-threading variants), e.g. Fedora:
#   sudo dnf install zig python3.13-devel python3.13-freethreading \
#     python3.14-devel python3.14-freethreading-devel
#
# Usage:
#   scripts/linux/run_test_all.sh                          # aarch64, Debug
#   scripts/linux/run_test_all.sh --arch=riscv64 --starburst
#   scripts/linux/run_test_all.sh --shutdown               # stop VM after
#   scripts/linux/run_test_all.sh --python=3.13,3.14       # subset of pythons
#
# Test-related env vars (defaults match test_all.sh):
#   TALYN_STDLIB_TIMEOUT  per stdlib-asyncio module timeout (default 60, VM: 300)
#   TALYN_REPRO_TIMEOUT   memory-safety repro subprocess timeout (default 120, VM: 900)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ARCH="${TALYN_ARCH:-aarch64}"

SHUTDOWN=false
KEEP_VM=false
PASS_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --shutdown) SHUTDOWN=true ;;
        --keep) KEEP_VM=true ;;
        --arch=*) ARCH="${arg#--arch=}" ;;
        --rebuild-image) ;;  # accepted for compatibility; no image build needed
        *) PASS_ARGS+=("$arg") ;;
    esac
done

# ---- architecture-specific configuration ----
case "$ARCH" in
    aarch64)
        VM_DIR="${TALYN_VM_DIR:-$HOME/.cache/talyn-aarch64-vm}"
        QCOW_PATH="${VM_DIR}/fedora44-aarch64.qcow2"
        KEY_NAME="id_talyn_arm"
        QEMU_BIN="qemu-system-aarch64"
        CPU_ARG="-cpu max"
        FW=""
        FW_CHECK="/usr/share/edk2/aarch64/QEMU_EFI.fd"
        NEED_PKGS="qemu-system-aarch64 edk2-aarch64"
        IMG_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2"
        TARGET_TRIPLE="aarch64-linux-gnu"
        TALYN_CPU="generic"
        SSH_PORT=2222
        ;;
    riscv64)
        VM_DIR="${TALYN_VM_DIR:-$HOME/.cache/talyn-riscv64-vm}"
        QCOW_PATH="${VM_DIR}/fedora44-riscv64.qcow2"
        KEY_NAME="id_talyn_rv"
        QEMU_BIN="qemu-system-riscv64"
        CPU_ARG=""
        FW=""
        FW_CHECK="/usr/share/edk2/riscv/RISCV_VIRT_CODE.qcow2"
        NEED_PKGS="qemu-system-riscv edk2-riscv64"
        IMG_URL="https://dl.fedoraproject.org/pub/alt/risc-v/release/44/Cloud/riscv64/images/Fedora-Cloud-Base-UEFI-UKI-44-20260604.0.riscv64.qcow2"
        TARGET_TRIPLE="riscv64-linux-gnu"
        TALYN_CPU="generic_rv64+m+a+f+d+c"
        SSH_PORT=2223
        ;;
    *)
        echo "Error: unsupported architecture: $ARCH (expected aarch64 or riscv64)"
        exit 2
        ;;
esac

SEED_PATH="${VM_DIR}/seed.img"
KEY_PATH="${VM_DIR}/${KEY_NAME}"
PID_PATH="${VM_DIR}/qemu.pid"
SSH_ARGS=(-i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR -o ConnectTimeout=15 -p "$SSH_PORT")
SCP_ARGS=(-i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR -P "$SSH_PORT")

# 1. Prerequisites
for tool in "$QEMU_BIN" ssh scp genisoimage curl zig; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: '$tool' not found."
        echo "  sudo dnf install $NEED_PKGS genisoimage openssh-clients curl zig"
        exit 1
    fi
done
if [ ! -f "$FW_CHECK" ]; then
    echo "Error: $ARCH UEFI firmware not found at $FW_CHECK."
    echo "  sudo dnf install $NEED_PKGS"
    exit 1
fi

# 2. Cross-build the 4 extension variants natively on the host (fast).
#    Save any existing host-arch .so files and restore them afterwards.
echo "Cross-compiling talyn extensions for ${ARCH} (native Zig)..."
BACKUP_DIR="$(mktemp -d)"
trap 'rm -f talyn/talyn_zig*.so; mv -f "${BACKUP_DIR}"/talyn_zig*.so talyn/ 2>/dev/null || true; rm -rf "${BACKUP_DIR}" zig-out zig-cache .zig-cache' EXIT
cd "$ROOT_DIR"
if ls talyn/talyn_zig*.so >/dev/null 2>&1; then
    mv talyn/talyn_zig*.so "$BACKUP_DIR"/
fi
cross_build_ext() {
    local variant="$1" gilflag="" soabi
    case "$variant" in
        3.13)  soabi="cpython-313" ;;
        3.14)  soabi="cpython-314" ;;
        3.13t) soabi="cpython-313t"; gilflag="-Dpython-gil-disabled" ;;
        3.14t) soabi="cpython-314t"; gilflag="-Dpython-gil-disabled" ;;
    esac
    rm -rf zig-out zig-cache .zig-cache
    if ! zig build install -Doptimize=ReleaseFast \
        -Dtarget="$TARGET_TRIPLE" "-Dcpu=$TALYN_CPU" $gilflag \
        -Dpython-include-dir="/usr/include/python${variant}" >/dev/null 2>&1; then
        echo "Error: cross-build failed for ${variant} (${ARCH})."
        return 1
    fi
    cp zig-out/lib/libtalyn.so "talyn/talyn_zig.${soabi}-${ARCH}-linux-gnu.so"
}
for v in 3.13 3.14 3.13t 3.14t; do
    cross_build_ext "$v" || exit 1
    echo "  built talyn_zig.cpython-${v}-${ARCH}-linux-gnu.so"
done
rm -rf zig-out zig-cache .zig-cache

# 3. Download image / seed / key (first run)
mkdir -p "$VM_DIR"
if [ ! -f "$QCOW_PATH" ]; then
    echo "Downloading Fedora 44 $ARCH cloud image..."
    curl -L "$IMG_URL" -o "$QCOW_PATH"
fi
if [ ! -f "$KEY_PATH" ]; then
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q -C "talyn-$ARCH"
fi
if [ ! -f "$SEED_PATH" ]; then
    echo "Generating cloud-init seed..."
    SEED_DIR="${VM_DIR}/seed"
    mkdir -p "$SEED_DIR"
    cat > "$SEED_DIR/meta-data" <<EOF
instance-id: talyn-${ARCH}-01
local-hostname: talyn-${ARCH}
EOF
    PUBKEY="$(cat "${KEY_PATH}.pub")"
    cat > "$SEED_DIR/user-data" <<EOF
#cloud-config
users:
  - name: fedora
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: wheel
    shell: /bin/bash
    ssh_authorized_keys:
      - $PUBKEY
ssh_pwauth: false
package_update: false
EOF
    cat > "$SEED_DIR/network-config" <<EOF
version: 2
ethernets:
  all-en:
    match:
      name: "en*"
    dhcp4: true
EOF
    genisoimage -output "$SEED_PATH" -volid cidata -joliet -rock \
        "$SEED_DIR/user-data" "$SEED_DIR/meta-data" "$SEED_DIR/network-config" >/dev/null 2>&1
fi
if [ "$ARCH" = "riscv64" ] && [ ! -f "${VM_DIR}/RISCV_VIRT_VARS.qcow2" ]; then
    cp /usr/share/edk2/riscv/RISCV_VIRT_VARS.qcow2 "${VM_DIR}/RISCV_VIRT_VARS.qcow2"
    chmod u+w "${VM_DIR}/RISCV_VIRT_VARS.qcow2"
fi

# 4. Start the VM
is_running() {
    [ -f "$PID_PATH" ] && kill -0 "$(cat "$PID_PATH")" 2>/dev/null
}
if ! is_running; then
    echo "Booting the $ARCH VM..."
    rm -f "$PID_PATH"
    BOOT_ARGS=()
    if [ "$ARCH" = "aarch64" ]; then
        BOOT_ARGS=(-bios /usr/share/edk2/aarch64/QEMU_EFI.fd)
    else
        BOOT_ARGS=(
            -drive if=pflash,format=qcow2,readonly=on,file=/usr/share/edk2/riscv/RISCV_VIRT_CODE.qcow2
            -drive if=pflash,format=qcow2,file="${VM_DIR}/RISCV_VIRT_VARS.qcow2"
        )
    fi
    # shellcheck disable=SC2086
    nohup "$QEMU_BIN" \
        -machine virt \
        $CPU_ARG \
        -accel tcg,thread=multi \
        -smp 16 \
        -m 8192 \
        "${BOOT_ARGS[@]}" \
        -drive file="$QCOW_PATH",format=qcow2,if=virtio \
        -drive file="$SEED_PATH",format=raw,if=virtio \
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22 \
        -device virtio-net-pci,netdev=net0 \
        -display none \
        -serial file:"${VM_DIR}/serial.log" \
        -pidfile "$PID_PATH" \
        >/dev/null 2>&1 &
fi

# 5. Wait for SSH
echo -n "Waiting for VM sshd"
for _ in $(seq 1 60); do
    if ssh "${SSH_ARGS[@]}" fedora@127.0.0.1 true 2>/dev/null; then
        echo " - up."
        break
    fi
    echo -n "."
    sleep 5
done
if ! ssh "${SSH_ARGS[@]}" fedora@127.0.0.1 true 2>/dev/null; then
    echo "Error: VM did not become reachable over ssh."
    exit 1
fi

# 6. Copy the repo (with the cross-built extensions) into the VM
ssh "${SSH_ARGS[@]}" fedora@127.0.0.1 "rm -rf /tmp/talyn && mkdir -p /tmp/talyn"
tar -C "$ROOT_DIR" --exclude=.hg --exclude=.zig-cache --exclude=zig-cache \
    --exclude=zig-out --exclude=build --exclude=dist --exclude=.mypy_cache \
    --exclude=.pytest_cache --exclude=.ruff_cache -czf - . | \
    ssh "${SSH_ARGS[@]}" fedora@127.0.0.1 "tar -xzf - -C /tmp/talyn"

# 7. Run test_all.sh --no-build in the VM
echo "Running test_all.sh --no-build in the $ARCH VM..."
# shellcheck disable=SC2206
TEST_CMD=(bash scripts/test_all.sh --no-build "${PASS_ARGS[@]}")
set +e
ssh "${SSH_ARGS[@]}" fedora@127.0.0.1 \
    "cd /tmp/talyn && time env TALYN_STDLIB_TIMEOUT=${TALYN_STDLIB_TIMEOUT:-300} TALYN_REPRO_TIMEOUT=${TALYN_REPRO_TIMEOUT:-900} ${TEST_CMD[*]}"
RC=$?
set -e

# 8. Shutdown policy
if [ "$SHUTDOWN" = true ]; then
    echo "Stopping the $ARCH VM..."
    ssh "${SSH_ARGS[@]}" fedora@127.0.0.1 "sudo systemctl poweroff" >/dev/null 2>&1 || true
    sleep 5
    [ -f "$PID_PATH" ] && kill "$(cat "$PID_PATH")" 2>/dev/null || true
elif [ "$KEEP_VM" != true ]; then
    echo "Leaving the VM running (use --shutdown to stop it, --keep to reuse it)."
fi
exit $RC
