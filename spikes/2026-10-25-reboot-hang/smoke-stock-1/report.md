# smoke: two concurrent installs, every layer checked (2026-10-27)

Host: Ubuntu 26.04.1 LTS; QEMU emulator version 10.2.1 (Debian 1:10.2.1+ds-1ubuntu3.2). Started 2026-10-27T18:49:38-04:00, took 55 min.
VMs: `smoke-ssh` (demo-ssh, AHCI disk + 8 GB USB stick, STOP_AFTER=25-download) and `smoke-rdp` (demo-rdp, virtio disk/NIC + virtio-w11, 8 GB SD card), both UPDATES=lcu, booted 18:49:43 within one second of each other. Both purged afterwards.

**48 PASS, 8 controls fired, 4 FAIL, 0 UNKNOWN** of 60 rows.

| verdict | layer | what | evidence |
|---|---|---|---|
| PASS | tools | every served binary is the one built-tools recorded (pdt-sha256, pdt-screen, pdt-console, openssl) | build-tools-check.out |
| PASS | roles | lab keys written into every role with SSH=on (fetch-tools keys) | keys.out |
| PASS | lint | bin/lint passes with the two demo roles and no lab VMs | 227 PASS, 0 FAIL, 0 UNKNOWN   (-v lists every row) |
| PASS | media | marker files written to the USB stick and the SD card images before boot | media-prep.out |
| PASS | sequence | smoke-ssh stopped at the WinPE prompt after 25-download (STOP_AFTER) |   2026-10-27T18:50:40-04:00  +   48.2s  (+   0.2s)  stop        ok    after=25-download |
| PASS | console | the deploy window's text frame shows the stop within 60 s of the beacon (pdt-console.exe dump, bin/console --await) | smoke-ssh-console-at-stop.txt |
| PASS | verify | 25-download on smoke-ssh: the image's SHA-256 matches images/base.json (pdt-sha256 on the machine) | sha256 0c947e482585e95418832fa74b37e67dd9c4fd92bc3c83229dc8034f0020a279 matches images/base.json |
| PASS | tools | pdt-sha256.exe on smoke-ssh hashes itself to the hash built-tools recorded | cd0965834efb92c03499bc327ca7e6ed72c6e10176c53bea13a411bda1356aa0 |
| PASS | tools | curl on smoke-ssh fetched openssl.exe and pdt-sha256 gives the recorded hash | 5384210784f5a4182192316bba6d2b0a0381f65ed8e0e6ea6067c889354f687c |
| PASS | verify | openssl dgst -sha256 on smoke-ssh agrees with the sidecar for the 3.5 GB image (the second opinion) | 0c947e482585e95418832fa74b37e67dd9c4fd92bc3c83229dc8034f0020a279 |
| PASS | verify | pdt-sha256 --check on smoke-ssh: image against the sidecar 25-download saved | exit 0 = matches |
| PASS | verify | verified.cmd on smoke-ssh with a truthful sidecar: exit 0, the file kept | rc=0 kept=0 |
| PASS (control fired, rc=1) | verify | CONTROL: verified.cmd on smoke-ssh with a lying sidecar must fail and delete the download | verified.cmd rc=1, deleted=yes; tools/pdt-screen.exe does not match the sha256 in cmd/smoke/bad.json: download deleted |
| PASS | diskguard | 17-diskguard on smoke-ssh listed the USB stick as not eligible (removable media / on USB) and chose the one fixed disk | disk 0:QEMU HARDDISK 64GiB of 2 (the only fixed disk); 1|Removable Media|USB|8|QEMU QEMU HARDDISK USB Device|not eligible: removable media (Removable Media) |
| PASS | console | bin/keys resumed smoke-ssh (deploy 30) and the next frame shows 30-apply | keys rc=0, console --await rc=0 |
| PASS | deploy | smoke-ssh deployed (PXE -> WinPE -> apply -> first logon -> role) in 1123 s wall |   2026-10-27T19:08:26-04:00  + 1114.1s  (+   0.1s)  deployed    ok    host=WIN-MMVR3D16SGG role=demo-ssh |
| PASS | deploy | smoke-rdp deployed, with the driver pack, in 1123 s wall |   2026-10-27T19:06:59-04:00  + 1028.2s  (+   0.0s)  deployed    ok    host=WIN-O2MEP19L943 role=demo-rdp |
| PASS | firmware | smoke-ssh came through both reboots (WinPE -> Setup, specialize -> first logon) on its own |   2026-10-27T19:07:55-04:00  + 1083.4s  (+  55.6s)  firstlogon  ok    host=WIN-MMVR3D16SGG build=26100.9550 secureboot=False user=deploy |
| PASS | firmware | smoke-rdp came through both reboots (WinPE -> Setup, specialize -> first logon) on its own |   2026-10-27T19:06:18-04:00  +  986.8s  (+  53.3s)  firstlogon  ok    host=WIN-O2MEP19L943 build=26100.9550 secureboot=False user=deploy |
| PASS | verify | 25-download on smoke-rdp: the image verified | sha256 0c947e482585e95418832fa74b37e67dd9c4fd92bc3c83229dc8034f0020a279 matches images/base.json |
| PASS | verify | 35-updates on smoke-ssh: the update pack verified against updates/lcu.json before DISM added it | package 26100.9550 is installed in the image; sha256 254b71a462b33ea450ef84eca1749c67599284272115b881a31d76326646c697 matches updates/lcu.json |
| PASS | verify | 35-updates on smoke-rdp: the update pack verified against updates/lcu.json before DISM added it | package 26100.9550 is installed in the image; sha256 254b71a462b33ea450ef84eca1749c67599284272115b881a31d76326646c697 matches updates/lcu.json |
| PASS | verify | 40-drivers on smoke-rdp: the driver pack verified against drivers/virtio-w11.json | sha256 0318467bc1adf768b54e54b97de367b52f0c5053ad966d1b5acdf66cff325330 matches drivers/virtio-w11.json |
| PASS | verify | 45-winre on smoke-ssh: Winre.wim from the image itself (base.wim carries one), or the server's verified against its sidecar | Winre.wim from the image itself, W:\Windows\System32\Recovery |
| PASS | boot | 50-boot on smoke-ssh: the firmware's first entry is Windows Boot Manager | boot files written; the firmware boots Windows Boot Manager first |
| PASS | roles | FASTSTARTUP=off applied on smoke-ssh |   2026-10-27T19:08:07-04:00  + 1095.2s  (+   0.1s)  faststartup ok    state=off |
| PASS | verify | 45-winre on smoke-rdp: Winre.wim from the image itself (base.wim carries one), or the server's verified against its sidecar | Winre.wim from the image itself, W:\Windows\System32\Recovery |
| PASS | boot | 50-boot on smoke-rdp: the firmware's first entry is Windows Boot Manager | boot files written; the firmware boots Windows Boot Manager first |
| PASS | roles | FASTSTARTUP=off applied on smoke-rdp |   2026-10-27T19:06:50-04:00  + 1019.6s  (+   0.2s)  faststartup ok    state=off |
| PASS | diskguard | 17-diskguard on smoke-rdp chose the one fixed (virtio) disk, whatever its number | disk 1:Red Hat VirtIO SCSI Disk Device 64GiB of 2 (the only fixed disk) |
| PASS | diskguard | WinPE on smoke-rdp saw the SD card as a disk and the guard rejected it as removable media | 0|Removable Media|SCSI|8|Generic QEMU! SD Card|not eligible: removable media (Removable Media) |
| PASS | roles | users on smoke-ssh: ops and carol created, carol's key installed |   2026-10-27T19:08:07-04:00  + 1095.0s  (+   5.5s)  users       ok    keys=carol created=ops,carol set=deploy |
| PASS | roles | SSH=on on smoke-ssh: OpenSSH Server installed, listening |   2026-10-27T19:08:22-04:00  + 1110.1s  (+  14.9s)  ssh         ok    port=22 shell=powershell keys=1 listening=yes |
| PASS | roles | no rdp beacon from smoke-ssh (the role has no RDP=on) | demo-ssh/role.cfg |
| PASS | roles | users on smoke-rdp: helpdesk and bob created with generated passwords |   2026-10-27T19:06:30-04:00  +  998.7s  (+   5.2s)  users       ok    created=helpdesk,bob set=deploy |
| PASS | roles | RDP=on on smoke-rdp: Remote Desktop listening |   2026-10-27T19:06:55-04:00  + 1024.4s  (+   4.8s)  rdp         ok    listening=yes |
| PASS | roles | APPS on smoke-rdp: 7-Zip installed by winget at first logon |   2026-10-27T19:06:50-04:00  + 1019.3s  (+   6.7s)  apps        ok    installed=7zip.7zip |
| PASS | roles | no ssh beacon from smoke-rdp (the role has no SSH=on) | demo-rdp/role.cfg |
| PASS | media | post.cmd on smoke-ssh: the installed Windows sees the removable medium and reads its marker (disks.txt) |   2026-10-27T19:08:26-04:00  + 1114.1s  (+   3.7s)  role-post   ok    disks=2 markers=1 |
| PASS | media | post.cmd on smoke-rdp: the installed Windows sees the removable medium and reads its marker (disks.txt) |   2026-10-27T19:06:59-04:00  + 1028.2s  (+   3.6s)  role-post   ok    disks=2 markers=1 |
| PASS | updates | smoke-ssh runs build 26100.9550, the one the update pack expects (firstlogon beacon) |   2026-10-27T19:07:55-04:00  + 1083.4s  (+  55.6s)  firstlogon  ok    host=WIN-MMVR3D16SGG build=26100.9550 secureboot=False user=deploy |
| PASS | updates | smoke-rdp runs build 26100.9550, the one the update pack expects (firstlogon beacon) |   2026-10-27T19:06:18-04:00  +  986.8s  (+  53.3s)  firstlogon  ok    host=WIN-O2MEP19L943 build=26100.9550 secureboot=False user=deploy |
| PASS | ssh | ops (Administrators, SSHKEYS) logs in to smoke-ssh with the lab key | ssh.out |
| PASS | ssh | carol (Users, keys=carol.pub) logs in to smoke-ssh with her own key, whoami says carol | ssh.out |
| PASS (control fired, rc=255) | ssh | CONTROL: carol with the administrators' key is refused | ssh.out |
| PASS (control fired, rc=255) | ssh | CONTROL: ops without a key is refused (passwords are off) | ssh.out |
| PASS (control fired, rc=255) | ssh | CONTROL: carol with another lab user's key (alice's) is refused | ssh.out |
| PASS | media | the installed Windows on smoke-ssh lists the USB stick (Get-Disk BusType USB) over SSH | ssh.out |
| PASS | ssh | the host key fingerprint offered to this host is the one smoke-ssh reported in ssh.txt | SHA256:FuoM4Koj7w35WNL9Rg748w+jU9jV62tQBXOO34MC7Pg |
| PASS (control fired, rc=124) | rdp | CONTROL: RDP to smoke-ssh (no RDP=on) fails (QEMU's port forward accepts the TCP connection, the guest has no listener: xfreerdp hangs and the 30 s timeout ends it, rc 124) | ssh.out |
| FAIL | roles | DEPLOY=remove on smoke-rdp: deploy account deleted, restart, profile gone | rc=2;  |
| PASS | roles | generated passwords for every account were uploaded as users.txt by both machines | bin/logs <vm> --cat users.txt (masked in this directory) |
| FAIL | rdp | helpdesk (Administrators) authenticates over RDP to smoke-rdp with the generated password (xfreerdp /auth-only) | rc=1; rdp.out |
| FAIL | rdp | bob (Users, Remote Desktop Users) authenticates over RDP to smoke-rdp | rc=124; rdp.out |
| PASS (control fired, rc=124) | rdp | CONTROL: bob with a wrong password is refused | rdp.out |
| PASS (control fired, rc=124) | rdp | CONTROL: the deleted deploy account is refused | rdp.out |
| PASS (control fired, rc=255) | ssh | CONTROL: SSH to smoke-rdp (no SSH=on) is refused | rdp.out |
| FAIL | shutdown | smoke-rdp at its login screen powers down on the ACPI button within 60 s (vm-stop); run 3 needed the forced stop | rc=1; shutdown.out |
| PASS | media | the USB stick's marker survived the install on smoke-ssh (read back with mtools) | media-readback.out |
| PASS | media | the SD card's marker survived the install on smoke-rdp | media-readback.out |

Files: `smoke.log` (the run), `status.log` (bin/status every 20 s), `*-timeline.txt` (bin/status <vm>), `hash-on-machine.out` (the hashes by hand in WinPE), `ssh.out`, `rdp.out`, `uploads/<vm>/<run>/` (everything the machines pushed: ts.log, dism.log and Setup's panther logs gzipped when over 1 MB, users.txt masked, ssh.txt, disks.txt, console.txt, the last pushed screen), `shots/` (QEMU screendumps at each stage; `*-pushed.png` are the screens the machines pushed themselves), `media-prep.out`/`media-readback.out` (sfdisk, mkfs.vfat, mtools), `*-reboot-hang.txt` (only when a guest hung at its reboot: QEMU's registers, the recovery), `create.out`, `boot.out`, `lint.out`, `build-tools-check.out`.
