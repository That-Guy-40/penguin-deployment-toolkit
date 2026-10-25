# smoke: two concurrent installs, every layer checked (2026-10-24)

Host: Ubuntu 26.04.1 LTS; QEMU emulator version 10.2.1 (Debian 1:10.2.1+ds-1ubuntu3.2). Started 2026-10-24T20:46:14-04:00, took 45 min.
VMs: `smoke-ssh` (demo-ssh, AHCI disk + 8 GB USB stick, STOP_AFTER=25-download) and `smoke-rdp` (demo-rdp, virtio disk/NIC + virtio-w11, UPDATES=lcu, 8 GB SD card), booted 20:46:19 within one second of each other. Both purged afterwards.

**38 PASS, 8 controls fired, 10 FAIL, 0 UNKNOWN** of 56 rows.

| verdict | layer | what | evidence |
|---|---|---|---|
| PASS | tools | every served binary is the one built-tools recorded (pdt-sha256, pdt-screen, pdt-console, openssl) | build-tools-check.out |
| PASS | roles | lab keys written into every role with SSH=on (fetch-tools keys) | keys.out |
| PASS | lint | bin/lint passes with the two demo roles and no lab VMs | 227 PASS, 0 FAIL, 0 UNKNOWN   (-v lists every row) |
| PASS | media | marker files written to the USB stick and the SD card images before boot | media-prep.out |
| PASS | sequence | smoke-ssh stopped at the WinPE prompt after 25-download (STOP_AFTER) |   2026-10-24T20:47:15-04:00  +   47.9s  (+   0.2s)  stop        ok    after=25-download |
| FAIL | console | the deploy window's text frame shows the stop (pdt-console.exe dump, bin/console) | rc=1; smoke-ssh-console-at-stop.txt |
| PASS | verify | 25-download on smoke-ssh: the image's SHA-256 matches images/base.json (pdt-sha256 on the machine) | sha256 0c947e482585e95418832fa74b37e67dd9c4fd92bc3c83229dc8034f0020a279 matches images/base.json |
| PASS | tools | pdt-sha256.exe on smoke-ssh hashes itself to the hash built-tools recorded | cd0965834efb92c03499bc327ca7e6ed72c6e10176c53bea13a411bda1356aa0 |
| PASS | tools | curl on smoke-ssh fetched openssl.exe and pdt-sha256 gives the recorded hash | 5384210784f5a4182192316bba6d2b0a0381f65ed8e0e6ea6067c889354f687c |
| PASS | verify | openssl dgst -sha256 on smoke-ssh agrees with the sidecar for the 3.5 GB image (the second opinion) | 0c947e482585e95418832fa74b37e67dd9c4fd92bc3c83229dc8034f0020a279 |
| PASS | verify | pdt-sha256 --check on smoke-ssh: image against the sidecar 25-download saved | exit 0 = matches |
| PASS | verify | verified.cmd on smoke-ssh with a truthful sidecar: exit 0, the file kept | rc=0 kept=0 |
| PASS (control fired, rc=1) | verify | CONTROL: verified.cmd on smoke-ssh with a lying sidecar must fail and delete the download | verified.cmd rc=1, deleted=yes; tools/pdt-screen.exe does not match the sha256 in cmd/smoke/bad.json: download deleted |
| PASS | diskguard | 17-diskguard on smoke-ssh listed the USB stick as not eligible (removable media / on USB) and chose the one fixed disk | disk 0:QEMU HARDDISK 64GiB of 2 (the only fixed disk); 1|Removable Media|USB|8|QEMU QEMU HARDDISK USB Device|not eligible: removable media (Removable Media) |
| PASS | console | bin/keys resumed smoke-ssh (deploy 30) and the next frame shows 30-apply | keys rc=0, console --await rc=0 |
| FAIL | deploy | smoke-ssh deployed (PXE -> WinPE -> apply -> first logon -> role) in 1620 s wall | rc=2;  |
| PASS | deploy | smoke-rdp deployed, with updates and drivers, in 1620 s wall |   2026-10-24T21:03:10-04:00  + 1003.1s  (+   0.1s)  deployed    ok    host=WIN-9B0RSH7TT6E role=demo-rdp |
| PASS | verify | 25-download on smoke-rdp: the image verified | sha256 0c947e482585e95418832fa74b37e67dd9c4fd92bc3c83229dc8034f0020a279 matches images/base.json |
| PASS | verify | 35-updates on smoke-rdp: the update pack verified against updates/lcu.json before DISM added it | package 26100.9550 is installed in the image; sha256 254b71a462b33ea450ef84eca1749c67599284272115b881a31d76326646c697 matches updates/lcu.json |
| PASS | verify | 40-drivers on smoke-rdp: the driver pack verified against drivers/virtio-w11.json | sha256 0318467bc1adf768b54e54b97de367b52f0c5053ad966d1b5acdf66cff325330 matches drivers/virtio-w11.json |
| FAIL | verify | 45-winre on smoke-ssh: the recovery image verified | rc=1;  |
| PASS | boot | 50-boot on smoke-ssh: the firmware's first entry is Windows Boot Manager | boot files written; the firmware boots Windows Boot Manager first |
| PASS | roles | FASTSTARTUP=off applied on smoke-ssh |   2026-10-24T21:19:09-04:00  + 1961.6s  (+   0.1s)  faststartup ok    state=off |
| FAIL | verify | 45-winre on smoke-rdp: the recovery image verified | rc=1;  |
| PASS | boot | 50-boot on smoke-rdp: the firmware's first entry is Windows Boot Manager | boot files written; the firmware boots Windows Boot Manager first |
| PASS | roles | FASTSTARTUP=off applied on smoke-rdp |   2026-10-24T21:03:02-04:00  +  995.3s  (+   0.2s)  faststartup ok    state=off |
| FAIL | diskguard | 17-diskguard on smoke-rdp chose the one fixed (virtio) disk | rc=1; disk 1:Red Hat VirtIO SCSI Disk Device 64GiB of 2 (the only fixed disk) |
| PASS | diskguard | WinPE on smoke-rdp saw the SD card as a second, not eligible disk | disk 1:Red Hat VirtIO SCSI Disk Device 64GiB of 2 (the only fixed disk) |
| PASS | roles | users on smoke-ssh: ops and carol created, carol's key installed |   2026-10-24T21:19:09-04:00  + 1961.4s  (+   1.9s)  users       ok    keys=carol |
| PASS | roles | SSH=on on smoke-ssh: OpenSSH Server installed, listening |   2026-10-24T21:19:21-04:00  + 1973.8s  (+  12.2s)  ssh         ok    port=22 shell=powershell keys=1 listening=yes |
| PASS | roles | no rdp beacon from smoke-ssh (the role has no RDP=on) | demo-ssh/role.cfg |
| FAIL | roles | users on smoke-rdp: helpdesk and bob created with generated passwords | rc=1;   2026-10-24T21:02:42-04:00  +  975.1s  (+   5.1s)  users       ok     |
| PASS | roles | RDP=on on smoke-rdp: Remote Desktop listening |   2026-10-24T21:03:06-04:00  +  999.7s  (+   4.4s)  rdp         ok    listening=yes |
| PASS | roles | APPS on smoke-rdp: 7-Zip installed by winget at first logon |   2026-10-24T21:03:02-04:00  +  995.1s  (+   6.8s)  apps        ok    installed=7zip.7zip |
| PASS | roles | no ssh beacon from smoke-rdp (the role has no SSH=on) | demo-rdp/role.cfg |
| FAIL | media | post.cmd on smoke-ssh: the installed Windows sees the removable medium and reads its marker (disks.txt) | rc=1;   2026-10-24T21:19:24-04:00  + 1976.5s  (+   2.5s)  role-post   ok     |
| FAIL | media | post.cmd on smoke-rdp: the installed Windows sees the removable medium and reads its marker (disks.txt) | rc=1;   2026-10-24T21:03:10-04:00  + 1003.0s  (+   3.2s)  role-post   ok     |
| PASS | updates | smoke-rdp runs build 26100.9550, the one the update pack expects (firstlogon beacon) |   2026-10-24T21:02:31-04:00  +  964.2s  (+  59.5s)  firstlogon  ok    host=WIN-9B0RSH7TT6E build=26100.9550 secureboot=False |
| PASS | updates | smoke-ssh, no updates, runs the image's build 26100.1 |   2026-10-24T21:19:04-04:00  + 1956.8s  (+  51.4s)  firstlogon  ok    host=WIN-JMV7LGGCDDO build=26100.1 secureboot=False |
| PASS | ssh | ops (Administrators, SSHKEYS) logs in to smoke-ssh with the lab key | ssh.out |
| FAIL | ssh | carol (Users, keys=carol.pub) logs in to smoke-ssh with her own key, whoami says carol | rc=1; ssh.out |
| PASS (control fired, rc=255) | ssh | CONTROL: carol with the administrators' key is refused | ssh.out |
| PASS (control fired, rc=255) | ssh | CONTROL: ops without a key is refused (passwords are off) | ssh.out |
| PASS (control fired, rc=255) | ssh | CONTROL: carol with another lab user's key (alice's) is refused | ssh.out |
| PASS | media | the installed Windows on smoke-ssh lists the USB stick (Get-Disk BusType USB) over SSH | ssh.out |
| PASS | ssh | the host key fingerprint offered to this host is the one smoke-ssh reported in ssh.txt | SHA256:7kX/b/l4l4KQuH9oU/qAukYGJaGWxaoUfsc9dXbJaSs |
| PASS (control fired, rc=124) | rdp | CONTROL: RDP to smoke-ssh (no RDP=on) is refused | ssh.out |
| FAIL | roles | DEPLOY=remove on smoke-rdp: deploy account deleted, restart, profile gone | rc=2;   2026-10-24T21:05:17-04:00  + 1130.7s  (+   5.3s)  deploy-removed ok    profile_gone=ok |
| PASS | roles | generated passwords for every account were uploaded as users.txt by both machines | bin/logs <vm> --cat users.txt (masked in this directory) |
| PASS | rdp | helpdesk (Administrators) authenticates over RDP to smoke-rdp with the generated password (xfreerdp /auth-only) | rdp.out |
| PASS | rdp | bob (Users, Remote Desktop Users) authenticates over RDP to smoke-rdp | rdp.out |
| PASS (control fired, rc=134) | rdp | CONTROL: bob with a wrong password is refused | rdp.out |
| PASS (control fired, rc=134) | rdp | CONTROL: the deleted deploy account is refused | rdp.out |
| PASS (control fired, rc=255) | ssh | CONTROL: SSH to smoke-rdp (no SSH=on) is refused | rdp.out |
| PASS | media | the USB stick's marker survived the install on smoke-ssh (read back with mtools) | media-readback.out |
| PASS | media | the SD card's marker survived the install on smoke-rdp | media-readback.out |

Files: `smoke.log` (the run), `status.log` (bin/status every 20 s), `*-timeline.txt` (bin/status <vm>), `hash-on-machine.out` (the hashes by hand in WinPE), `ssh.out`, `rdp.out`, `uploads/<vm>/<run>/` (everything the machines pushed: ts.log, dism.log, users.txt masked, ssh.txt, disks.txt, console.txt, the last pushed screen), `shots/` (QEMU screendumps at each stage; `*-pushed.png` are the screens the machines pushed themselves), `media-prep.out`/`media-readback.out` (sfdisk, mkfs.vfat, mtools), `create.out`, `boot.out`, `lint.out`, `build-tools-check.out`.
