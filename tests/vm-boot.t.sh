#!/bin/bash
# vm-boot: what QEMU is asked for, from the options, the environment and vm.conf.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox
B="$T/bin"
"$B/vm-create" lab1 --mode none >/dev/null 2>&1 || { fail "setup: vm-create" ""; finish; }
"$B/vm-create" vio --mode none --nic virtio-net-pci --disk virtio --second-disk 1G --usb-disk 1G --sd-card 1G >/dev/null 2>&1
stop() { "$B/vm-stop" "$1" --force >/dev/null 2>&1; }

# --- defaults
out="$("$B/vm-boot" lab1 2>&1)"; rc=$?
chk_rc "vm-boot lab1 exits 0 with the fake QEMU" 0 "$rc" "$out"
argv_pair -drive "^if=pflash,format=raw,unit=0,readonly=on,file=$T/fw/CODE.fd$" && pass "pflash unit 0 is config.sh's OVMF_CODE" || fail "pflash unit 0" "$(grep pflash "$FAKE_QEMU_ARGV")"
argv_pair -machine '^q35,smm=on$' && pass "default machine q35,smm=on" || fail "machine" "$(grep -A1 -- '^-machine$' "$FAKE_QEMU_ARGV" | tail -1)"
argv_pair -global '^driver=cfi.pflash01,property=secure,value=on$' && pass "secure pflash with SMM on" || fail "secure pflash" "absent"
argv_pair -smp '^2$' && pass "-smp from vm.conf (VM_CPUS=2)" || fail "-smp" "$(grep -A1 -- '^-smp$' "$FAKE_QEMU_ARGV" | tail -1)"
argv_pair -device '^ide-hd,drive=hd0,bus=ide.0,bootindex=1$' && pass "AHCI disk first in boot order" || fail "disk bootindex" "$(grep bootindex "$FAKE_QEMU_ARGV")"
argv_pair -device "^e1000e,netdev=net0,mac=.*,romfile=$T/roms/efi-e1000e.rom,bootindex=3$" && pass "e1000e NIC with its iPXE ROM, after the disks" || fail "nic device" "$(grep netdev=net0 "$FAKE_QEMU_ARGV")"
argv_pair -netdev "^user,id=net0,tftp=$T/pxe,bootfile=ipxe.efi$" && pass "user network serving pxe/ipxe.efi over TFTP" || fail "netdev" "$(grep -A1 -- '^-netdev$' "$FAKE_QEMU_ARGV" | tail -1)"
chk "no -trace without QEMU_TRACE" "0" "$(argv_count -trace)"
argv_has -daemonize && argv_has -display && pass "headless: -display none -daemonize" || fail "headless" "missing"
chk_grep "status line names the firmware by basename and smm=on" "firmware CODE.fd smm=on, boot disk then network" "$out"
chk_grep "status line gives the id for status/await" "id for bin/status and bin/await: [0-9a-f-]{36}" "$out"
[[ -f "$T/vms/lab1/qemu.pid" ]] && kill -0 "$(cat "$T/vms/lab1/qemu.pid")" 2>/dev/null && pass "pidfile written and the process is alive" || fail "pidfile" "missing or dead"
refuses "booting a running VM is refused" "already running" -- "$B/vm-boot" lab1
stop lab1
[[ ! -f "$T/vms/lab1/qemu.pid" ]] && pass "vm-stop --force removes the pidfile" || fail "vm-stop --force" "pidfile remains"

# --- vars.fd reset rule: empty disk -> template copied; installed disk -> kept
echo "GUEST-WROTE-THIS" > "$T/vms/lab1/vars.fd"
"$B/vm-boot" lab1 >/dev/null 2>&1; stop lab1
[[ ! -s "$T/vms/lab1/vars.fd" ]] && pass "vars.fd reset from the template while the disk is empty" || fail "vars reset" "vars.fd kept its content"
echo "GUEST-WROTE-THIS" > "$T/vms/lab1/vars.fd"; truncate -s 200M "$T/vms/lab1/disk.qcow2"
"$B/vm-boot" lab1 >/dev/null 2>&1; stop lab1
chk "vars.fd kept once the disk has data (actual-size >= 100 MB)" "GUEST-WROTE-THIS" "$(cat "$T/vms/lab1/vars.fd")"
"$B/vm-boot" lab1 --pxe >/dev/null 2>&1; stop lab1
[[ ! -s "$T/vms/lab1/vars.fd" ]] && pass "--pxe resets vars.fd even with data on the disk" || fail "--pxe vars reset" "kept"
argv_pair -device '^ide-hd,drive=hd0,bus=ide.0,bootindex=2$' && argv_pair -device '^e1000e,.*bootindex=1$' && pass "--pxe: network first, disk second" || fail "--pxe order" "$(grep bootindex "$FAKE_QEMU_ARGV")"
: > "$T/vms/lab1/disk.qcow2"

# --- firmware selection: option, environment, --smm off
"$B/vm-boot" lab1 --firmware "$T/fw/OTHER.fd" >/dev/null 2>&1; stop lab1
argv_pair -drive "^if=pflash,format=raw,unit=0,readonly=on,file=$T/fw/OTHER.fd$" && pass "--firmware <file> is pflash unit 0" || fail "--firmware" "$(grep pflash "$FAKE_QEMU_ARGV")"
out="$(VM_BOOT_FIRMWARE="$T/fw/OTHER.fd" "$B/vm-boot" lab1 2>&1)"; stop lab1
argv_pair -drive "^if=pflash,format=raw,unit=0,readonly=on,file=$T/fw/OTHER.fd$" && pass "VM_BOOT_FIRMWARE (environment) is pflash unit 0" || fail "VM_BOOT_FIRMWARE" "$(grep pflash "$FAKE_QEMU_ARGV")"
chk_grep "with another firmware the status line prints the full path" "firmware $T/fw/OTHER.fd smm=on" "$out"
VM_BOOT_FIRMWARE="$T/fw/OTHER.fd" "$B/vm-boot" lab1 --firmware "$T/fw/CODE.fd" >/dev/null 2>&1; stop lab1
argv_pair -drive "^if=pflash,format=raw,unit=0,readonly=on,file=$T/fw/CODE.fd$" && pass "--firmware on the command line beats VM_BOOT_FIRMWARE" || fail "option vs env" "$(grep pflash "$FAKE_QEMU_ARGV")"
refuses "a missing firmware file is refused before QEMU runs" "OVMF firmware not found" -- "$B/vm-boot" lab1 --firmware "$T/fw/nope.fd"
"$B/vm-boot" lab1 --smm off >/dev/null 2>&1; stop lab1
argv_pair -machine '^q35,smm=off$' && pass "--smm off: machine q35,smm=off" || fail "--smm off machine" "$(grep -A1 -- '^-machine$' "$FAKE_QEMU_ARGV" | tail -1)"
argv_pair -drive "^if=pflash,format=raw,unit=0,readonly=on,file=$T/fw/CODE_NOSMM.fd$" && pass "--smm off: the non-SMM code image" || fail "--smm off code" "$(grep pflash "$FAKE_QEMU_ARGV")"
argv_pair -global '^driver=cfi.pflash01,property=secure,value=on$' && fail "--smm off: no secure pflash" "present" || pass "--smm off: no secure pflash"
refuses "--smm wants on or off" "wants on or off" -- "$B/vm-boot" lab1 --smm maybe

# --- QEMU_TRACE
QEMU_TRACE='fw_cfg_select,cpuhp_acpi_*' "$B/vm-boot" lab1 >/dev/null 2>&1; stop lab1
chk "QEMU_TRACE with two patterns: three -trace arguments (two enable=, one file=)" "3" "$(argv_count -trace)"
argv_pair -trace '^enable=fw_cfg_select$' && argv_pair -trace '^enable=cpuhp_acpi_[*]$' && pass "each pattern becomes -trace enable=<pattern>" || fail "trace enable" "$(grep enable= "$FAKE_QEMU_ARGV")"
argv_pair -trace "^file=$T/vms/lab1/qemu-trace.log$" && pass "trace output goes to vms/<vm>/qemu-trace.log" || fail "trace file" "$(grep file= "$FAKE_QEMU_ARGV" | grep trace)"

# --- --fwd, --nic, --no-rom, --gui refusal of bad input
"$B/vm-boot" lab1 --fwd 2222:22,3390:3389 >/dev/null 2>&1; stop lab1
argv_pair -netdev 'hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:3390-:3389$' && pass "--fwd a:b,c:d adds two hostfwd rules" || fail "--fwd" "$(grep -A1 -- '^-netdev$' "$FAKE_QEMU_ARGV" | tail -1)"
refuses "--fwd without host:guest is refused" "wants <host-port>:<guest-port>" -- "$B/vm-boot" lab1 --fwd 2222
"$B/vm-boot" lab1 --nic virtio-net-pci >/dev/null 2>&1; stop lab1
argv_pair -device "^virtio-net-pci,netdev=net0,.*romfile=$T/roms/efi-virtio.rom,.*$" && pass "--nic virtio-net-pci picks the virtio ROM" || fail "--nic virtio" "$(grep netdev=net0 "$FAKE_QEMU_ARGV")"
refuses "--nic outside the two models" "unsupported --nic" -- "$B/vm-boot" lab1 --nic rtl8139
"$B/vm-boot" lab1 --no-rom --nic virtio-net-pci >/dev/null 2>&1; stop lab1
argv_pair -device '^virtio-net-pci,netdev=net0,.*romfile=,bootindex=3$' && pass "--no-rom: romfile= empty (firmware's own PXE stack)" || fail "--no-rom" "$(grep netdev=net0 "$FAKE_QEMU_ARGV")"
refuses "an unknown option" "unknown option" -- "$B/vm-boot" lab1 --turbo
refuses "a VM that does not exist" "no such VM" -- "$B/vm-boot" ghost
refuses "no VM name" "usage: vm-boot" -- "$B/vm-boot"

# --- extra disks and virtio disk from vm.conf
"$B/vm-boot" vio >/dev/null 2>&1; stop vio
argv_pair -device '^virtio-blk-pci,drive=hd0,bootindex=1$' && pass "VM_DISK=virtio: virtio-blk-pci boot disk" || fail "virtio disk" "$(grep hd0 "$FAKE_QEMU_ARGV")"
argv_pair -device '^ide-hd,drive=hd1,bus=ide.1,bootindex=2$' && pass "disk2.qcow2: second AHCI disk right after the first" || fail "disk2" "$(grep hd1 "$FAKE_QEMU_ARGV")"
argv_pair -device '^usb-storage,bus=xhci.0,drive=usb0,removable=on$' && pass "usb.qcow2: removable USB stick on xhci" || fail "usb" "$(grep usb "$FAKE_QEMU_ARGV")"
argv_pair -device '^sd-card,drive=sd0$' && argv_pair -device '^sdhci-pci,id=sdhci0$' && pass "sd.qcow2: SD card behind an SDHCI controller" || fail "sd" "$(grep sd "$FAKE_QEMU_ARGV")"
argv_pair -device '^virtio-net-pci,.*bootindex=3$' && pass "with a second disk the network is still last (bootindex 3)" || fail "net last" "$(grep bootindex "$FAKE_QEMU_ARGV")"

# --- QEMU failing to start is reported, not hidden
out="$(FAKE_QEMU_FAIL=1 "$B/vm-boot" lab1 2>&1)"; rc=$?
if (( rc != 0 )) && grep -q "QEMU failed to start" <<<"$out"; then control "a QEMU that exits non-zero: vm-boot fails with 'QEMU failed to start'"; else fail "QEMU failure surfaced" "rc $rc: $out"; fi
[[ ! -f "$T/vms/lab1/qemu.pid" ]] && pass "no pidfile left after a failed start" || fail "pidfile after failure" "present"
finish
