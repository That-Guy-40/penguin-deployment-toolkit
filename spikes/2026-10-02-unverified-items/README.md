# 2026-10-02: working through the "not verified" list

After Phase 2 the docs listed what had not been verified. This is what was
done about each item, on this host, in lab VMs. Timelines of every VM are in
`timelines.txt` (`bin/status <vm>`).

## 1. Update packs beyond one cumulative update **[verified]**

Source: two UUP sets kept with `bin/fetch-iso --keep` (24H2 and 25H2). The
packages in them: `KB5043080` (24H2 checkpoint update, .msu), `KB5124010`
(cumulative update for x.9550, .msu, 4.4 GB), `KB5126052` (.NET 4.8.1
cumulative update, .cab), `KB5054156` (25H2 enablement package, .cab, tiny),
`KB5125758` (Safe OS dynamic update: for the WinRE image, not the OS),
`KB5127216` (Setup dynamic update: files for installation media, not a
servicing package).

| VM | pack (`--target`s; all with the checkpoint beside them) | result |
|---|---|---|
| ua | cumulative update + .NET update, `--expect 26100.9550` | `35-updates ok` (DISM: success for each target); installed system reports `build=26100.9550` |
| ub | cumulative update + **25H2 enablement** + .NET update | `35-updates ok`; installed system reports **`build=26200.9550`**: Windows 11 25H2 from the 26100.1 base image |
| uc | only the Setup dynamic update, no target | `35-updates fail rc=2` (DISM cannot open it as a package): a file that is not a servicing package fails the step |

`bin/fetch-iso --release 25H2` was run as well: it builds, and its sidecar
says what is true, that the image inside is still 26100.1 (`iso-25h2-sidecar.json`).
"25H2" is the 24H2 base plus the cumulative update plus the enablement package,
which is exactly what pack `ub` delivers.

Not done: the Safe OS update is not applied to the recovery image, so WinRE
stays at the base build.

## 2. A generalized (sysprep) image, captured and deployed **[verified]**

`bin/vm-create ref1 --reference` (cfg `REFERENCE=yes`): after first logon the
machine runs `post/prepare-capture.cmd` (stamp, `sysprep /generalize /oobe`,
full shutdown). Then, two ways to capture it, both deployed to a fresh VM:

| path | capture | deployed VM |
|---|---|---|
| WinPE: `MODE=capture`, `bin/stage-image --from-upload ref1 --name role-test` | `70-capture ok … state IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`, 3.59 GB (XPRESS) | r1: `specialize ok`, `firstlogon ok … image=reference 77a1b6f7… run 314504395`, `winre ok` |
| Linux: `bin/capture-image ref1 role-linux` (VM off; qemu-img, partition cut out, wimlib NTFS capture **from a plain file**) | 89 s, 3.22 GB (LZX) | r2: the same three events, same stamp |

The stamp in the `firstlogon` event is the proof that the captured state
carried over; `specialize` and a new host name are the proof that the image
was generalized (the un-sysprepped capture of Phase 2 produced neither).

Learned on the way:

- `reagentc /disable` does **not** move `Winre.wim` back onto the Windows
  volume when WinRE lives on a recovery partition (first attempt: `prepare-capture
  fail`). A captured volume therefore never contains it. Fix: `bin/stage-image`
  keeps `images/<name>.winre.wim` beside every image (extracted from the base
  image on Linux) and `45-winre` falls back to it: `45-winre ok msg=Winre.wim
  taken from the server`.
- Generalizing removes the network adapter, so `prepare-capture`'s final
  beacon cannot be delivered. The verdict is read from the disk instead:
  `70-capture` reports the offline `ImageState`, and `stage-image` warns when
  an image has no `Sysprep_succeeded.tag`.
- In `base.wim` the file is `winre.wim`, lowercase; wimlib on Linux is
  case-sensitive unless told otherwise.
- The unattend's `deploy` account already exists in the captured image; OOBE
  did not object.

## 3. Others found in the docs, and what happened to each

| item | outcome |
|---|---|
| Do drivers injected by wimboot + `drvload` give WinPE a NIC/disk it has no driver for? (PLAN open question 1) | **Yes [verified].** v1: virtio NIC *and* virtio disk, `DrvLoad: Successfully loaded` ×3, full deploy. Control v0 (no injection): WinPE boots, never reaches the server. `netkvm.inf` needs every file it names beside it (two `.exe`), or drvload says "file not found" |
| How to select those drivers | By the NIC's **PCI id** (`${netX/busid}`) or the product name, not by iPXE's chip name: started by firmware PXE, as on real hardware, iPXE reports every chip as `SNP` (sb0, found when the first no-ROM boot got no drivers) |
| Firmware's own PXE stack loading our `ipxe.efi` (the path real hardware takes; lab VMs use an iPXE option ROM) | **[verified]** `vm-boot --no-rom`: sb0, sb2, sb3, pp2 |
| Secure Boot enforcing (open question 3) | **[verified in a VM]** Unsigned `ipxe.efi`: firmware downloads it, then "Access Denied" (`secureboot-enforcing-unsigned-ipxe.png`), no request reaches the server. Signed with our own key (`SB_KEY`/`SB_CERT`, `sbsign`) and the certificate enrolled in the firmware's db: full deploy, and Windows itself reports `secureboot=True` (sb3). `wimboot` and `bootmgfw.efi` are already Microsoft-signed; the virtio drivers loaded under Secure Boot. Enrolling a certificate in real firmware is still a manual, per-vendor step |
| Proxy-DHCP next to another DHCP server | **[verified in `lab-netns`]** A second dnsmasq in a nested namespace played "the router" (addresses only). `bin/pxe-lan start` in proxy mode answered the PXE part and served `ipxe.efi`: pp1 (iPXE-ROM client) and pp2 (firmware client, full deploy). Control pp3 with our proxy stopped: nothing boots (`proxy-dhcp.txt`). Proxy mode now serves `ipxe.efi` to iPXE-ROM clients too |
| Could `ipxe.efi` use `${next-server}` instead of a baked-in address? | **No [verified].** In proxy mode iPXE's `next-server` is the *router* (`bootsrv=10.42.0.254`), not us. The baked-in `HTTP_HOST` stays. The value is now logged with every boot (`bootsrv=`), which also shows which DHCP server a machine listened to |
| winget at first logon (open question 2) | **Absent [verified]** on an image built from UUP dump: no `winget`, App Installer not even staged. Bootstrapping with the release's `msixbundle` plus `DesktopAppInstaller_Dependencies.zip` works at first logon and `winget install 7zip.7zip` then succeeds (p4). VCLibs + UI.Xaml alone no longer suffice: it wants `Microsoft.WindowsAppRuntime.1.8` (`first-logon-probes.txt`) |
| The every-boot beacon that "never fired" | **Explained [verified]** (p3). After a real restart the "at startup" task fires. After a fast-startup shutdown and power-on it does not (Windows resumes, it does not boot), but a task triggered on System event Kernel-Boot 27 does. A reliable probe needs both triggers. The original spike had powered the VM off through ACPI, i.e. fast startup |
| Linux-side capture: does wimlib's NTFS mode take a plain file? (open question 5) | **Yes [verified]**, see §2 |

## 4. Still not verified, and why

- **Anything on physical hardware**, including enrolling a Secure Boot
  certificate in real firmware and LAN throughput: no hardware attached.
- **A bridge on the real host** (setuid `qemu-bridge-helper`,
  `/etc/qemu/bridge.conf`, firewall): needs root, which was not available.
  The same lab inside `bin/lab-netns` is verified.
- **`bin/lab-netns` on a stock Ubuntu 24.04** where unprivileged user
  namespaces are restricted: changing that sysctl needs root.
- After a *forced* power-off (QEMU killed), neither boot task reported within
  150 s on p3. Not investigated: it may simply have been a fast-startup resume.
- The remote-shell idea for `MODE=shell` machines, streaming apply, and the
  dispatcher remain unbuilt ideas, not unverified claims.

## 5. Bugs found and fixed while doing this

- A pipe to a missing program (Phase 2) had a cousin: `lint`'s fixture and the
  first `drvload` attempt both failed on *incomplete file sets*; the injection
  now copies every file of a driver.
- `bin/fetch-tools virtio` left its temp dir path in a function-local variable
  used by an EXIT trap (fixed earlier) and now regenerates `winpe-drivers/`
  from scratch each run.
- My own test of the boot task was void the first time: the keystrokes landed
  in the Start menu and the VM never restarted. The probe now restarts the
  machine itself.
