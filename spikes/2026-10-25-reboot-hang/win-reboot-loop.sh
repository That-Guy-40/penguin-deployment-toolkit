#!/bin/bash
# win-reboot-loop.sh - deploy a lab VM, then reboot the installed Windows N
# times over SSH, recording every hang (TODO.md's reboot hang, install context).
#
#   win-reboot-loop.sh <vm> <cycles> <out-dir> <ssh-port> [vm-boot options...]
#
# The VM must exist (vm-create <vm> --role demo-ssh ...) and have an empty disk;
# vm-boot gets --fwd <ssh-port>:22 plus the options given. The deployment's own
# two reboots (WinPE -> Setup, specialize -> first logon) are watched like
# bin/smoke does and count as cycles "install-1" and "install-2". Then each
# cycle: `shutdown /r /t 0` as ops over SSH, wait for sshd to go away and come
# back. No sshd within HANG_AFTER s = a hang: recorded, vm-stop --force, vm-boot.
# REJOIN=1: the VM is already deploying (no vm-boot), DEPLOY_BUDGET=<s> is the ts-done
# wait (default 1500). SKIP_DEPLOY=1: the VM is already installed and running with sshd on <ssh-port>;
# only the N cycles run. LOAD=<text> is recorded in the result (what else the host ran).
# Exit 0 when nothing hung, 1 when something did, 2 on a setup failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; BIN="$HERE/bin"
source "$BIN/lib.sh"; set +e
source "$(dirname "${BASH_SOURCE[0]}")/hang-record.sh"
VM="${1:?vm}"; N="${2:?cycles}"; OUT="$(realpath -m "${3:?out-dir}")"; PORT="${4:?ssh-port}"; shift 4
BOOT=(--fwd "$PORT:22" "$@")
HANG_AFTER="${HANG_AFTER:-300}"
KEY="${LAB_KEY:-$HOME/.ssh/id_ed25519}"
mkdir -p "$OUT"; LOG="$OUT/loop.log"
say() { echo "$(date +%H:%M:%S) $*" | tee -a "$LOG"; }
SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes -o LogLevel=ERROR -i "$KEY" -p "$PORT" ops@127.0.0.1)
HANGS=0; PASSES=0; RESULTS=()

recover() {  # <label>
    "$BIN/vm-stop" "$VM" --force >>"$LOG" 2>&1
    "$BIN/vm-boot" "$VM" "${BOOT[@]}" >>"$LOG" 2>&1 || { say "vm-boot failed after hang $1"; exit 2; }
    say "$1: recovered by vm-stop --force + vm-boot"
}
# await_or_hang <label> <step> <secs>: a deployment event, or a recorded hang + recovery
await_or_hang() {
    local label="$1" step="$2" secs="$3"
    if "$BIN/await" "$VM" "$step" "$secs" >>"$LOG" 2>&1; then PASSES=$((PASSES+1)); RESULTS+=("$label=pass"); say "$label: PASS ($step)"; return 0; fi
    HANGS=$((HANGS+1)); RESULTS+=("$label=HANG")
    say "$(record_hang "$VM" "$label" "$OUT" "no $step within $secs s")"
    recover "$label"
    "$BIN/await" "$VM" "$step" "$secs" >>"$LOG" 2>&1 || { say "$label: no $step after recovery either"; exit 2; }
}

if [[ -n "${SKIP_DEPLOY:-}" ]]; then
    # the VM is already deployed and running with sshd forwarded: only the reboot cycles
    "${SSH[@]}" hostname >>"$LOG" 2>&1 || { say "SKIP_DEPLOY set but no sshd on $PORT"; exit 2; }
    say "SKIP_DEPLOY: $VM already installed, $N reboots over SSH"
    N_TOTAL=$N
else
N_TOTAL=$((N+2))
if [[ -n "${REJOIN:-}" ]]; then
    # the deployment is already running (an earlier driver gave up on it): watch from here
    say "REJOIN: $VM is deploying, watching from ts-done on"
else
    "$BIN/vm-boot" "$VM" "${BOOT[@]}" >>"$LOG" 2>&1 || { say "vm-boot failed"; exit 2; }
    say "deploying: $(tail -2 "$LOG" | head -1)"
fi
DEPLOY_BUDGET="${DEPLOY_BUDGET:-1500}"   # s from now to ts-done; a loaded host needs more (the update pass alone can take 12+ min)
"$BIN/await" "$VM" ts-done "$DEPLOY_BUDGET" >>"$LOG" 2>&1 || { say "no ts-done in $DEPLOY_BUDGET s: not a reboot problem, giving up"; exit 2; }
say "ts-done; watching the two reboots of the installation"
await_or_hang install-1 specialize "$HANG_AFTER"
await_or_hang install-2 firstlogon 420
"$BIN/await" "$VM" deployed 900 >>"$LOG" 2>&1 || { say "no deployed in 900 s"; exit 2; }
say "deployed: $(bin_status_line=$("$BIN/status" "$VM" 2>/dev/null | grep -aE 'firstlogon' | head -1); echo "${bin_status_line:-?}")"
for _ in $(seq 1 24); do "${SSH[@]}" hostname >>"$LOG" 2>&1 && break; sleep 5; done
"${SSH[@]}" hostname >>"$LOG" 2>&1 || { say "sshd not reachable on $PORT after deployment"; exit 2; }
say "ssh up; $N reboots of the installed Windows"
fi

for (( i=1; i<=N; i++ )); do
    t0=$(date +%s)
    "${SSH[@]}" 'shutdown /r /t 0' >>"$LOG" 2>&1
    down=0
    for _ in $(seq 1 30); do "${SSH[@]}" true >>"$LOG" 2>&1 || { down=1; break; }; sleep 2; done
    (( down )) || { say "cycle $i: sshd never went away after shutdown /r; stopping"; exit 2; }
    up=0
    while (( $(date +%s) - t0 < HANG_AFTER )); do "${SSH[@]}" hostname >>"$LOG" 2>&1 && { up=1; break; }; sleep 5; done
    dt=$(( $(date +%s) - t0 ))
    if (( up )); then PASSES=$((PASSES+1)); RESULTS+=("$i=pass"); say "cycle $i: PASS, sshd back after $dt s"
    else
        HANGS=$((HANGS+1)); RESULTS+=("$i=HANG")
        say "$(record_hang "$VM" "cycle-$i" "$OUT" "no sshd within $HANG_AFTER s of shutdown /r")"
        recover "cycle-$i"
        ok=0; for _ in $(seq 1 60); do "${SSH[@]}" hostname >>"$LOG" 2>&1 && { ok=1; break; }; sleep 5; done
        (( ok )) || { say "cycle $i: no sshd after recovery either"; exit 2; }
    fi
    sleep 10
done
say "RESULT $VM: $PASSES fine, $HANGS hung, of $N_TOTAL guest-initiated reboots: ${RESULTS[*]} (boot options: ${BOOT[*]}; SKIP_DEPLOY=${SKIP_DEPLOY:-} LOAD=${LOAD:-})"
echo "$VM $PASSES $HANGS $N_TOTAL ${BOOT[*]} SKIP_DEPLOY=${SKIP_DEPLOY:-} LOAD=${LOAD:-}" >"$OUT/result.txt"
(( HANGS == 0 ))
