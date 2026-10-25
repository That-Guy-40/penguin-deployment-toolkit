# hang-record.sh - sourced by the reboot loops: record a hung lab VM from QEMU's side.
#   record_hang <vm> <label> <out-dir> <what-was-expected>
# Writes <out-dir>/hang-<label>.txt (status, registers twice, code bytes, mtimes,
# vars.fd hash), <out-dir>/hang-<label>-bsp-*.bin and -ap-*.bin (guest-physical
# memory around CPU#0's and CPU#1's RIP, 2 MB and 128 KB, when they look like
# firmware addresses) and hang-<label>.png (screendump). Needs bin/lib.sh sourced.
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
        if (( 0x$rip < 0x100000000 && 0x$rip >= 0x200000 )); then
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
    } >"$f" 2>&1
    "$BIN/vm-shot" "$vm" "$out/hang-$label.png" >/dev/null 2>&1
    echo "HANG $label recorded in $f; $(grep -aE '^RIP' "$f" | head -1)"
}
