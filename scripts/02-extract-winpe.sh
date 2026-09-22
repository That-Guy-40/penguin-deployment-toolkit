#!/bin/bash
# 02-extract-winpe.sh - Extract Windows PE files from ISO
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Source config
source "$PROJECT_ROOT/config.sh"

# Validate config before proceeding
validate_config

echo "=== Extract Windows PE Files ==="

# Mount ISO
MOUNT_POINT="/mnt/winiso"

if [[ ! -d "$MOUNT_POINT" ]]; then
    echo "Creating mount point..."
    sudo mkdir -p "$MOUNT_POINT"
fi

echo "Mounting ISO: $ISO_PATH"
sudo mount -o loop,ro "$ISO_PATH" "$MOUNT_POINT"

# Cleanup function
cleanup() {
    echo "Unmounting ISO..."
    sudo umount "$MOUNT_POINT" || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

# Extract files
echo "Extracting boot files..."

# UUP Dump ISOs use slightly different paths than retail ISOs:
#   bootmgfw.efi → efi/boot/bootx64.efi  (UEFI fallback boot path)
#   BCD          → efi/microsoft/boot/bcd (lowercase)
#   boot.sdi     → boot/boot.sdi          (same)
#   boot.wim     → sources/boot.wim       (same)
# We copy bootx64.efi as "bootmgfw.efi" — the name wimboot looks for.

SRC_EFI="$MOUNT_POINT/efi/boot/bootx64.efi"
SRC_BCD="$MOUNT_POINT/efi/microsoft/boot/bcd"
SRC_SDI="$MOUNT_POINT/boot/boot.sdi"
SRC_WIM="$MOUNT_POINT/sources/boot.wim"

# Verify source files exist
for file in "$SRC_EFI" "$SRC_BCD" "$SRC_SDI" "$SRC_WIM"; do
    if [[ ! -f "$file" ]]; then
        echo "ERROR: Source file not found: $file" >&2
        exit 1
    fi
done

# Create output directory
mkdir -p "http/winpe"

cp "$SRC_EFI" "http/winpe/bootmgfw.efi"
cp "$SRC_BCD" "http/winpe/BCD"
cp "$SRC_SDI" "http/winpe/boot.sdi"
cp "$SRC_WIM" "http/winpe/boot.wim"

# Verify extraction
echo "Verifying extracted files..."
missing=0
for file in bootmgfw.efi BCD boot.sdi boot.wim; do
    if [[ ! -f "http/winpe/$file" ]]; then
        echo "ERROR: Failed to extract $file" >&2
        missing=1
    fi
done

if [[ $missing -ne 0 ]]; then
    echo "ERROR: Some files were not extracted successfully" >&2
    exit 1
fi

# Normalize ownership/permissions. Files copied from the read-only ISO mount come
# out mode 0444, and if this script was run via sudo they are owned by root. Make
# them owned by the invoking user and writable, so later steps (03 injection,
# rootless nginx in 04) don't need sudo to touch them.
if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" http/winpe
fi
chmod -R u+rw http/winpe

# Verify wimboot symlink
if [[ ! -L "http/winpe/wimboot" ]]; then
    ln -sf "../../pxe/wimboot" "http/winpe/wimboot"
fi

echo ""
echo "Windows PE files extracted successfully!"
echo "  - bootmgfw.efi"
echo "  - BCD"
echo "  - boot.sdi"
echo "  - boot.wim"
echo ""
echo "Next: Run 03-inject-autounattend.sh"
