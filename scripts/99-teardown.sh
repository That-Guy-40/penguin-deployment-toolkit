#!/bin/bash
# 99-teardown.sh - Stop services and (optionally) remove VM state this project created.
#
#   (no args)   Stop running services only (QEMU, swtpm, our nginx, our dnsmasq),
#               unmount the ISO. Non-destructive: disk, ISO and extracted files stay.
#   --purge     Also delete this VM's disk, TPM state, OVMF NVRAM, and the generated
#               boot.ipxe / nginx.conf / dnsmasq.conf. Prompts unless --yes.
#   --yes,-y    Don't prompt for --purge.
#
# Intentionally NOT removed (expensive to recreate): win11.iso, http/winpe/* (the
# extracted WinPE incl. the ~500 MB boot.wim), pxe/ipxe.efi, pxe/wimboot, build/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"
source "$PROJECT_ROOT/config.sh"

PURGE=0; ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --purge)   PURGE=1 ;;
        --yes|-y)  ASSUME_YES=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $arg (try --help)" >&2; exit 1 ;;
    esac
done

DISK_PATH="$VMS_DIR/${VM_NAME}.qcow2"
TPM_STATE_PATH="$VMS_DIR/${VM_NAME}-swtpm"
OVMF_VARS_PATH="$VMS_DIR/${VM_NAME}-OVMF_VARS.fd"

echo "=== Teardown (VM: $VM_NAME) ==="

# --- 1. Stop QEMU for THIS VM (matched by its disk path on the cmdline) ---
mapfile -t QEMU_PIDS < <(pgrep -f "$DISK_PATH" 2>/dev/null || true)
if (( ${#QEMU_PIDS[@]} )); then
    echo "Stopping QEMU (${QEMU_PIDS[*]})..."
    kill "${QEMU_PIDS[@]}" 2>/dev/null || true
else
    echo "QEMU: not running."
fi

# --- 2. Stop swtpm (its pid file) ---
SWTPM_PID="$TPM_STATE_PATH/swtpm.pid"
if [[ -f "$SWTPM_PID" ]] && kill -0 "$(cat "$SWTPM_PID" 2>/dev/null)" 2>/dev/null; then
    echo "Stopping swtpm ($(cat "$SWTPM_PID"))..."
    kill "$(cat "$SWTPM_PID")" 2>/dev/null || true
    rm -f "$SWTPM_PID" "$TPM_STATE_PATH/swtpm.sock"
else
    echo "swtpm: not running."
fi

# --- 3. Stop OUR (rootless) nginx by its pid file, else by our conf path.
#         Never touches other nginx/services (e.g. an essential service on :8080). ---
NGINX_PID="$PROJECT_ROOT/run/nginx.pid"
NGINX_CONF_PATH="$PROJECT_ROOT/run/nginx.conf"
if [[ -f "$NGINX_PID" ]] && kill -0 "$(cat "$NGINX_PID" 2>/dev/null)" 2>/dev/null; then
    echo "Stopping project nginx ($(cat "$NGINX_PID"))..."
    nginx -s quit -c "$NGINX_CONF_PATH" -p "$PROJECT_ROOT/run" 2>/dev/null \
        || kill "$(cat "$NGINX_PID")" 2>/dev/null || true
else
    mapfile -t NGINX_PIDS < <(pgrep -f "$NGINX_CONF_PATH" 2>/dev/null || true)
    if (( ${#NGINX_PIDS[@]} )); then
        echo "Stopping project nginx (${NGINX_PIDS[*]})..."
        kill "${NGINX_PIDS[@]}" 2>/dev/null || true
    else
        echo "nginx (this project): not running."
    fi
fi

# --- 4. Stop OUR dnsmasq (from 07) ---
DNSMASQ_CONF_PATH="$PROJECT_ROOT/pxe/dnsmasq.conf"
DNSMASQ_PID="$PROJECT_ROOT/pxe/dnsmasq.pid"
if [[ -f "$DNSMASQ_PID" ]] && kill -0 "$(cat "$DNSMASQ_PID" 2>/dev/null)" 2>/dev/null; then
    echo "Stopping dnsmasq ($(cat "$DNSMASQ_PID"))..."
    sudo kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
    rm -f "$DNSMASQ_PID"
else
    mapfile -t DM_PIDS < <(pgrep -f "$DNSMASQ_CONF_PATH" 2>/dev/null || true)
    if (( ${#DM_PIDS[@]} )); then
        echo "Stopping dnsmasq (${DM_PIDS[*]})..."
        sudo kill "${DM_PIDS[@]}" 2>/dev/null || true
    else
        echo "dnsmasq (this project): not running."
    fi
fi

# --- 5. Unmount the ISO if a previous 02 run left it mounted ---
if mountpoint -q /mnt/winiso 2>/dev/null; then
    echo "Unmounting /mnt/winiso..."
    sudo umount /mnt/winiso 2>/dev/null || true
    sudo rmdir /mnt/winiso 2>/dev/null || true
else
    echo "ISO mount: not present."
fi

# --- 6. Legacy cleanup: older 04 added www-data to your group; undo if present ---
OWNER_GROUP="$(id -gn)"
if id -nG www-data 2>/dev/null | grep -qw "$OWNER_GROUP"; then
    echo "Removing legacy www-data membership of group '$OWNER_GROUP'..."
    sudo gpasswd -d www-data "$OWNER_GROUP" >/dev/null 2>&1 || true
fi

echo "Services stopped."

# --- 7. Optional purge of VM state + generated configs ---
if (( PURGE )); then
    echo ""
    echo "--purge will delete:"
    echo "  $DISK_PATH"
    echo "  $TPM_STATE_PATH/"
    echo "  $OVMF_VARS_PATH"
    echo "  run/  pxe/boot.ipxe  http/boot.ipxe  pxe/dnsmasq.conf"
    echo "(win11.iso, http/winpe/*, pxe/ipxe.efi, pxe/wimboot are kept.)"
    if (( ! ASSUME_YES )); then
        read -rp "Proceed? (y/N) " reply
        [[ "$reply" =~ ^[Yy]$ ]] || { echo "Purge cancelled."; exit 0; }
    fi
    # VM state may be root-owned (created via sudo) — use sudo rm for those.
    sudo rm -f  "$DISK_PATH" "$OVMF_VARS_PATH"
    sudo rm -rf "$TPM_STATE_PATH"
    # Generated configs/runtime are user-owned (rootless) — plain rm.
    rm -rf run
    rm -f  pxe/boot.ipxe http/boot.ipxe pxe/dnsmasq.conf
    echo "Purge complete. Re-run from 05-create-vm.sh to rebuild the VM."
fi
