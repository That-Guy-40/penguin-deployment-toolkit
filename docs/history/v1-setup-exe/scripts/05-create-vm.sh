#!/bin/bash
# 05-create-vm.sh - Create VM disk and TPM state
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Source config
source "$PROJECT_ROOT/config.sh"

echo "=== Create VM ==="

validate_vm_config || exit 1

# Create vms directory
mkdir -p "$VMS_DIR"

# === BITLOCKER RECOVERY PREVENTION ===
# If the disk is being recreated, the TPM state and OVMF NVRAM MUST be cleared
# too: a fresh disk with the old TPM state triggers BitLocker recovery, and stale
# NVRAM boot entries point at an OS that no longer exists. Ask FIRST, and only
# wipe when the user actually chooses to recreate (an earlier version wiped TPM/
# NVRAM before asking, which broke an installed VM when the answer was "keep").
DISK_PATH="$VMS_DIR/${VM_NAME}.qcow2"
TPM_STATE_PATH="$VMS_DIR/${VM_NAME}-swtpm"
OVMF_VARS_PATH="$VMS_DIR/${VM_NAME}-OVMF_VARS.fd"

if [[ -f "$DISK_PATH" ]]; then
    echo "Existing disk found: $DISK_PATH"
    read -p "Recreate disk? This wipes the VM, its TPM state and NVRAM. (y/N) " -n 1 -r reply
    echo
    if [[ $reply =~ ^[Yy]$ ]]; then
        rm -f "$DISK_PATH"
        if [[ -d "$TPM_STATE_PATH" ]]; then
            echo "Clearing TPM state (prevents BitLocker recovery on the new disk)..."
            rm -rf "$TPM_STATE_PATH"
        fi
        if [[ -f "$OVMF_VARS_PATH" ]]; then
            echo "Clearing OVMF NVRAM for a fresh boot..."
            rm -f "$OVMF_VARS_PATH"
        fi
    else
        echo "Keeping existing disk, TPM state and NVRAM."
    fi
fi

# === CREATE OVMF_VARS ===
echo "Creating OVMF_VARS..."
if [[ -f "$OVMF_VARS_PATH" ]]; then
    echo "OVMF_VARS already exists, keeping"
else
    if [[ ! -f "$OVMF_VARS_TEMPLATE" ]]; then
        echo "ERROR: OVMF_VARS template not found: $OVMF_VARS_TEMPLATE" >&2
        exit 1
    fi
    cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS_PATH"
    echo "Created: $OVMF_VARS_PATH"
fi

# === CREATE QCOW2 DISK ===
echo "Creating virtual disk..."
if [[ ! -f "$DISK_PATH" ]]; then
    # Check for qemu-img
    if ! command -v qemu-img &> /dev/null; then
        echo "ERROR: qemu-img not found. Install qemu-utils." >&2
        exit 1
    fi
    
    qemu-img create -f qcow2 "$DISK_PATH" "${VM_DISK_SIZE}"
    echo "Created: $DISK_PATH (${VM_DISK_SIZE})"
fi

# Verify disk
if qemu-img info "$DISK_PATH" &> /dev/null; then
    echo "Disk verified: $(qemu-img info "$DISK_PATH" | grep 'virtual size' | head -1)"
else
    echo "ERROR: Failed to verify disk" >&2
    exit 1
fi

# === CREATE TPM STATE DIRECTORY ===
echo "Creating TPM state directory..."
mkdir -p "$TPM_STATE_PATH"

echo ""
echo "VM created successfully!"
echo "  - Disk: $DISK_PATH"
echo "  - TPM: $TPM_STATE_PATH"
echo "  - OVMF_VARS: $OVMF_VARS_PATH"
echo ""
echo "Next: Run 06-boot-vm.sh"