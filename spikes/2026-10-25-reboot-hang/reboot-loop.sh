#!/bin/bash
# reboot-loop.sh - reboot a --mode shell lab VM from WinPE N times and record
# every hang (TODO.md: "Lab VMs sometimes hang at a guest-initiated reboot").
#
#   reboot-loop.sh <vm> <cycles> <out-dir> [vm-boot options...]
#
# The VM must exist (bin/vm-create <vm> --mode shell ...). Each cycle: start
# bin/await <vm> shell (new events only), then bin/shell <vm> 'wpeutil reboot'.
# The `shell ok` beacon of the next boot within HANG_AFTER s = PASS; otherwise
# a HANG: QEMU status, registers twice 2 s apart, the instructions at CPU#0's
# RIP, a screendump, serial/disk mtimes, the vars.fd hash, then vm-stop --force
# and vm-boot again (that cold boot is not a counted cycle).
# PRE='<cmd with %d>' runs a command on the machine before each reboot (e.g. a
# bcdedit that writes a UEFI variable); IDLE=<s> waits that long first.
# Exit: 0 when no cycle hung, 1 when at least one did, 2 on a setup failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$HERE/bin"
VM="${1:?vm}"; N="${2:?cycles}"; OUT="$(realpath -m "${3:?out-dir}")"; shift 3   # absolute: QEMU resolves pmemsave paths from its own cwd
BOOT=("$@")
HANG_AFTER="${HANG_AFTER:-300}"   # a reboot that has not come back in this long is a hang
COLD_AFTER="${COLD_AFTER:-300}"   # the first boot and a recovery boot (HANG_AFTER=1 with this left alone is the detector's negative control)
PRE="${PRE:-}"       # a cmd line to run on the machine right before each reboot (%d = the cycle number)
IDLE="${IDLE:-0}"    # seconds to let WinPE sit before each reboot
mkdir -p "$OUT"
LOG="$OUT/loop.log"
ts() { date +%H:%M:%S; }
say() { echo "$(ts) $*" | tee -a "$LOG"; }
source "$BIN/lib.sh"; set +e   # lib.sh sets -e; this script records failures
source "$(dirname "${BASH_SOURCE[0]}")/hang-record.sh"
mon() { vm_monitor "$VM" "$@" | grep -av -e "monitor - type" -e $'\x1b\[K' | sed "s/^(qemu) //"; }
VMDIR="$HERE/vms/$VM"
[[ -f "$VMDIR/vm.conf" ]] || { say "no such VM $VM"; exit 2; }

HANGS=0; PASSES=0
"$BIN/vm-boot" "$VM" "${BOOT[@]}" >>"$LOG" 2>&1 || { say "vm-boot failed"; exit 2; }
say "cold boot: $(tail -2 "$LOG" | head -1)"
sha256sum "$VMDIR/vars.fd" | tee -a "$LOG" >"$OUT/vars-before.sha"
t0=$(date +%s)
if ! "$BIN/await" "$VM" shell "$COLD_AFTER" >>"$LOG" 2>&1; then say "cold boot did not reach WinPE in $COLD_AFTER s"; exit 2; fi
say "cold boot reached WinPE in $(( $(date +%s) - t0 )) s"

for (( i=1; i<=N; i++ )); do
    (( IDLE )) && sleep "$IDLE"   # before the await starts: its clock is the hang detector's
    "$BIN/await" "$VM" shell "$HANG_AFTER" >>"$LOG" 2>&1 & AW=$!
    sleep 1
    t0=$(date +%s)
    if [[ -n "$PRE" ]]; then
        # shellcheck disable=SC2059
        pre="$(printf "$PRE" "$i")"; "$BIN/shell" "$VM" "$pre" --timeout 30 >>"$LOG" 2>&1; echo "$(ts) cycle $i: pre-reboot command rc=$? ($pre)" >>"$LOG"
        t0=$(date +%s)
    fi
    "$BIN/shell" "$VM" 'wpeutil reboot' --timeout 20 >>"$LOG" 2>&1   # usually times out: the machine is gone
    wait $AW; rc=$?
    dt=$(( $(date +%s) - t0 ))
    if (( rc == 0 )); then
        PASSES=$((PASSES+1)); say "cycle $i: PASS, back in WinPE after $dt s"
    else
        HANGS=$((HANGS+1)); say "$(record_hang "$VM" "$i" "$OUT" "no 'shell ok' within $HANG_AFTER s of 'wpeutil reboot'")"
        "$BIN/vm-stop" "$VM" --force >>"$LOG" 2>&1
        "$BIN/await" "$VM" shell "$COLD_AFTER" >>"$LOG" 2>&1 & AW=$!
        sleep 1
        "$BIN/vm-boot" "$VM" "${BOOT[@]}" >>"$LOG" 2>&1 || { say "vm-boot failed after hang"; exit 2; }
        wait $AW || { say "recovery boot did not reach WinPE"; exit 2; }
        say "cycle $i: recovered by vm-stop --force + vm-boot"
    fi
    sleep 5
done
say "RESULT $VM: $PASSES of $N reboots fine, $HANGS hung (boot options: ${BOOT[*]:-none}; PRE='$PRE' IDLE=$IDLE LOAD=${LOAD:-})"
echo "$VM $PASSES $HANGS $N ${BOOT[*]:-none} PRE='$PRE' IDLE=$IDLE LOAD=${LOAD:-}" >"$OUT/result.txt"
(( HANGS == 0 ))
