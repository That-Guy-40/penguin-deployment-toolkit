#!/bin/bash
# 06-boot-vm.sh - Start swtpm and launch QEMU
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Source config
source "$PROJECT_ROOT/config.sh"

echo "=== Boot VM ==="

validate_vm_config || exit 1

# Verify required files
DISK_PATH="$VMS_DIR/${VM_NAME}.qcow2"
TPM_STATE_PATH="$VMS_DIR/${VM_NAME}-swtpm"
OVMF_VARS_PATH="$VMS_DIR/${VM_NAME}-OVMF_VARS.fd"

for f in "$DISK_PATH" "$TPM_STATE_PATH"; do
    if [[ ! -e "$f" ]]; then
        echo "ERROR: Missing $f. Run 05-create-vm.sh first." >&2
        exit 1
    fi
done

# OVMF NVRAM handling.
# Reset NVRAM ONLY for a fresh install (empty disk), so stale boot entries don't
# fight the bootindex. Once Windows is installed it owns an NVRAM boot entry and
# the disk has no \EFI\BOOT fallback — resetting then would strand it and we'd
# PXE-reinstall on every run. So preserve NVRAM when the disk already has data.
DISK_ALLOC=$(qemu-img info --output=json "$DISK_PATH" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('actual-size',0))" 2>/dev/null || echo 0)
if [[ ! -f "$OVMF_VARS_PATH" ]]; then
    echo "OVMF NVRAM missing — creating from template..."
    cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS_PATH"
elif (( DISK_ALLOC < 104857600 )); then   # < 100 MiB allocated => effectively empty
    echo "Disk is empty — resetting OVMF NVRAM for a clean install boot..."
    cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS_PATH"
else
    echo "Disk has data — preserving OVMF NVRAM so the installed OS boots."
fi

# Check for required commands
for cmd in qemu-system-x86_64 swtpm; do
    if ! command -v $cmd &> /dev/null; then
        echo "ERROR: $cmd not found" >&2
        exit 1
    fi
done

# === CHECK FOR RUNNING SW TPM ===
SWTPM_SOCK="$TPM_STATE_PATH/swtpm.sock"
SWTPM_PID="$TPM_STATE_PATH/swtpm.pid"

if [[ -S "$SWTPM_SOCK" ]] || [[ -f "$SWTPM_PID" ]] && kill -0 "$(cat "$SWTPM_PID" 2>/dev/null)" 2>/dev/null; then
    echo "WARNING: swtpm already running"
    read -p "Kill and restart? (y/N) " -n 1 -r reply
    echo
    if [[ $reply =~ ^[Yy]$ ]]; then
        kill "$(cat "$SWTPM_PID")" 2>/dev/null || true
        rm -f "$SWTPM_SOCK" "$SWTPM_PID"
        sleep 1
    else
        echo "Reusing existing swtpm"
    fi
fi

# === START SW TPM ===
echo "Starting TPM emulator..."
swtpm socket \
    --tpmstate dir="$TPM_STATE_PATH" \
    --ctrl type=unixio,path="$SWTPM_SOCK" \
    --tpm2 \
    --daemon \
    --pid file="$SWTPM_PID"

# Wait for TPM socket
sleep 1
for i in {1..10}; do
    if [[ -S "$SWTPM_SOCK" ]]; then
        break
    fi
    sleep 0.5
done

if [[ ! -S "$SWTPM_SOCK" ]]; then
    echo "ERROR: TPM socket not created" >&2
    exit 1
fi
echo "TPM started: $SWTPM_SOCK"

# === RESOLVE ABSOLUTE PATHS ===
# Critical: TFTP path must be absolute
PROJDIR="$(pwd)"
TFTP_DIR="$PROJDIR/pxe"
IPXE_EFI="$TFTP_DIR/ipxe.efi"
BOOT_IPXE="$TFTP_DIR/boot.ipxe"

# ipxe.efi is the TFTP boot file OVMF downloads and executes as a UEFI binary.
# It contains an embedded script that chains to boot.ipxe over HTTP.
# boot.ipxe is served by nginx (HTTP), not TFTP.
if [[ ! -f "$IPXE_EFI" ]]; then
    echo "ERROR: ipxe.efi not found: $IPXE_EFI" >&2
    echo "       Run scripts/00c-build-ipxe.sh first." >&2
    exit 1
fi

if [[ ! -f "$BOOT_IPXE" ]]; then
    echo "ERROR: boot.ipxe not found: $BOOT_IPXE" >&2
    echo "       Run scripts/04-setup-http.sh first." >&2
    exit 1
fi

# === CHECK HTTP SERVER ===
HTTP_RUNNING=false
if ss -tuln 2>/dev/null | grep -q ":${HTTP_PORT} "; then
    HTTP_RUNNING=true
elif netstat -tuln 2>/dev/null | grep -q ":${HTTP_PORT} "; then
    HTTP_RUNNING=true
fi

if [[ "$HTTP_RUNNING" != "true" ]]; then
    echo "WARNING: nginx not running on port $HTTP_PORT"
    read -p "Start nginx? (y/N) " -n 1 -r reply
    echo
    if [[ $reply =~ ^[Yy]$ ]]; then
        bash "$SCRIPT_DIR/04-setup-http.sh"
    fi
fi

# === LAUNCH QEMU ===
echo "Launching QEMU..."

# Headless mode (HEADLESS=1) is handy for automated/boot-chain testing.
QEMU_DISPLAY="gtk"
[[ "${HEADLESS:-0}" == "1" ]] && QEMU_DISPLAY="none"

# Build QEMU command
QEMU_CMD=(
    qemu-system-x86_64
    -enable-kvm
    -cpu host
    # smm=on + the "secure" pflash global are required by the Secure-Boot OVMF
    # build (OVMF_CODE_4M.secboot.fd in config.sh). disable_s3 avoids an
    # S3-sleep/Secure-Boot interaction. Secure Boot is exposed as *capable* but is
    # in Setup Mode (not enforcing), so our unsigned pxe/ipxe.efi still loads.
    -machine q35,smm=on
    -global driver=cfi.pflash01,property=secure,value=on
    -global ICH9-LPC.disable_s3=1
    -m "$VM_MEMORY"
    -smp "$VM_CPUS"

    # UEFI firmware (unit=0 = code/read-only, unit=1 = writable NVRAM vars)
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,unit=1,file="$OVMF_VARS_PATH"
    
    # TPM
    -chardev socket,id=chrtpm,path="$SWTPM_SOCK"
    -tpmdev emulator,id=tpm0,chardev=chrtpm
    -device tpm-tis,tpmdev=tpm0
    
    # Disks — bootindex lives on -device, not -drive.
    # IMPORTANT: the system disk is AHCI/SATA (ide-hd), NOT virtio-blk. Stock
    # WinPE ships the inbox storahci.sys driver but NO virtio driver, so a
    # virtio-blk disk is invisible to Windows Setup and the install fails in the
    # disk-configuration pass.
    #
    # Boot order via bootindex:  1 = system disk   2 = network/PXE   3 = CD-ROM
    # Disk-first is deliberate, not a mistake:
    #   * First run the disk is empty -> UEFI finds no bootloader -> falls through
    #     to PXE (index 2) -> iPXE -> WinPE -> install.  [verified]
    #   * Once Setup writes Windows, the disk boots it directly (no PXE reinstall
    #     loop) — verified end-to-end. This relies on OVMF honoring the NVRAM entry
    #     Windows writes, so we PRESERVE NVRAM once the disk has data (see below).
    #   * The CD (index 3) is only a fallback; it never pre-empts our injected
    #     PXE boot.wim.
    # Disk and CD go on SEPARATE q35 AHCI/SATA ports (ide.0, ide.2). Each SATA
    # port holds one unit, so leaving them on the default bus collides
    # ("Can't create IDE unit 1, bus supports only 1 units").
    -drive file="$DISK_PATH",format=qcow2,if=none,id=hd0
    -device ide-hd,drive=hd0,bus=ide.0,bootindex=1
    -drive file="$ISO_PATH",media=cdrom,readonly=on,if=none,id=cdrom0
    -device ide-cd,drive=cdrom0,bus=ide.2,bootindex=3

    # Network with TFTP. bootfile=ipxe.efi: OVMF downloads ipxe.efi via TFTP and
    # executes it as a UEFI binary; iPXE then chains to boot.ipxe over HTTP
    # (10.0.2.2 = host). The NIC stays virtio: the iPXE ROM drives PXE, and WinPE
    # does not need a NIC driver for a CD-based install.
    -netdev user,id=net0,tftp="$TFTP_DIR",bootfile=ipxe.efi
    -device virtio-net-pci,netdev=net0,romfile="$IPXE_ROM",bootindex=2
    
    # Display — set HEADLESS=1 to run with no GUI window (serial-only; for testing)
    -display "$QEMU_DISPLAY"

    # Serial log — captures OVMF + iPXE debug output
    -serial file:/tmp/qemu-serial.log
)

# Add common options based on availability
if command -v virsh &> /dev/null; then
    # Could add libvirt integration here
    :
fi

# Execute
echo "QEMU command:"
echo "  ${QEMU_CMD[*]}"
echo ""

exec "${QEMU_CMD[@]}"