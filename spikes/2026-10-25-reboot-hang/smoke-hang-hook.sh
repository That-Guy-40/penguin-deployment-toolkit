#!/bin/bash
# smoke-hang-hook.sh - SMOKE_HANG_HOOK for bin/smoke: <vm> <label> <out-dir>.
# Records the hung VM with hang-record.sh (registers, stack, code bytes,
# firmware memory around both RIPs, lapics, I/O map, screendump) before
# bin/smoke force-stops it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; BIN="$HERE/bin"
source "$BIN/lib.sh"; set +e
source "$(dirname "${BASH_SOURCE[0]}")/hang-record.sh"
record_hang "$1" "$2" "$(realpath -m "$3")" "bin/smoke: no next beacon after the reboot"
