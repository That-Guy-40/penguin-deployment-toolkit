# The collector: a Linux that PXE-boots into RAM and tells you what the machine is

For machines you cannot sit at, and for every machine before its first
Windows deploy: boot it into a small Debian that runs entirely from RAM,
inventories it, uploads the inventory, takes commands (`bin/shell`) and
SSH, and, when told, points the firmware's next boot at the network and
reboots into Windows PE. It never writes to a disk.

```
bin/build-collector                      # once: http/collector/{vmlinuz,initrd.img} (rootless, mmdebstrap)
bin/netboot default collector            # every unlisted machine boots the collector (or: bin/netboot <m> collector)
# ... the machine PXE-boots ...
bin/status                               # collect ok  product=… serial=… amt=… firmware=… pxe_entry=… ssh=up
bin/logs <m> --cat inventory.txt         # everything it saw (efibootmgr -v, lspci, lsblk, firmware attributes, dmidecode)
bin/shell <m> 'cat /sys/class/firmware-attributes/*/attributes/*/current_value'
bin/enroll <m> --role lab-apps           # machines/<uuid>.cfg from the inventory
bin/netboot <m> winpe                    # (or leave "default collector" and override this one)
bin/shell <m> 'pdt-pxe-next --reboot'    # BootNext = the UEFI network entry, reboot -> iPXE -> Windows PE
bin/await <m> deployed 900
```

## What it is

| | |
|---|---|
| base | Debian (`trixie`), `minbase` + systemd, udev, networkd (DHCP on every Ethernet port), resolved, sshd |
| tools | `dmidecode`, `efibootmgr`, `mokutil`, `amtterm` + `mei-amt-check`, `pciutils`, `usbutils`, `ethtool`, `nvme-cli`, `curl`, `jq` |
| kernel | Debian's `linux-image-amd64` with all its modules, so unknown NICs and disks work; `dell-wmi-sysman`, `think-lmi`, `hp-bioscfg` expose firmware settings as files under `/sys/class/firmware-attributes/` |
| form | the whole root filesystem is the initramfs (zstd cpio); the kernel unpacks it into RAM and runs systemd as `/init`. No disk is touched |
| identity | `boot.ipxe` passes `pdt.server=` (its own base URL) and `pdt.id=` (the UUID iPXE saw) on the kernel command line; the collector reports with that id, so its events join the machine's timeline |
| access | root over SSH by key only (the first `~/.ssh/*.pub` on the server at build time, or `--ssh-key`); no password; fresh host keys every boot; a getty on `ttyS0` for machines with a serial port. Verified from this host against a lab VM (`bin/vm-boot --fwd 2222:22`, `spikes/2026-10-12-ssh-rdp/`): the key logs in, password methods and a wrong key are refused |
| trust | the same as everything else here: whoever writes to `http/` runs code on booting machines. The collector adds sshd as a listening service, with your key; `bin/shell` adds no port |

## Firmware settings from Linux, without a screen

On a Dell with the `dell-wmi-sysman` driver (most Latitudes/OptiPlex/Precision
from about 2018; earlier ones are **[unknown]** until tried) every setup
option is a file: `…/attributes/UefiNwStack/current_value`, `…/EmbNic1/…`
and so on, readable, and writable by `echo`; a BIOS admin password goes in
`…/authentication/Admin/current_password` first. `inventory.txt` lists every
attribute with its possible values. So "enable PXE" is
`bin/shell <m> 'echo Enabled > /sys/class/firmware-attributes/dell-wmi-sysman/attributes/UefiNwStack/current_value'`.
Where the driver does not bind, Dell's own `cctk` (Dell Command | Configure
for Linux, a package from Dell) is the fallback, not included here.

## Where it fits

`boot.ipxe` decides what a machine boots: `boot/<uuid>.ipxe` for this
machine, else `boot/default.ipxe`, else Windows PE. Both snippets are one
line (`set pdt_boot collector`) written by `bin/netboot`. The collector is a
sensible default for unlisted machines: an unknown machine then boots
something that cannot wipe it, says what it is, and waits for orders;
Windows PE's `MODE=shell` prompt did the same but with less to say and no
SSH.

The laptop with the damaged screen is the case this was written for, with
one caveat: a machine whose firmware has PXE off cannot boot the collector
either, so the first setting change on such a machine comes from whatever
OS it has (SSH into its Kali), or from a display borrowed once. After that,
the collector is how it is driven.

## Building

`bin/build-collector` needs `mmdebstrap`, `zstd`, `cpio`, `gcc` and working
unprivileged user namespaces (the same ones `bin/lab-netns` uses); no sudo.
It takes a few minutes and ~150 MB of downloads. The recipe is
LAB_CREATE_V2's "chroot → export-initrd" one (debootstrap, systemd as
`/init`, cpio of the tree) and its metal-as-a-service probe's "gather facts,
POST" pattern, built here with mmdebstrap instead of that toolkit's
fakechroot-based rootless mode. `http/collector/collector.json` records
sizes, hashes and the package list.
