#!/bin/bash
# 03-inject-autounattend.sh - Inject autounattend.xml + startnet.cmd into boot.wim
#
# CRITICAL DESIGN NOTE (this is the bug this script exists to avoid):
#   A Windows install boot.wim contains TWO images:
#     index 1 = "Microsoft Windows PE"     (bare PE)
#     index 2 = "Microsoft Windows Setup"  (this is the WIM header "Boot Index")
#   The image that actually boots is the one named by the WIM "Boot Index" (2 on
#   stock media). Injecting only into index 1 — as an earlier version did — put the
#   answer file into an image that never boots, so the install ran fully interactive.
#   We therefore inject into EVERY image in the WIM. That is correct regardless of
#   which index is the boot image and robust to differently-built ISOs.
#
# What we inject (into each image):
#   /autounattend.xml               - the answer file (setup reads it via /unattend)
#   /Windows/System32/startnet.cmd  - WinPE's first script; we make it launch setup
#
# Why a custom startnet.cmd: neither boot.wim image ships a winpeshl.ini, so WinPE
# runs cmd.exe -> startnet.cmd on boot. The stock startnet.cmd is just "wpeinit"
# (it does NOT launch setup), so we replace it with one that starts Setup and
# points it at the answer file explicitly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/config.sh"

echo "=== Inject autounattend.xml + startnet.cmd into boot.wim ==="

ANSWER="answer/autounattend.xml"
WIM="http/winpe/boot.wim"

[[ -f "$ANSWER" ]] || { echo "ERROR: $ANSWER not found" >&2; exit 1; }
[[ -f "$WIM" ]]    || { echo "ERROR: $WIM not found. Run 02-extract-winpe.sh first." >&2; exit 1; }
command -v wimlib-imagex >/dev/null 2>&1 || { echo "ERROR: wimlib-imagex not found. Run 01-install-deps.sh first." >&2; exit 1; }

# boot.wim is copied from a read-only ISO mount and is often mode 0444 (and, if an
# earlier step ran via sudo, root-owned). wimlib-imagex update rewrites the file in
# place, so we need write access. If we already own it, just add the write bit (no
# sudo). Only fall back to sudo chown if it's owned by someone else.
if [[ ! -w "$WIM" ]]; then
    if [[ -O "$WIM" ]]; then
        echo "boot.wim is read-only — adding the write bit..."
        chmod u+w "$WIM"
    else
        echo "boot.wim is owned by another user — taking ownership (needs sudo)..."
        sudo chown "$(id -un):$(id -gn)" "$WIM"
        chmod u+w "$WIM"
    fi
fi

# --- Build the startnet.cmd that launches Windows Setup unattended ---
# WinPE auto-runs X:\Windows\System32\startnet.cmd, where X: is the boot RAM disk.
# setup.exe only auto-discovers autounattend.xml on *removable* media, not on X:,
# so we pass /unattend:X:\autounattend.xml explicitly. setup.exe and the install
# image live on the attached CD-ROM (D:\sources\...), so we scan likely letters.
#
# Secure Boot / TPM note: config.sh uses Secure-Boot-*capable* firmware in Setup
# Mode (capable but not enforcing). If a future Windows build rejects the install
# with a Secure Boot / TPM error, uncomment the three LabConfig bypass lines below
# (they set the documented WinPE registry bypass before Setup runs).
STARTNET_TMP="$(mktemp)"
cleanup() { rm -f "$STARTNET_TMP"; }
trap cleanup EXIT

cat > "$STARTNET_TMP" <<'CMD'
@echo off
wpeinit
rem --- Optional Secure Boot / TPM / RAM check bypass (see header of 03-*.sh) ---
rem reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck        /t REG_DWORD /d 1 /f
rem reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
rem reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck        /t REG_DWORD /d 1 /f
echo Searching for Windows Setup on attached media...
for %%d in (d e f g h c) do (
    if exist %%d:\sources\setup.exe (
        echo Found %%d:\sources\setup.exe - starting unattended Setup
        %%d:\sources\setup.exe /unattend:X:\autounattend.xml
        goto :done
    )
)
echo ERROR: could not find \sources\setup.exe on any drive.
echo Dropping to a command prompt for diagnosis.
cmd /k
:done
CMD
# Windows batch files want CRLF line endings.
sed -i 's/$/\r/' "$STARTNET_TMP"

# --- Inject into every image in the WIM ---
IMG_COUNT=$(wimlib-imagex info "$WIM" | awk -F': *' '/^Image Count:/ {print $2}')
BOOT_IDX=$(wimlib-imagex info "$WIM" | awk -F': *' '/^Boot Index:/ {print $2}')
[[ -n "$IMG_COUNT" ]] || { echo "ERROR: could not read image count from $WIM" >&2; exit 1; }
echo "boot.wim has $IMG_COUNT image(s); WIM Boot Index = ${BOOT_IDX:-unknown} (the image that boots)."

for idx in $(seq 1 "$IMG_COUNT"); do
    echo "Injecting into image $idx..."
    # delete --force makes this idempotent (no error if the file isn't there yet);
    # then add. wimlib-imagex has no in-place "replace", hence delete + add.
    wimlib-imagex update "$WIM" "$idx" <<UPD
delete --force /autounattend.xml
add $ANSWER /autounattend.xml
delete --force /Windows/System32/startnet.cmd
add $STARTNET_TMP /Windows/System32/startnet.cmd
UPD
done

# --- Verify both files landed in every image ---
echo "Verifying..."
fail=0
for idx in $(seq 1 "$IMG_COUNT"); do
    a=$(wimlib-imagex dir "$WIM" "$idx" 2>/dev/null | grep -ic '^/autounattend.xml$' || true)
    s=$(wimlib-imagex dir "$WIM" "$idx" 2>/dev/null | grep -ic '/Windows/System32/startnet.cmd$' || true)
    if [[ "$a" -ge 1 && "$s" -ge 1 ]]; then
        echo "  image $idx: autounattend.xml + startnet.cmd OK"
    else
        echo "  image $idx: MISSING (autounattend=$a startnet=$s)" >&2
        fail=1
    fi
done
[[ $fail -eq 0 ]] || { echo "ERROR: verification failed" >&2; exit 1; }

echo ""
echo "Injection complete into all $IMG_COUNT image(s)."
echo ""
echo "Next: Run 04-setup-http.sh"
