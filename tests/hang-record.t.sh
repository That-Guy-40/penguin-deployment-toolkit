#!/bin/bash
# hang-record.sh and smoke-hang-hook.sh from spikes/2026-10-25-reboot-hang, run against
# a fake monitor: what gets recorded, when the big dump is taken, the self-recovery
# verdicts, and the hook's "wait only for CpuMpPei" gate.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox
SPIKE="$REPO/spikes/2026-10-25-reboot-hang"
mkdir -p "$T/spikes/x" "$T/out" "$T/nosleep"
cp "$SPIKE/hang-record.sh" "$SPIKE/smoke-hang-hook.sh" "$T/spikes/x/"
cp "$T/fakebin/vm-shot-fake" "$T/bin/vm-shot"
printf '#!/bin/bash\nexit 0\n' > "$T/nosleep/sleep"; chmod +x "$T/nosleep/sleep"   # a sleep that does not
"$T/bin/vm-create" t --mode none >/dev/null 2>&1
VMDIR="$T/vms/t"; echo "serial" > "$VMDIR/serial.log"
# the fake monitor's answer to everything: registers with CPU#0 at $1 and CPU#1 parked
reply() { printf '(qemu) info status\nVM status: running\nCPU#0\nRIP=%s RFL=00000002 [-------] CPL=0 II=0 A20=1 SMM=0 HLT=0\nCPU#1\nRIP=%s RFL=00000002 [-------] CPL=0 II=0 A20=1 SMM=0 HLT=1\n' "$1" "${2:-000000007ad65d71}" > "$FAKE_MONITOR_REPLY"; }

# --- record_hang, sourced in a subshell with the sandbox's lib.sh
rec() {  # rec <rip> <label>: run record_hang, return its stdout
    ( cd "$T" && source bin/lib.sh && set +e && BIN="$T/bin" && source spikes/x/hang-record.sh && record_hang t "$2" "$T/out" "test: expected a beacon" )
}
reply 000000007bf7c483; : > "$FAKE_MONITOR_LOG"
out="$(rec 000000007bf7c483 dxe 2>&1)"
chk_grep "record_hang announces the record and the RIP" "HANG dxe recorded in $T/out/hang-dxe.txt; RIP=000000007bf7c483" "$out"
f="$T/out/hang-dxe.txt"
chk_grep "the record holds the registers twice" "-- 2 s later" "$(cat "$f")"
chk "the registers were asked for three times (two looks + the RIP extraction... at least 3)" "yes" "$([[ $(grep -c 'info registers -a' "$FAKE_MONITOR_LOG") -ge 3 ]] && echo yes || echo no)"
chk_grep "a RIP in the PEI/DXE region takes the 80 MB dump from 0x77000000" "pmemsave 0x77000000 0x5000000 " "$(cat "$FAKE_MONITOR_LOG")"
chk_grep "the record says there was no QEMU trace for this boot" "qemu trace: none" "$(cat "$f")"
[[ -f "$T/out/hang-dxe.png" ]] && pass "a screendump is taken (vm-shot)" || fail "screendump" "missing"
# a Windows RIP (the detector's own negative control): no firmware dump at all
reply fffff800bd0563bf fffff800bd0563bf; : > "$FAKE_MONITOR_LOG"
rec fffff800bd0563bf win >/dev/null 2>&1
grep -q pmemsave "$FAKE_MONITOR_LOG" && fail "a Windows RIP: no memory dump" "pmemsave issued" || control "a Windows RIP (fffff8...) is recorded without any pmemsave: not a firmware hang"
# a firmware RIP below the PEI/DXE region: the small dump around it, not the big one
reply 0000000000e01234 0000000000e01234; : > "$FAKE_MONITOR_LOG"
rec 0000000000e01234 low >/dev/null 2>&1
grep -q 'pmemsave 0x77000000' "$FAKE_MONITOR_LOG" && fail "RIP outside 0x77000000..0x7c000000: no 80 MB dump" "big dump issued" || pass "RIP outside 0x77000000..0x7c000000: no 80 MB dump"
grep -qE "pmemsave $((0xd00000)) 0x200000 " "$FAKE_MONITOR_LOG" && pass "but the 2 MB dump from 1 MB below the RIP's megabyte (0xd00000)" || fail "2 MB dump" "$(grep pmemsave "$FAKE_MONITOR_LOG")"
grep -qE "pmemsave $((0xe00000)) 0x20000 " "$FAKE_MONITOR_LOG" && pass "and 128 KB around CPU#1's RIP" || fail "AP dump" "$(grep pmemsave "$FAKE_MONITOR_LOG")"
reply 00000000000f1234 00000000000f1234; : > "$FAKE_MONITOR_LOG"
rec 00000000000f1234 verylow >/dev/null 2>&1
grep -qE 'bsp-' "$FAKE_MONITOR_LOG" && fail "a RIP under 2 MB: no BSP dump (nothing below 0 to dump from)" "$(grep bsp- "$FAKE_MONITOR_LOG")" || control "a RIP under 2 MB (f1234): no BSP dump is attempted"
# with a trace file: copied and quoted
echo "fw_cfg_select ... key 0x0019 'file_dir'" > "$VMDIR/qemu-trace.log"
reply 000000007bf7c483; rec 000000007bf7c483 traced >/dev/null 2>&1
[[ -f "$T/out/hang-traced-qemu-trace.log" ]] && pass "the VM's qemu-trace.log is copied next to the record" || fail "trace copy" "missing"
chk_grep "and the record names it" "qemu trace: hang-traced-qemu-trace.log, 1 lines" "$(cat "$T/out/hang-traced.txt")"
rm -f "$VMDIR/qemu-trace.log"

# --- wait_for_self_recovery (sleep stubbed out: the function's 60 s looks become instant)
wait_for() {  # wait_for <label> <secs>
    ( cd "$T" && source bin/lib.sh && set +e && BIN="$T/bin" && source spikes/x/hang-record.sh && sleep() { :; } && wait_for_self_recovery t "$1" "$T/out" "$2" )
}
reply 000000007bf7c483
out="$(wait_for w1 2)"; rc=$?
chk_rc "firmware RIP, serial.log unchanged: NOT RECOVERED, rc 1" 1 "$rc" "$out"
chk_grep "the wait file ends with NOT RECOVERED" "NOT RECOVERED after 2 s" "$(tail -1 "$T/out/hang-w1-wait.txt")"
reply fffff800bd0563bf
out="$(wait_for w2 5)"; rc=$?
chk_rc "a Windows RIP (16 digits, not eight zeros first): RECOVERED, rc 0" 0 "$rc" "$out"
chk_grep "the wait file says so" "RECOVERED BY ITSELF" "$(cat "$T/out/hang-w2-wait.txt")"
reply 000000007bf7c483
( sleep 1; echo more >> "$VMDIR/serial.log" ) &
out="$(wait_for w3 5)"; rc=$?; wait
chk_rc "firmware RIP but serial.log changes: RECOVERED" 0 "$rc" "$out"
reply 00000000ffffffff
out="$(wait_for w4 2)"; rc=$?
if (( rc == 1 )); then control "RIP 00000000ffffffff (firmware, top of 4 GiB) is NOT a recovery: the regex is on the digits, not a signed compare"; else fail "regex control" "rc $rc"; fi

# --- the hook: records, then waits only when the RIP is inside CpuMpPei
hook() {  # hook <rip> <label> [env...]: run smoke-hang-hook.sh with a no-op sleep on PATH
    reply "$1"; ( cd "$T" && PATH="$T/nosleep:$PATH" env "${@:3}" bash spikes/x/smoke-hang-hook.sh t "$2" "$T/out" )
}
out="$(hook 000000007bfe35d3 pei SMOKE_HANG_WAIT=2 2>&1)"
chk_grep "PEI RIP (7bfe35d3, in CpuMpPei): the hook records and then waits" "waiting up to 2 s" "$(cat "$T/out/hang-pei-wait.txt")"
chk_grep "and reports the wait's verdict" "HANG pei: still hung after 2 s" "$out"
out="$(hook 000000007bf7c483 dxe2 SMOKE_HANG_WAIT=2 2>&1)"
chk_grep "DXE RIP (7bf7c483, DxeCore): the hook does not wait" "HANG dxe2: DXE variant \(RIP=000000007bf7c483\), not waiting" "$out"
chk_grep "and leaves an UNKNOWN wait file" "UNKNOWN whether it would ever move on, not waited for" "$(cat "$T/out/hang-dxe2-wait.txt")"
out="$(hook 000000007bfe35d3 nowait 2>&1)"
[[ -f "$T/out/hang-nowait-wait.txt" ]] && fail "without SMOKE_HANG_WAIT no wait file at all" "exists" || control "without SMOKE_HANG_WAIT the hook only records (no wait file, not even for a PEI RIP)"
out="$(hook 000000007bf7c483 custom SMOKE_HANG_WAIT=2 'SMOKE_HANG_WAIT_RIP=^0*7bf7c' 2>&1)"
chk_grep "SMOKE_HANG_WAIT_RIP overrides the range (another firmware layout)" "waiting up to 2 s" "$(cat "$T/out/hang-custom-wait.txt")"
finish
