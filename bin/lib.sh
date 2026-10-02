#!/bin/bash
# lib.sh - shared by every bin/ script: locate the repo, load config.sh, helpers.
# Source it; do not run it.

set -euo pipefail

PDT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PDT_ROOT"

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
info() { echo "$*"; }

# need <cmd>...: fail with one message naming every missing command.
need() {
    local missing=() c
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    (( ${#missing[@]} == 0 )) || die "missing command(s): ${missing[*]}"
}

[[ -f "$PDT_ROOT/config.sh" ]] || die "config.sh not found. Run: cp config.sh.example config.sh   (then edit it)"
# shellcheck disable=SC1091
source "$PDT_ROOT/config.sh"

: "${HTTP_HOST:?config.sh: HTTP_HOST is not set}"
: "${HTTP_PORT:?config.sh: HTTP_PORT is not set}"
HTTP_BIND="${HTTP_BIND:-}"
STATE_DIR="${STATE_DIR:-$PDT_ROOT/run}"
HTTP_DIR="$PDT_ROOT/http"
PXE_DIR="$PDT_ROOT/pxe"
VMS_DIR="$PDT_ROOT/vms"
BUILD_DIR="$PDT_ROOT/build"
BEACON_LOG="$STATE_DIR/beacons.log"
ACCESS_LOG="$STATE_DIR/access.log"
BASE_URL="http://${HTTP_HOST}:${HTTP_PORT}"
export PDT_ROOT STATE_DIR HTTP_DIR BEACON_LOG ACCESS_LOG

# in_userns: true when we are "root" inside a user namespace (bin/lab-netns),
# where uid 0 is the only account there is and maps to the real user outside.
in_userns() { (( EUID == 0 )) && ! grep -qE '^\s*0\s+0\s+4294967295' /proc/self/uid_map; }

# need_iso: validate ISO_PATH for the scripts that read the ISO.
need_iso() {
    [[ -n "${ISO_PATH:-}" ]] || die "config.sh: ISO_PATH is not set"
    [[ -f "$ISO_PATH" ]]     || die "ISO not found: $ISO_PATH"
}

# sha256_is <file> <hex>: true when the file's SHA-256 equals <hex>.
sha256_is() { [[ "$(sha256sum "$1" | cut -d' ' -f1)" == "$2" ]]; }

# The ISO's file listing, read once. (Never pipe 7z into something that exits
# early: under pipefail the SIGPIPE turns a successful lookup into a failure.)
_ISO_LISTING=""
_iso_listing() {
    [[ -n "$_ISO_LISTING" ]] || _ISO_LISTING="$(7z l -slt "$ISO_PATH")" || die "7z cannot read $ISO_PATH"
}

# iso_path <path>: the path as spelled inside the ISO (case-insensitive match), or empty.
iso_path() {
    _iso_listing
    awk -v want="${1,,}" '/^Path = / { p = substr($0, 8); if (!hit && tolower(p) == want) { print p; hit = 1 } }' <<<"$_ISO_LISTING"
}

# iso_size <path-in-iso>: byte size of one file inside the ISO (case-insensitive path), or empty.
iso_size() {
    _iso_listing
    awk -v want="${1,,}" '/^Path = / { p = tolower(substr($0, 8)) } /^Size = / { if (!hit && p == want) { print $3; hit = 1 } }' <<<"$_ISO_LISTING"
}

# vm_load <name>: source vms/<name>/vm.conf into VM_* variables.
vm_load() {
    local name="${1:?vm name required}"
    VM_DIR="$VMS_DIR/$name"
    [[ -f "$VM_DIR/vm.conf" ]] || die "no such VM: $name (create it with bin/vm-create $name)"
    # shellcheck disable=SC1091
    source "$VM_DIR/vm.conf"
}

# vm_pid <name>: print the QEMU pid if this VM is running (pidfile + live check).
vm_pid() {
    local f="$VMS_DIR/$1/qemu.pid" p
    [[ -f "$f" ]] || return 1
    p="$(cat "$f")"
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && [[ "$(ps -o comm= -p "$p")" == qemu-system-* ]] || return 1
    echo "$p"
}

# vm_monitor <name> <command...>: send one HMP command to the VM's QEMU monitor.
vm_monitor() {
    local name="$1"; shift
    vm_load "$name"
    printf '%s\n' "$*" | socat -t 2 - "TCP:127.0.0.1:${VM_MONITOR_PORT}" 2>/dev/null
}
