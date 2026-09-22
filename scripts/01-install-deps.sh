#!/bin/bash
# 01-install-deps.sh - Install dependencies and download wimboot
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Source config
source "$PROJECT_ROOT/config.sh"

echo "=== Install Dependencies ==="

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
    SUDO="sudo"
else
    SUDO=""
fi

echo "Installing dependencies..."
$SUDO apt-get update
# --- runtime + ISO-build tools ---
# wimtools      - WIM image manipulation (extract/modify boot.wim)
# nginx         - HTTP server to serve WinPE files to the VM
# aria2         - parallel downloader used by UUP Dump scripts
# cabextract    - Cabinet file extractor (required by UUP Dump converter)
# chntpw        - offline Windows registry editor (required by UUP Dump converter)
# genisoimage   - creates the final bootable ISO from UUP packages
# jq            - parses the GitHub API JSON for the wimboot release (used below)
# curl          - HTTP client used by this and the ISO-download script
# --- iPXE build toolchain (used by 00c-build-ipxe.sh) ---
# build-essential liblzma-dev binutils-dev git mtools syslinux isolinux
$SUDO apt-get install -y \
    wimtools nginx aria2 cabextract chntpw genisoimage jq curl \
    build-essential liblzma-dev binutils-dev git mtools syslinux isolinux

# Download wimboot
echo "Downloading wimboot..."
WIMBOOT_VER=$(curl -s https://api.github.com/repos/ipxe/wimboot/releases/latest | jq -r .tag_name)
WIMBOOT_URL="https://github.com/ipxe/wimboot/releases/download/${WIMBOOT_VER}/wimboot"

if [[ -f "pxe/wimboot" ]]; then
    echo "Removing existing wimboot..."
    rm -f "pxe/wimboot"
fi

echo "Fetching wimboot $WIMBOOT_VER..."
curl -L "$WIMBOOT_URL" -o "pxe/wimboot"
chmod +x "pxe/wimboot"

# Verify wimboot. Upstream publishes no stable per-file checksum, so instead of
# trusting the download blindly we sanity-check that it is a real PE/COFF binary
# (starts with "MZ") of plausible size — this catches HTML error pages, empty
# files, and truncated downloads.
if [[ ! -x "pxe/wimboot" ]]; then
    echo "ERROR: Failed to download or make wimboot executable" >&2
    exit 1
fi
if [[ "$(head -c2 pxe/wimboot)" != "MZ" ]]; then
    echo "ERROR: pxe/wimboot is not a PE binary — download likely failed:" >&2
    head -c200 pxe/wimboot >&2; echo >&2
    exit 1
fi
WIMBOOT_SIZE=$(stat -c%s pxe/wimboot)
if (( WIMBOOT_SIZE < 20000 )); then
    echo "ERROR: pxe/wimboot is suspiciously small ($WIMBOOT_SIZE bytes)" >&2
    exit 1
fi
echo "wimboot verified: PE binary, $WIMBOOT_SIZE bytes"

echo ""
echo "Dependencies installed successfully!"
echo "  - wimtools: installed"
echo "  - nginx: installed"
echo "  - wimboot: downloaded ($WIMBOOT_VER)"
echo ""
echo "Next: Run 02-extract-winpe.sh"
