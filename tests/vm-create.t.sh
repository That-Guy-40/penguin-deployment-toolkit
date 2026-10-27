#!/bin/bash
# vm-create: identity, vm.conf, the machines/ entry, the refusals.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox
B="$T/bin"

out="$("$B/vm-create" lab1 --role demo 2>&1)"; rc=$?
chk_rc "vm-create lab1 --role demo exits 0" 0 "$rc" "$out"
conf="$T/vms/lab1/vm.conf"
[[ -f "$conf" ]] && pass "vm.conf written" || fail "vm.conf written" "missing"
uuid="$(sed -nE 's/^VM_UUID=//p' "$conf")"
chk_grep "VM_UUID is a lowercase UUID" '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' "$uuid"
chk_grep "VM_MAC is a QEMU-range unicast MAC" '^VM_MAC=52:54:00:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$' "$(grep VM_MAC "$conf")"
port="$(sed -nE 's/^VM_MONITOR_PORT=//p' "$conf")"
(( port >= 7001 )) && pass "monitor port from 7001 up ($port)" || fail "monitor port" "$port"
ss -tln | grep -q ":$port " && fail "monitor port is free on the host" "$port is listened on" || pass "monitor port is free on the host"
chk "defaults from config.sh: VM_CPUS" "VM_CPUS=2" "$(grep ^VM_CPUS= "$conf")"
chk "defaults: NIC e1000e, disk ahci, net user" "e1000e ahci user" "$(sed -nE 's/^VM_(NIC|DISK|NET)=//p' "$conf" | tr '\n' ' ' | sed 's/ $//')"
chk "VM_VARS_TEMPLATE is config.sh's" "VM_VARS_TEMPLATE=$T/fw/VARS.fd" "$(grep ^VM_VARS_TEMPLATE= "$conf")"
[[ -f "$T/vms/lab1/disk.qcow2" && -f "$T/vms/lab1/vars.fd" ]] && pass "disk.qcow2 and vars.fd created" || fail "disk and vars" "missing"
cfg="$T/http/machines/$uuid.cfg"
[[ -f "$cfg" ]] && pass "machines/<uuid>.cfg written for --mode deploy" || fail "machines cfg" "missing"
chk "cfg says MODE=deploy IMAGE=base.wim ROLE=demo" "MODE=deploy IMAGE=base.wim UNATTEND=default.xml ROLE=demo" "$(grep -vE '^#' "$cfg" | tr '\n' ' ' | sed 's/ $//')"

# a second VM gets its own identity and port
"$B/vm-create" lab2 --mode shell --image custom.wim --drivers virtio-w11 --nic virtio-net-pci --disk virtio --reference >/dev/null 2>&1
conf2="$T/vms/lab2/vm.conf"; uuid2="$(sed -nE 's/^VM_UUID=//p' "$conf2")"
[[ "$uuid2" != "$uuid" ]] && pass "second VM: a different UUID" || fail "second VM UUID" "same as the first"
[[ "$(sed -nE 's/^VM_MONITOR_PORT=//p' "$conf2")" != "$port" ]] && pass "second VM: a different monitor port" || fail "second VM port" "same as the first"
chk "--image custom.wim is stored as IMAGE=custom.wim (the .wim stripped and re-added once)" "IMAGE=custom.wim" "$(grep ^IMAGE= "$T/http/machines/$uuid2.cfg")"
chk "--mode shell, --drivers, --reference land in the cfg" "MODE=shell DRIVERS=virtio-w11 REFERENCE=yes" "$(grep -E '^(MODE|DRIVERS|REFERENCE)=' "$T/http/machines/$uuid2.cfg" | tr '\n' ' ' | sed 's/ $//')"
chk "--nic/--disk land in vm.conf" "virtio-net-pci virtio" "$(sed -nE 's/^VM_(NIC|DISK)=//p' "$conf2" | tr '\n' ' ' | sed 's/ $//')"

# --mode none: no machines entry at all
n_before="$(ls "$T/http/machines" | wc -l)"
"$B/vm-create" lab3 --mode none --second-disk 2G --usb-disk 1G --sd-card 1G >/dev/null 2>&1
chk "--mode none writes no machines/ entry" "$n_before" "$(ls "$T/http/machines" | wc -l)"
[[ -f "$T/vms/lab3/disk2.qcow2" && -f "$T/vms/lab3/usb.qcow2" && -f "$T/vms/lab3/sd.qcow2" ]] && pass "--second-disk/--usb-disk/--sd-card create disk2/usb/sd.qcow2" || fail "extra disks" "$(ls "$T/vms/lab3")"

# refusals (controls)
refuses "a name with a slash is refused" "name: letters, digits" -- "$B/vm-create" "bad/name"
refuses "an existing VM is not overwritten" "already exists" -- "$B/vm-create" lab1
refuses "--mode other than deploy/shell/none" "must be deploy, shell or none" -- "$B/vm-create" lab9 --mode wipe
refuses "a role without role.cfg" "no such role" -- "$B/vm-create" lab9 --role nonexistent
refuses "--nic outside e1000e/virtio-net-pci" "must be e1000e or virtio-net-pci" -- "$B/vm-create" lab9 --nic rtl8139
refuses "--disk outside ahci/virtio" "must be ahci or virtio" -- "$B/vm-create" lab9 --disk nvme
refuses "--net outside user/bridge:<br>" "must be 'user' or 'bridge" -- "$B/vm-create" lab9 --net tap0
refuses "a missing vars template" "vars template not found" -- "$B/vm-create" lab9 --vars "$T/fw/nope.fd"
refuses "an unknown option" "unknown option" -- "$B/vm-create" lab9 --colour blue
[[ ! -e "$T/vms/lab9" ]] && pass "a refused create leaves no vms/ directory behind" || fail "refused create" "vms/lab9 exists"
finish
