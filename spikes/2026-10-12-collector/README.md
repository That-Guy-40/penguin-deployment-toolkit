# 2026-10-12: the collector (Linux in RAM, built rootless) and the hand-over to Windows PE

Asked for: a small PXE-bootable Linux to inventory a machine headlessly
(SMBIOS, NICs, AMT, firmware settings), write its `machines/` entry, and
reboot it into Windows PE. `docs/COLLECTOR.md` is the result; this is how it
was built and what the lab showed. All VMs on this host; `beacons.txt` has
every event of VM `cl`.

## Build **[verified]**

`bin/build-collector`: mmdebstrap `--mode=unshare` (rootless; this host
allows user namespaces), Debian trixie minbase + 24 packages, inline hooks,
the tree as a tar, then `tar2initrd.py` turns the tar into `vmlinuz` + a
zstd newc cpio without extracting anything onto the host. 179 packages,
kernel 11 MiB, initramfs 134 MiB, 19 s once the packages are cached
(`collector.json`).

Found on the way:

- mklab (LAB_CREATE_V2) was surveyed first: its `chroot → export-initrd`
  recipe is what this does, but its rootless mode is a fakechroot jail its
  own docs call limited, and its root path would want sudo per rebuild.
  Recipe taken, tool not.
- This host's AppArmor profile for `mmdebstrap` (`flags=(unconfined)`,
  `userns`) denies hooks given as *files* ("Permission denied" on exec and
  even on `sh file`); hooks as inline strings run. `customize-inside.sh` is
  therefore passed as a string.
- My first cpio writer emitted the magic as an 8-digit field (newc wants the
  six characters `070701`): "no cpio magic", kernel panic
  (`first-boots-serial-excerpt.txt`). The second sized file names in
  characters; Debian ships a CA certificate named `…Főtanúsítvány.pem`:
  "malformed archive". Sized in bytes, the archive walks clean.
- Debian's `amtterm` has no `mei-amt-check`; it is vendored (Intel/Google,
  BSD/GPLv2) and built statically on the host.
- Deleting the install-time SSH host keys without regenerating them left
  `sshd -t` failing: `ssh=down` on the first good boot, honestly. A oneshot
  `ssh-keygen -A` unit before `ssh.service` fixed it; every boot gets fresh keys.

## Boot and inventory **[verified]**

VM `cl`, `vm-create cl --mode none` (unlisted), `bin/netboot cl collector`:

```
01:34:31  ipxe ok      product=lab-vm mac=52:54:00:c7:3c:f2
01:34:36  collect ok   os=linux product=lab-vm serial=cl amt=absent firmware=none pxe_entry=0003 ssh=up
```

4.5 s from the iPXE request to the inventory being on the server
(`cl-inventory.json`, `cl-inventory.txt`): product, manufacturer, serial,
the NIC's MAC, `amt=absent` (QEMU has no MEI: the negative case for the
check), `firmware=none` (no firmware-attributes driver bound: the honest
answer in a VM), the UEFI network boot entry `0003`, Secure Boot state,
memory, CPU, the disk. `bin/shell cl '…'` works unchanged against Linux
(1.2 s round trip; `bin/shell` writes a `sh` script when the machine's run
has a `collect` event). sshd listens with `permitrootlogin without-password`,
`passwordauthentication no`. Serial console: `vms/cl/serial.log`.

## Enrol and hand over **[verified]**

`bin/enroll cl --role lab-apps` wrote `machines/<uuid>.cfg` from the
inventory (`cl-machine.cfg`); a second run refused without `--force`.
`bin/netboot cl winpe && bin/shell cl 'pdt-pxe-next --reboot'` printed
`BootNext=0003: Boot0003* UEFI PXEv4 (MAC:525400C73CF2)`, the VM rebooted,
PXE → iPXE → Windows PE → the enrolled cfg → the full role deploy:

```
01:37:08  ipxe ok … 01:39:01 ts-done ok … 01:41:13 deployed ok role=lab-apps
01:41:13  deploy-remove ok account=deleted … 01:41:44 deploy-removed ok
```

245 s from the collector's reboot to `deployed`. (The disk was empty for
that boot, so it proves the flow, not `BootNext`; see below.)

## BootNext, the real test **[verified]** (`bootnext-ab.txt`)

With Windows now on the disk and the firmware's order disk-first:

| step | result |
|---|---|
| `vm-stop cl` (ACPI; the role has fast startup off), `vm-boot cl --pxe` | collector (override still `collector`), `collect ok` |
| `bin/shell cl 'pdt-pxe-next'` (no reboot) | `BootNext=0003 …`; `efibootmgr`: `BootNext: 0003`, `BootOrder: 0003,…` |
| `vm-stop cl` (clean Linux shutdown), `vm-boot cl` with the **disk first** | **`collect ok`** again: the firmware took BootNext over its order; inside, `BootCurrent: 0003`, no `BootNext` line (consumed), `BootOrder: 0002,0003,…` (disk first, as QEMU asked) |
| control: `vm-stop cl`, `vm-boot cl` disk first, nothing set | Windows: `boot ok trigger=onstart` from the installed system, no `collect` within 150 s |

`pdt-pxe-next --reboot` now delays the reboot 3 s so the shell loop can
upload its output (the first hand-over's `bin/shell` timed out for that
reason, while the machine was already rebooting).

## Not verified

A real SSH session (the user-mode VM is not reachable from the host; the
bridged lab would show it), AMT on real hardware, firmware attributes on a
Dell (`firmware=none` in QEMU is the correct answer, not evidence either way).
