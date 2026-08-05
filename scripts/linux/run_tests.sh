#!/usr/bin/env bash
set -euo pipefail

# Tests foreign-architecture wheels (aarch64, riscv64) on an x86_64 Linux host
# by booting a real Fedora 44 VM (full-system emulation via QEMU TCG) and
# running the full pytest suite against each installed wheel.
#
# WHY a full VM and not QEMU user-mode + containers:
#   QEMU user-mode emulation (binfmt_misc) returns ENOSYS for io_uring_setup,
#   and talyn's event loop requires io_uring with no fallback. A full-system
#   VM runs a real guest kernel whose io_uring syscalls reach the host
#   kernel, so the loop works.
#
# Performance: the full pytest suite (292 tests) runs in ~45-50s in the aarch64
# VM and ~40-190s in the riscv64 VM, vs ~30s natively. Pure CPU-bound loops are
# much slower under TCG, but talyn's event-loop workload is I/O-wait dominated,
# so it emulates well.
#
# Prerequisites (one-time):
#   sudo dnf install qemu-system-aarch64 edk2-aarch64 qemu-system-riscv edk2-riscv64 genisoimage openssh-clients
#
# Usage:
#   scripts/linux/run_tests.sh                       # aarch64, full suite on all wheels
#   scripts/linux/run_tests.sh --arch=riscv64        # riscv64 wheels
#   scripts/linux/run_tests.sh --smoke               # quick smoke test only
#   scripts/linux/run_tests.sh --shutdown            # stop the VM after the run
#   scripts/linux/run_tests.sh --keep                # leave the VM running
#   scripts/linux/run_tests.sh --rebuild             # re-provision the VM image

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ARCH="${TALYN_ARCH:-aarch64}"

SHUTDOWN=false
KEEP_VM=false
SMOKE_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --shutdown) SHUTDOWN=true ;;
        --keep) KEEP_VM=true ;;
        --smoke) SMOKE_ONLY=true ;;
        --arch=*) ARCH="${arg#--arch=}" ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
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
for tool in "$QEMU_BIN" ssh scp genisoimage curl; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: '$tool' not found."
        echo "  sudo dnf install $NEED_PKGS genisoimage openssh-clients curl"
        exit 1
    fi
done
if [ ! -f "$FW_CHECK" ]; then
    echo "Error: $ARCH UEFI firmware not found at $FW_CHECK."
    echo "  sudo dnf install $NEED_PKGS"
    exit 1
fi

mkdir -p "$VM_DIR"

# 2. Download the Fedora 44 cloud image
if [ ! -f "$QCOW_PATH" ]; then
    echo "Downloading Fedora 44 $ARCH cloud image..."
    curl -L "$IMG_URL" -o "$QCOW_PATH"
fi

# 3. Generate cloud-init seed + ssh key on first run
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

# riscv64 boots via UEFI pflash (edk2); copy a writable VARS image once
if [ "$ARCH" = "riscv64" ] && [ ! -f "${VM_DIR}/RISCV_VIRT_VARS.qcow2" ]; then
    cp /usr/share/edk2/riscv/RISCV_VIRT_VARS.qcow2 "${VM_DIR}/RISCV_VIRT_VARS.qcow2"
    chmod u+w "${VM_DIR}/RISCV_VIRT_VARS.qcow2"
fi

# 4. Start the VM if it isn't running
is_running() {
    [ -f "$PID_PATH" ] && kill -0 "$(cat "$PID_PATH")" 2>/dev/null
}
if ! is_running; then
    echo "Booting the $ARCH VM (first boot takes a few minutes under TCG)..."
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

# 6. Install the Python interpreters, pytest, and pytest-asyncio
echo "Ensuring python3.13/3.14, free-threading variants, and pytest are installed in the VM..."
ssh "${SSH_ARGS[@]}" fedora@127.0.0.1 \
    "sudo dnf install -y python3.13 python3.13-devel python3.13-freethreading python3.14-freethreading"
ssh "${SSH_ARGS[@]}" fedora@127.0.0.1 \
    "for p in python3.13 python3.13t python3.14 python3.14t; do
         \$p -m ensurepip --upgrade >/dev/null 2>&1 || true
         \$p -m pip install --user --quiet pytest pytest-asyncio
     done"
ssh "${SSH_ARGS[@]}" fedora@127.0.0.1 "rm -rf /tmp/talyn-tests"
scp -r -q "${SCP_ARGS[@]}" "${ROOT_DIR}/tests" fedora@127.0.0.1:/tmp/talyn-tests

# 7. Smoke-test each wheel against its matching Python
SMOKE_TEST='
import sys, talyn, asyncio
talyn.install()
async def tcp_echo():
    async def handler(reader, writer):
        data = await reader.read(100)
        writer.write(data)
        await writer.drain()
        writer.close()
        await writer.wait_closed()
    srv = await asyncio.start_server(handler, "127.0.0.1", 0)
    port = srv.sockets[0].getsockname()[1]
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(b"hello-talyn")
    await writer.drain()
    data = await reader.read(100)
    assert data == b"hello-talyn", data
    writer.close()
    await writer.wait_closed()
    srv.close()
    await srv.wait_closed()
async def tasks():
    async def work(i):
        await asyncio.sleep(0.05)
        return i * i
    rs = await asyncio.gather(*(work(i) for i in range(50)))
    assert rs == [i * i for i in range(50)], rs
asyncio.run(tcp_echo())
asyncio.run(tasks())
print("SMOKE TEST PASS")
'

echo "=========================================="
echo "Testing ${ARCH} wheels:"
PASS=0
FAIL=0
for wheel in "${ROOT_DIR}"/dist/*manylinux_2_36_${ARCH}.whl; do
    [ -e "$wheel" ] || continue
    base="$(basename "$wheel")"
    case "$base" in
        *-cp313-cp313-*)  PY=python3.13 ;;
        *-cp313-cp313t-*) PY=python3.13t ;;
        *-cp314-cp314-*)  PY=python3.14 ;;
        *-cp314-cp314t-*) PY=python3.14t ;;
        *) echo "  ${base}: unknown python tag, skipping"; continue ;;
    esac

    echo "  ${base}:"
    echo -n "    install + smoke ... "
    if ! scp "${SCP_ARGS[@]}" "$wheel" fedora@127.0.0.1:"/tmp/${base}" >/dev/null 2>&1 \
        || ! ssh "${SSH_ARGS[@]}" fedora@127.0.0.1 \
            "$PY -m pip install --user --force-reinstall /tmp/${base} >/dev/null 2>&1 \
             && cd /tmp && $PY -c '$SMOKE_TEST'" >"${VM_DIR}/smoke.log" 2>&1 \
        || ! grep -q "SMOKE TEST PASS" "${VM_DIR}/smoke.log"; then
        echo "FAIL"
        tail -5 "${VM_DIR}/smoke.log"
        FAIL=$((FAIL + 1))
        continue
    fi
    echo "PASS"

    if [ "$SMOKE_ONLY" = true ]; then
        PASS=$((PASS + 1))
        continue
    fi

    echo -n "    pytest suite ... "
    # Free-threaded interpreters are the slowest combination under TCG; raise
    # the subprocess-repro timeout so BUG-118/119/120 tests don't trip their
    # hardcoded 120s limit (see tests/test_connection_memory_safety.py).
    if ssh "${SSH_ARGS[@]}" fedora@127.0.0.1 \
        "cd /tmp && TALYN_REPRO_TIMEOUT=900 $PY -m pytest talyn-tests/ -q --no-header" \
        >"${VM_DIR}/pytest.log" 2>&1 \
        && grep -Eq "[0-9]+ passed" "${VM_DIR}/pytest.log" \
        && ! grep -q "failed" "${VM_DIR}/pytest.log"; then
        tail -1 "${VM_DIR}/pytest.log"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        tail -15 "${VM_DIR}/pytest.log"
        FAIL=$((FAIL + 1))
    fi
done

echo "=========================================="
echo "Results: $PASS passed, $FAIL failed."

# 8. Shutdown policy
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
if [ "$SHUTDOWN" = true ]; then
    echo "Stopping the $ARCH VM..."
    ssh "${SSH_ARGS[@]}" fedora@127.0.0.1 "sudo systemctl poweroff" >/dev/null 2>&1 || true
    sleep 5
    [ -f "$PID_PATH" ] && kill "$(cat "$PID_PATH")" 2>/dev/null || true
elif [ "$KEEP_VM" != true ]; then
    echo "Leaving the VM running (use --shutdown to stop it, --keep to reuse it)."
fi
