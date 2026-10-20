# 2026-10-20: what libguestfs and hivex (RWMJ's tools) can do for this toolkit

Asked: Richard W.M. Jones' libguestfs did notable offline Windows work
(`virt-win-reg`, `hivex`, `virt-v2v`'s driver injection, `virt-customize
--firstboot` through rhsrvany, `virt-inspector`). What of it fits here?
Probed on this host (Ubuntu 26.04, libguestfs 1.58, hivex 1.3.24).

## Two different things

- **hivex**: a library and CLI (`hivexregedit`, Perl `Win::Hivex`) that reads
  and writes Windows registry hive *files* directly. No VM, no appliance, no
  root. Our images are WIMs and `wimlib` can pull any file out of them, so
  every registry hive of an image, the Default profile's `NTUSER.DAT`, and
  the **BCD** (which is a hive) are editable on Linux today.
- **libguestfs proper** (`guestfish`, `guestmount`, `virt-inspector`,
  `virt-customize`): mounts disk *images* through a small appliance VM. Our
  only disk images are the lab VMs' qcow2 files (`bin/capture-image` already
  reads them with `qemu-img` + wimlib); for WIMs it adds nothing wimlib does
  not do. The appliance needs a readable kernel; Ubuntu ships `/boot/vmlinuz-*`
  as `0600 root` (checked), so rootless use needs
  `sudo dpkg-statoverride --update --add root root 0644 /boot/vmlinuz-<ver>`
  once, or `libguestfs-test-tool` says so. Result of that test: see the end.

## Verified today, with hivex, no root **[verified]**

| what | result |
|---|---|
| `wimlib-imagex extract base.wim 1 /Windows/System32/config/{SYSTEM,SOFTWARE} /Users/Default/NTUSER.DAT` then `hivexregedit --export` | the hives read: `SOFTWARE\…\CurrentVersion` gives `CurrentBuild=26100`, `DisplayVersion=24H2` (`base-software-currentversion.reg`); `SYSTEM\Setup` reads (the base image has no `ImageState` value yet; a captured one would say `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`, which `70-capture` reads inside WinPE today) |
| `hivexregedit --merge` of the lab role's `skel.reg` (rewritten to a hive-local root) into a copy of the Default profile's `NTUSER.DAT`, then export | `Software\PDT`: `SkelFrom="lab-apps"`, `Deployed=1` (`ntuser-after-merge.reg`). **The registry half of a role can be baked into an image on Linux**, which `SKELREG` does per machine at first logon today |
| `hivexregedit --export http/winpe/BCD '\'` | 66 keys: the boot manager, the WinPE loader object (`Type=0x10200003`), the ramdisk device object, settings objects (`winpe-bcd-export.reg`). **The BCD is editable on Linux**, which is what the serial-console (EMS) spike in `REMOTE_VISIBILITY.md` was waiting for: `bcdedit /ems on` is two elements in this file |

## What is worth doing with it, in order

1. **EMS / serial console for WinPE from Linux**: set the EMS elements in
   the served `BCD` with hivex (element ids to confirm against `bcdedit
   /enum all` on a Windows box **[read]**), boot a VM with `-serial`, and
   see the boot manager's and kernel's text console on the serial log. Pays
   off on real hardware only with a real UART or AMT Serial-over-LAN; costs
   an hour in the lab.
2. **`bin/stage-image`: read the captured image's `ImageState` on Linux**
   (`SYSTEM\Setup`) instead of trusting `Sysprep_succeeded.tag` alone. Small.
3. **Role images with the registry side baked in**: `bin/capture-image`
   (or a new `bin/tweak-image`) merges the role's `skel.reg` into the
   image's `Users/Default/NTUSER.DAT`, and could set machine-wide values
   (`SOFTWARE`/`SYSTEM`) the role wants, with wimlib's `update` to put the
   hive back. Replaces first-logon work with build-time work; keeps `lint`
   able to check it (a hive diff).
4. **`virt-inspector` on a reference VM's disk** before capture: Windows
   version, installed applications (from the Uninstall keys), for the
   sidecar's provenance. Needs the appliance (the kernel permission above).
5. Not needed: `virt-v2v`'s offline virtio driver injection (we add drivers
   in WinPE with DISM); `virt-customize --firstboot` (the unattend's
   `FirstLogonCommands` is the same hook, without rhsrvany); `guestmount`
   for capture (wimlib already reads the partition from a plain file).

## Not done

Nothing was changed in the toolkit; this is a feasibility record. The
appliance's rootless state is recorded below once `libguestfs-test-tool`
finishes.

## The appliance, rootless, on this host **[verified: not usable as is]**

`libguestfs-test-tool`: `cp: cannot open '/boot/vmlinuz-7.0.0-38-generic'
for reading: Permission denied` → `supermin exited with error status 1`.
Ubuntu's kernel image is `0600 root`; libguestfs needs to copy it into its
appliance. The documented fix is one root command,
`sudo dpkg-statoverride --update --add root root 0644 /boot/vmlinuz-7.0.0-38-generic`
(and again after kernel upgrades, or `/etc/kernel/postinst.d/statoverride`).
Until then, everything above that says "hivex" works and everything that
says "virt-*" does not. Nothing here needs the appliance yet.
