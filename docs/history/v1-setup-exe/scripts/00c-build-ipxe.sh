#!/bin/bash
# 00c-build-ipxe.sh - Build ipxe.efi with embedded chainload script
#
# Why this is needed:
#   OVMF (the UEFI firmware) has its own built-in PXE stack ("UEFI PXEv4").
#   It downloads the TFTP boot file and tries to execute it as a UEFI binary.
#   If we serve boot.ipxe (a plain text script) as the boot file, OVMF fails
#   with "Not Found" — it can't execute a text file as UEFI code.
#
#   The fix: serve ipxe.efi as the TFTP boot file. ipxe.efi IS a UEFI binary
#   (it's iPXE compiled as an EFI application). OVMF downloads it and executes
#   it. iPXE then takes over, runs the embedded script, which fetches boot.ipxe
#   over HTTP and executes it as an iPXE script.
#
# Boot chain after this fix:
#   OVMF UEFI PXE → ipxe.efi (TFTP) → chain boot.ipxe (HTTP) → wimboot → WinPE
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/config.sh"

echo "=== Build iPXE EFI ==="

# Build dependencies are installed by 01-install-deps.sh (build-essential,
# liblzma-dev, binutils-dev, git, mtools, syslinux, isolinux). Verify the key
# tools are present rather than re-installing them here.
for tool in gcc make git mcopy; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: build tool '$tool' not found. Run 01-install-deps.sh first." >&2
        exit 1
    fi
done

# Build directory
BUILD_DIR="$PROJECT_ROOT/build/ipxe"
mkdir -p "$BUILD_DIR"

# Clone or update iPXE source
IPXE_SRC="$BUILD_DIR/ipxe"
if [[ -d "$IPXE_SRC/.git" ]]; then
    echo "Updating iPXE source..."
    git -C "$IPXE_SRC" pull --ff-only
else
    echo "Cloning iPXE source..."
    git clone --depth 1 https://github.com/ipxe/ipxe.git "$IPXE_SRC"
fi

# Write the embedded boot script
# This script runs inside iPXE immediately at startup.
# It chains to boot.ipxe over HTTP. If that fails, it drops to the iPXE shell
# so you can diagnose the problem interactively.
#
# IPXE_CHAIN_HOST is the host that serves boot.ipxe over HTTP. It defaults to
# 10.0.2.2 (the QEMU user-net gateway = the host, for VM installs). For physical
# machines, 07-setup-physical.sh re-runs this script with IPXE_CHAIN_HOST set to
# the host's real LAN IP. (Baked in at build time because the embedded script
# runs before any of our HTTP config is available.)
IPXE_CHAIN_HOST="${IPXE_CHAIN_HOST:-10.0.2.2}"
echo "Embedding chain target: http://${IPXE_CHAIN_HOST}:${HTTP_PORT}/boot.ipxe"
EMBED_SCRIPT="$BUILD_DIR/chain.ipxe"
cat > "$EMBED_SCRIPT" << EOF
#!ipxe
echo === iPXE chainloader ===
:retry_dhcp
dhcp && goto got_dhcp
echo DHCP failed, retrying in 3s...
sleep 3
goto retry_dhcp
:got_dhcp
echo Chaining to http://${IPXE_CHAIN_HOST}:${HTTP_PORT}/boot.ipxe ...
chain http://${IPXE_CHAIN_HOST}:${HTTP_PORT}/boot.ipxe
echo chain failed - entering shell
shell
EOF

echo "Embedded script:"
cat "$EMBED_SCRIPT"
echo ""

# Build ipxe.efi
echo "Building ipxe.efi (this takes 1-3 minutes)..."
make -C "$IPXE_SRC/src" \
    bin-x86_64-efi/ipxe.efi \
    EMBED="$EMBED_SCRIPT" \
    -j"$(nproc)"

# Copy to pxe/ (rm first so we can overwrite even a read-only/old binary)
mkdir -p "$PROJECT_ROOT/pxe"
rm -f "$PROJECT_ROOT/pxe/ipxe.efi"
cp "$IPXE_SRC/src/bin-x86_64-efi/ipxe.efi" "$PROJECT_ROOT/pxe/ipxe.efi"

echo ""
echo "ipxe.efi built successfully!"
echo "  Output: pxe/ipxe.efi ($(du -sh "$PROJECT_ROOT/pxe/ipxe.efi" | cut -f1))"
echo ""
echo "Next: Run 04-setup-http.sh (to regenerate boot.ipxe), then 06-boot-vm.sh"
