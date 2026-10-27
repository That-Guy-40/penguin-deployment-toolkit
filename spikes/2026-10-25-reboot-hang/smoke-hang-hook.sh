#!/bin/bash
# smoke-hang-hook.sh - SMOKE_HANG_HOOK for bin/smoke: <vm> <label> <out-dir>.
# Records the hung VM with hang-record.sh (registers, stack, code bytes,
# firmware memory around both RIPs, lapics, I/O map, screendump) before
# bin/smoke force-stops it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; BIN="$HERE/bin"
source "$BIN/lib.sh"; set +e
source "$(dirname "${BASH_SOURCE[0]}")/hang-record.sh"
# SMOKE_HANG_WAIT=<seconds>: then leave the VM alone that long, watching for it to
# move on by itself (hang-record.sh), before bin/smoke force-stops it. bin/smoke's
# own deploy budget keeps running meanwhile, so the hung machine's later rows fail;
# the point is the answer in hang-<label>-wait.txt. Only worth it for the PEI
# variant (CpuMpPei's 71.6-min AP timeout); the DXE variant is a loop with no exit
# condition (README, "Caught again"), so waiting on it is wasted lab time: the wait
# runs only when CPU#0's recorded RIP matches SMOKE_HANG_WAIT_RIP, by default
# CpuMpPei's image range on the OVMF 2025.11 layout, 0x7bfe1000..0x7bfeda00
# (layout/images.txt; another firmware build needs its own range).
OUT="$(realpath -m "$3")"
record_hang "$1" "$2" "$OUT" "bin/smoke: no next beacon after the reboot"
if [[ -n "${SMOKE_HANG_WAIT:-}" ]]; then
    rip="$(grep -aoE 'RIP=[0-9a-f]+' "$OUT/hang-$2.txt" | head -1 | cut -d= -f2)"
    # the default on its own line: a '}' inside ${VAR:-...} ends the expansion (the
    # first version's regex lost its '{3}' and never matched; wait-helper-control.out)
    re="${SMOKE_HANG_WAIT_RIP:-}"; [[ -n "$re" ]] || re='^0*7bfe[1-9a-d][0-9a-f]{3}$'
    if [[ "$rip" =~ $re ]]; then
        wait_for_self_recovery "$1" "$2" "$OUT" "$SMOKE_HANG_WAIT"
    else
        echo "$2: no self-recovery wait: CPU#0 RIP=${rip:-?} is not in CpuMpPei (SMOKE_HANG_WAIT_RIP), so this is the DXE variant, a loop with no exit; UNKNOWN whether it would ever move on, not waited for" >"$OUT/hang-$2-wait.txt"
        echo "HANG $2: DXE variant (RIP=${rip:-?}), not waiting (hang-$2-wait.txt)"
    fi
fi
