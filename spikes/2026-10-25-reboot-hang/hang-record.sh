# hang-record.sh - sourced by the reboot loops: record a hung lab VM from QEMU's side.
#   record_hang <vm> <label> <out-dir> <what-was-expected>
# Writes <out-dir>/hang-<label>.txt (status, registers twice, code bytes, mtimes,
# vars.fd hash), <out-dir>/hang-<label>-bsp-*.bin and -ap-*.bin (guest-physical
# memory around CPU#0's and CPU#1's RIP, 2 MB and 128 KB, when they look like
# firmware addresses) and hang-<label>.png (screendump). Needs bin/lib.sh sourced.
BIN="${BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd)}"   # the loops set it; a bare source does not

record_hang() {
    local vm="$1" label="$2" out="$3" expected="$4" f rip aprip base ab
    f="$out/hang-$label.txt"
    local vmdir="$VMS_DIR/$vm"
    m() { vm_monitor "$vm" "$@" | grep -av -e "monitor - type" -e $'\x1b\[K' | sed "s/^(qemu) //"; }
    {
        echo "$label: $expected; recorded $(date +%H:%M:%S)"
        m "info status"
        echo "-- registers"; m "info registers -a" | grep -aE '^CPU|RIP'
        sleep 2
        echo "-- 2 s later"; m "info registers -a" | grep -aE '^CPU|RIP'
        rip="$(m "info registers -a" | grep -aoE 'RIP=[0-9a-f]+' | head -1 | cut -d= -f2)"
        aprip="$(m "info registers -a" | grep -aoE 'RIP=[0-9a-f]+' | sed -n 2p | cut -d= -f2)"
        echo "-- CPU#0 code bytes at 0x$rip (this QEMU has no disassembler; objdump them on the host)"; m "x /48xb 0x$rip"
        # guest-physical memory around both RIPs, to find the firmware module by its PE header.
        # Only for identity-mapped addresses under 4 GiB: a Windows kernel address (fffff8...)
        # is the detector's own negative control, not a firmware hang. Quoted paths: HMP
        # reads an unquoted /path as a division.
        # A firmware RIP in the DXE/PEI region (0x78000000..0x7c000000 on these VMs,
        # layout/): dump the whole 64 MB, so that the GCD map, the HOB list, the PCD
        # database and the pool are all there (the 2 MB around the RIP of the first
        # version left the hung DxeCore's GCD walk unreadable, rerun 5). Elsewhere
        # under 4 GiB: 2 MB around the RIP. gzip the .bin before keeping it.
        # (PEI memory on these VMs starts at 0x77f5e000, layout/hob-list-healthy.out: the
        # PEI HOB list with the PlatformInfoHob and the PCD database sit there; 80 MB
        # from 0x77000000 covers it and DXE's copy near 0x7b8e4000.)
        if (( 0x$rip >= 0x77000000 && 0x$rip < 0x7c000000 )); then
            base=0x77000000
            m "pmemsave $base 0x5000000 \"$out/hang-$label-bsp-$(printf %x $base).bin\"" >/dev/null
        elif (( 0x$rip < 0x100000000 && 0x$rip >= 0x200000 )); then
            base=$(( (0x$rip & ~0xfffff) - 0x100000 ))
            m "pmemsave $base 0x200000 \"$out/hang-$label-bsp-$(printf %x $base).bin\"" >/dev/null
        fi
        if [[ -n "$aprip" ]] && (( 0x$aprip < 0x100000000 && 0x$aprip >= 0x10000 )); then
            ab=$(( 0x$aprip & ~0xffff )); m "pmemsave $ab 0x20000 \"$out/hang-$label-ap-$(printf %x $ab).bin\"" >/dev/null
        fi
        echo "-- memory dumps: $(ls "$out"/hang-$label-*.bin 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
        # CPU#0's stack: return addresses into firmware images give the call chain (find-module.py places them)
        local rsp; rsp="$(m "info registers -a" | grep -aoE 'RSP=[0-9a-f]+' | head -1 | cut -d= -f2)"
        echo "-- CPU#0 stack at RSP 0x$rsp (64 qwords)"; m "x /64gx 0x$rsp"
        echo "-- CPU#0 full registers"; m "info registers" | head -40
        for c in 0 1 2 3; do echo "-- info lapic $c"; m "info lapic $c" | head -30; done
        m "info mtree" >"$out/hang-$label-mtree.txt"
        echo "-- I/O map (hang-$label-mtree.txt): $(grep -aE 'ich9-pm|acpi-tmr|acpi-evt|acpi-cnt' "$out/hang-$label-mtree.txt" | tr -s ' ' | head -4 | tr '\n' ';')"
        echo "-- serial.log: $(stat -c '%y %s bytes' "$vmdir/serial.log")"
        echo "-- disk.qcow2: $(stat -c '%y' "$vmdir/disk.qcow2")"
        echo "-- vars.fd now: $(sha256sum "$vmdir/vars.fd" | cut -c1-16)"
        echo "-- qemu: $(ps -o etime=,pcpu= -p "$(cat "$vmdir/qemu.pid")")"
        # QEMU's own trace of the firmware's CPU-count inputs (bin/vm-boot with
        # QEMU_TRACE='fw_cfg_select,fw_cfg_read,cpuhp_acpi_*'): which fw_cfg items were
        # selected and what the CPU-hotplug register block answered at this reset.
        if [[ -f "$vmdir/qemu-trace.log" ]]; then
            cp "$vmdir/qemu-trace.log" "$out/hang-$label-qemu-trace.log"
            echo "-- qemu trace: hang-$label-qemu-trace.log, $(wc -l <"$vmdir/qemu-trace.log") lines; last nb_cpus select + cpuhp probe:"
            grep -anE "nb_cpus|cpuhp" "$vmdir/qemu-trace.log" | tail -30
        else
            echo "-- qemu trace: none (QEMU_TRACE was not set for this boot)"
        fi
    } >"$f" 2>&1
    "$BIN/vm-shot" "$vm" "$out/hang-$label.png" >/dev/null 2>&1
    echo "HANG $label recorded in $f; $(grep -aE '^RIP' "$f" | head -1)"
}

# wait_for_self_recovery <vm> <label> <out-dir> <seconds>: after record_hang, leave the
# VM alone and look once a minute, for up to <seconds>, for the firmware moving on by
# itself; hang-<label>-wait.txt gets one line per look. The hang captured on 10-25 is
# MpInitLib waiting MAX_UINT32 us (71.6 min) for APs that do not exist; if that is the
# whole story the VM boots on its own about 72 min after the reboot. Recovery is seen
# as serial.log changing or CPU#0 leaving the firmware (RIP above 4 GiB, Windows).
# Returns 0 when it recovered, 1 when the time ran out.
wait_for_self_recovery() {
    local vm="$1" label="$2" out="$3" secs="$4" t0 rip smtime
    local vmdir="$VMS_DIR/$vm"   # its own line: within one 'local', $vm is not yet set
    local f="$out/hang-$label-wait.txt"
    m() { vm_monitor "$vm" "$@" | grep -av -e "monitor - type" -e $'\x1b\[K' | sed "s/^(qemu) //"; }
    t0=$(date +%s); smtime="$(stat -c %Y "$vmdir/serial.log")"
    echo "$label: waiting up to $secs s for the firmware to move on by itself (started $(date +%T); serial.log $(stat -c %s "$vmdir/serial.log") bytes)" >"$f"
    while (( $(date +%s) - t0 < secs )); do
        sleep 60
        rip="$(m "info registers -a" | grep -aoE 'RIP=[0-9a-f]+' | head -1 | cut -d= -f2)"
        echo "$(date +%T) +$(( $(date +%s) - t0 ))s CPU#0 RIP=${rip:-?} serial.log $(stat -c %s "$vmdir/serial.log") bytes, disk.qcow2 $(stat -c %y "$vmdir/disk.qcow2" | cut -c12-19)" >>"$f"
        # 'info registers' prints RIP as 16 zero-padded hex digits: a firmware RIP
        # (below 4 GiB) starts with eight zeros, a Windows one (fffff8...) does not.
        # Not an arithmetic compare: bash integers are signed, 0xfffff8... is negative;
        # not a length compare either (the first version; its control used a hand-typed
        # 8-digit string, not the monitor's format, and passed while the check was wrong).
        if [[ "$(stat -c %Y "$vmdir/serial.log")" != "$smtime" ]] || { [[ -n "$rip" ]] && [[ ! "$rip" =~ ^0{8}[0-9a-f]{8}$ ]]; }; then
            echo "RECOVERED BY ITSELF after $(( $(date +%s) - t0 ))s (serial.log changed or CPU#0 left the firmware)" >>"$f"
            "$BIN/vm-shot" "$vm" "$out/hang-$label-recovered.png" >/dev/null 2>&1
            echo "HANG $label: the VM recovered by itself after $(( $(date +%s) - t0 )) s ($f)"
            return 0
        fi
    done
    echo "NOT RECOVERED after $secs s" >>"$f"
    echo "HANG $label: still hung after $secs s ($f)"
    return 1
}
