#!/bin/bash
# 00b-download-iso.sh — Download and build a Windows 11 ISO via UUP Dump
#
# UUP Dump downloads individual Windows Update packages directly from
# Microsoft's update servers (the same mechanism Windows itself uses),
# then assembles them into a bootable ISO. This is more reliable than
# the gated consumer download page, which blocks scripted access.
#
# Process:
#   1. Query api.uupdump.net for the latest stable Win11 x64 build UUID
#   2. Download the UUP Dump conversion zip (contains uup_download_linux.sh)
#   3. Run the script: downloads UUP packages via aria2c, builds ISO
#
# Requirements (installed by 01-install-deps.sh):
#   aria2c, cabextract, wimlib-imagex, chntpw, genisoimage
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/config.sh"

ISO_DEST="${ISO_PATH:-$PROJECT_ROOT/win11.iso}"

echo "=== Download Windows 11 ISO via UUP Dump ==="

# --- Dependency check ---
for prog in aria2c cabextract wimlib-imagex chntpw genisoimage python3 curl unzip; do
    if ! command -v "$prog" &>/dev/null; then
        echo "ERROR: '$prog' not found. Run 01-install-deps.sh first." >&2
        exit 1
    fi
done

# --- Find latest stable Windows 11 amd64 build UUID ---
echo "Querying UUP Dump for latest Windows 11 ${WIN_RELEASE} amd64 build..."

BUILD_LIST=$(curl -s "https://api.uupdump.net/listid.php?search=Windows+11&sortByDate=1")

# Pick the newest "Windows 11, version <WIN_RELEASE>" amd64 entry
UUID=$(echo "$BUILD_LIST" | python3 -c "
import json, sys
data = json.load(sys.stdin)
release = '${WIN_RELEASE}'
for b in data['response']['builds'].values():
    title = b.get('title', '')
    arch  = b.get('arch', '')
    if arch == 'amd64' and release in title and 'Insider' not in title and 'OOBE' not in title:
        print(b['uuid'])
        break
")

if [[ -z "$UUID" ]]; then
    echo "ERROR: Could not find a '${WIN_RELEASE}' amd64 build in UUP Dump." >&2
    echo "       Check WIN_RELEASE in config.sh (current: ${WIN_RELEASE})." >&2
    exit 1
fi

BUILD_TITLE=$(echo "$BUILD_LIST" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for b in data['response']['builds'].values():
    if b.get('uuid') == '${UUID}':
        print(b.get('title', 'unknown'))
        break
")

echo "Found: $BUILD_TITLE"
echo "UUID:  $UUID"

# --- Download UUP Dump conversion zip ---
WORK_DIR="$PROJECT_ROOT/tools/uupdump-work"
mkdir -p "$WORK_DIR"

ZIP_URL="https://uupdump.net/get.php?id=${UUID}&pack=en-us&edition=PROFESSIONAL&autodl=2"
ZIP_FILE="$WORK_DIR/uupdump-convert.zip"

echo "Downloading UUP Dump conversion package..."
curl -fsSL "$ZIP_URL" -o "$ZIP_FILE"

# Extract into work dir (overwrite on re-run)
unzip -o "$ZIP_FILE" -d "$WORK_DIR" > /dev/null

# --- Run the Linux download + conversion script ---
echo ""
echo "Downloading Windows UUP packages from Microsoft and building ISO..."
echo "(This downloads ~4-6 GB — may take 10-30 minutes depending on connection)"
echo ""

chmod +x "$WORK_DIR/uup_download_linux.sh"
(cd "$WORK_DIR" && bash uup_download_linux.sh)

# --- Locate the resulting ISO ---
BUILT_ISO=$(find "$WORK_DIR" -maxdepth 1 -iname "*.iso" | head -1)

if [[ -z "$BUILT_ISO" ]]; then
    echo ""
    echo "ERROR: No ISO was produced in $WORK_DIR" >&2
    echo "       Check $WORK_DIR/aria2_download.log for details." >&2
    exit 1
fi

echo ""
echo "Moving ISO to: $ISO_DEST"
mv "$BUILT_ISO" "$ISO_DEST"

ISO_SIZE=$(du -h "$ISO_DEST" | cut -f1)
echo "ISO built successfully!"
echo "  Path: $ISO_DEST"
echo "  Size: $ISO_SIZE"
echo ""

# Update ISO_PATH in config.sh, but only if it isn't already set — don't clobber a
# path the user chose. We sourced config.sh above, so $ISO_PATH reflects its
# current value; replace the whole ISO_PATH= line (robust to any prior value).
if [[ -z "${ISO_PATH:-}" ]]; then
    sed -i "s|^ISO_PATH=.*|ISO_PATH=\"$ISO_DEST\"|" "$PROJECT_ROOT/config.sh"
    echo "config.sh updated: ISO_PATH=\"$ISO_DEST\""
fi

echo ""
echo "Next: Run 02-extract-winpe.sh"
