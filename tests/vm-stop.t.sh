#!/bin/bash
# vm-stop: ACPI first, --force by pid, the exclusions.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox
B="$T/bin"
"$B/vm-create" lab1 --mode none >/dev/null 2>&1

out="$("$B/vm-stop" lab1 2>&1)"; rc=$?
chk_rc "stopping a VM that is not running exits 0" 0 "$rc" "$out"
chk_grep "and says so" "is not running" "$out"

"$B/vm-boot" lab1 >/dev/null 2>&1
pid="$(cat "$T/vms/lab1/qemu.pid")"
out="$("$B/vm-stop" lab1 --force 2>&1)"; rc=$?
chk_rc "--force exits 0" 0 "$rc" "$out"
kill -0 "$pid" 2>/dev/null && fail "--force ends the QEMU process" "pid $pid alive" || pass "--force ends the QEMU process"
[[ ! -f "$T/vms/lab1/qemu.pid" ]] && pass "--force removes the pidfile" || fail "pidfile" "remains"
grep -q system_powerdown "$FAKE_MONITOR_LOG" 2>/dev/null && fail "--force sends no ACPI button" "system_powerdown in the monitor log" || pass "--force sends no ACPI button"

# ACPI honoured by the guest (the fake monitor ends QEMU on system_powerdown)
: > "$FAKE_MONITOR_LOG"
"$B/vm-boot" lab1 >/dev/null 2>&1
pid="$(cat "$T/vms/lab1/qemu.pid")"
t0=$(date +%s); out="$(FAKE_ACPI_HONOURED=1 "$B/vm-stop" lab1 2>&1)"; rc=$?; dt=$(( $(date +%s) - t0 ))
chk_rc "ACPI stop exits 0 when the guest powers down" 0 "$rc" "$out"
chk "the ACPI button was pressed once (system_powerdown)" "1" "$(grep -c system_powerdown "$FAKE_MONITOR_LOG")"
(( dt < 10 )) && pass "and returned as soon as QEMU was gone ($dt s, not the 60 s limit)" || fail "ACPI stop timing" "$dt s"
kill -0 "$pid" 2>/dev/null && fail "QEMU gone after the honoured ACPI stop" "alive" || pass "QEMU gone after the honoured ACPI stop"

refuses "--full and --force together" "exclude each other" -- "$B/vm-stop" lab1 --full --force
refuses "no name" "usage: vm-stop" -- "$B/vm-stop"
refuses "unknown VM" "no such VM" -- "$B/vm-stop" ghost
unknown "the 60 s ACPI-ignored path (guest keeps running, then kill)" "not exercised: it takes 60 s by design"
finish
