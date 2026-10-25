# 2026-10-24: `bin/smoke`, the final run — two installs at once, every layer measured

`report.md` is the verdict: **51 PASS, 8 controls fired, 1 FAIL, 0 UNKNOWN**
of 60 rows, 25 minutes wall, exit 1 because of the one FAIL (a firmware
hang, below). The four runs before it, and what each found, are in
`../2026-10-24-smoke-earlier-runs/`. Host: Ubuntu 26.04.1, QEMU 10.2.1, the
OVMF secboot build in setup mode, nginx on 8090; both VMs purged at the end.

| machine | `smoke-ssh` | `smoke-rdp` |
|---|---|---|
| role | `demo-ssh`: key-only SSH for `ops` (Administrators, the lab key) and `carol` (Users, her own key); no RDP, no apps | `demo-rdp`: Remote Desktop for `helpdesk` (Administrators) and `bob` (Users), 7-Zip from winget, `DEPLOY=remove`; no SSH |
| hardware | e1000e, one 64 GB AHCI disk, an 8 GB USB stick (xHCI, removable) with a marker file | virtio NIC and disk + the `virtio-w11` driver pack, one 64 GB disk, an 8 GB SD card (`sdhci-pci`) with a marker file |
| cfg | `UPDATES=lcu`, `STOP_AFTER=25-download` | `UPDATES=lcu` |
| PXE → `deployed` | 1089.9 s (of which about 45 s at the prompt for the hand checks, 758 s in `35-updates`) | 1301.3 s, including a 5-minute hang at the reboot out of WinPE and its recovery (724 s in `35-updates`) |

## Where everything is

| what you want to see | file |
|---|---|
| the verdict, one row per check, counts, the FAIL | `report.md` |
| the run as it happened, with timestamps | `smoke.log` |
| each machine's timeline (`bin/status <vm>`): every step, its duration, its message with the hash | `smoke-ssh-timeline.txt`, `smoke-rdp-timeline.txt` |
| the fleet view every 20 s while it ran (`bin/status`) | `status.log`, `status-final.txt` |
| screenshots (QEMU screendumps) at each stage; `*-pushed.png` are the screens the machines pushed themselves (`pdt-screen.exe`, `bin/screen`) | `shots/` (15 files): `*-pxe-winpe`, `smoke-ssh-*-stopped-prompt`, `*-applying`, `smoke-rdp-*-reboot-hang-recovered`, `*-firstlogon`, `*-deployed` |
| the deploy window as text at the stop; the list of all frames the window pushed | `smoke-ssh-console-at-stop.txt`, `*-console-frames.txt` |
| the hashes by hand in WinPE (`bin/shell`): pdt-sha256 on itself, curl fetching openssl.exe, `openssl dgst` of the image, `pdt-sha256 --check`, `verified.cmd` with a truthful and with a lying sidecar, the disk listing | `hash-on-machine.out` |
| `bin/keys` typing `deploy 30`, `bin/console --await 30-apply` | `keys-typed.out` |
| SSH logins and refusals, `Get-Disk` over SSH, the host key fingerprint | `ssh.out` |
| RDP credentials and refusals (`xfreerdp /auth-only`), the no-SSH control | `rdp.out` |
| everything each machine uploaded: `ts.log.gz`, `dism.log.gz`, Setup's panther logs, `users.txt` (passwords **masked**), `ssh.txt` (host keys), `disks.txt` (what the installed Windows sees), `console.txt`, `screen-last-pushed.png`, `winget.txt`, `cmd-N.out` (the hand checks' raw output) | `uploads/smoke-ssh/<run>/`, `uploads/smoke-rdp/<run>/` |
| the USB stick and SD card: built before boot, read back after the installs | `media-prep.out`, `media-readback.out` |
| the hang: QEMU's view of the stuck guest and the recovery | `smoke-rdp-reboot-hang.txt` |
| lint, the built tools, the lab keys, create/boot/shutdown/teardown | `lint.out`, `build-tools-check.out`, `keys.out`, `create.out`, `boot.out`, `shutdown.out`, `teardown.out` |
| the fix for the defect found in this run's log, verified on a fresh VM | `winre-fix-control.out` |
| all beacons of the day (every machine, for cross-reference) | `beacons.log` |

## What passed, layer by layer

- **Hashing.** `25-download` on both: the 3.5 GB image's SHA-256 matches
  `images/base.json` (`pdt-sha256.exe` on the machine). By hand on
  `smoke-ssh`: the hasher hashes itself to the hash `built.json` records
  (`cd096583…`); `curl` fetched `openssl.exe` and it hashes to the recorded
  `53842107…`; `openssl dgst -sha256 W:\image.wim` equals the sidecar;
  `pdt-sha256 --check` says match; `verified.cmd` with a truthful sidecar
  keeps the file, **with a lying one exits 1 and deletes it** (the
  control). `35-updates` on both: the 5.2 GB update pack verified
  (`254b71a4…`), then DISM added it; `40-drivers` on `smoke-rdp`: the driver
  pack verified (`0318467b…`); `45-winre` on both: the recovery image
  verified (`1f9ee125…`) — but see the defect below.
- **Updates.** Both machines booted build 26100.9550, the one `lcu.json`
  says to expect (`firstlogon` beacon). Two DISM update passes ran at once,
  758 s and 724 s (790 s for one alone earlier today).
- **Disk guard, removable media.** `smoke-ssh`: `disk 0:QEMU HARDDISK 64GiB
  of 2 (the only fixed disk)`, the stick `1|Removable Media|USB|8|… not
  eligible: removable media`. `smoke-rdp`: WinPE enumerated the SD card as
  disk 0 (`Generic QEMU! SD Card`, removable, SCSI) and the virtio disk as
  disk 1, and the guard chose disk 1 [verified: an SDHCI card is a
  `Win32_DiskDrive` to WinPE]. After the installs, both markers read back
  byte for byte, and the installed Windows reports both media
  (`disks.txt`: `disk 1|QEMU QEMU HARDDISK|USB|8GB|MBR`, `marker D: …`;
  `disk 1|VID:AA QEMU!|SD|8GB|MBR`, `marker D: …`), `role-post ok disks=2 markers=1`.
- **Console frames and keys.** The stop frame arrived within 60 s of the
  beacon; `bin/keys smoke-ssh 'deploy 30{enter}'` resumed the sequence and
  the next frame showed `30-apply`.
- **Boot.** `50-boot` on both: the firmware's first entry is Windows Boot
  Manager; both booted Windows from the disk, no second `ts-start`.
- **Roles.** `smoke-ssh`: `users ok created=ops,carol keys=carol`, `ssh ok
  … listening=yes`, `faststartup ok state=off`, no `rdp` beacon.
  `smoke-rdp`: `users ok created=helpdesk,bob`, `apps ok installed=7zip.7zip`
  (visible in the Start menu of `shots/smoke-rdp-224810-deployed.png`),
  `rdp ok listening=yes`, `deploy-remove`, restart, `boot ok`,
  `deploy-removed ok profile_gone=ok`, no `ssh` beacon. Generated passwords
  uploaded by both, masked here.
- **SSH from this host.** `ops` logs in with the lab key; `carol` with
  `build/lab-carol`, `whoami` = `…\carol`; refused: carol with the
  administrators' key, ops without a key, carol with alice's key; the host
  key fingerprint offered equals the one in `ssh.txt`; `Get-Disk` shows the
  stick as `BusType USB`.
- **RDP from this host.** `helpdesk` and `bob` authenticate with their
  generated passwords; refused: bob with a wrong password, the deleted
  `deploy` account. RDP to `smoke-ssh` fails (no listener behind QEMU's port
  forward, so xfreerdp hangs and the 30 s timeout ends it, rc 124); SSH to
  `smoke-rdp` refused.
- **Shutdown.** `smoke-ssh` by `shutdown /s /t 0` over SSH; `smoke-rdp` at
  its login screen by the ACPI button within 60 s (in run 3 it was not).
- **Lint and tools.** 227 PASS, self-test 59/59; `build-tools check` all
  recorded.

## The one FAIL: the firmware hang, third time today

`smoke-rdp` sent `ts-done ok` at 22:40:28 and no `specialize` for 300 s.
QEMU: `running`, CPU#0 at `RIP=7bf7c483`, CPU#1-3 halted at `7ad65d71`,
serial and disk untouched since the reboot — **the same registers as run
4's hang of the same VM** (that one after specialize). The driver recorded
it, force-stopped and booted it from its disk; `specialize` 65 s later,
`deployed` 2 min 40 s after the recovery, every later row passed. Three of
ten guest-initiated reboots in the smoke runs hung (`TODO.md` has the
record and the bisection to try next). The row is a FAIL because the hang
is real; the toolkit is not what hung.

## A defect this run found in the toolkit, after the report

The ts.log of both machines shows `45-winre` running **both** branches:
`1 File(s) copied` (the image's Winre.wim) and then `the image has no
Winre.wim, fetching images/base.winre.wim`, which overwrote it, and the step
message said "taken from the server". Cause: the message line added earlier
this evening, `echo Winre.wim from the image itself (W:\Windows\System32\Recovery)`,
sits inside the `if exist (...) else (...)` block, and in cmd an unescaped
`)` ends the block. The report's `45-winre` rows passed because the
alternation accepted either message; the log is what told the truth. Fixed
(no parentheses in the line), and verified on a fresh VM stopped after that
step: `45-winre ok msg=Winre.wim from the image itself, W:\Windows\System32\Recovery`,
one `1 File(s) copied`, no fetch (`winre-fix-control.out`). The two
`base.winre.wim` copies are the same bytes (both come from the ISO), so the
installed machines are correct; the step was not. The same grep over every
`.cmd` found no other unquoted parenthesis inside a block.

## Honest limits

- The hang is observed and recovered, not explained. Whether it is OVMF's
  SMM reset path, QEMU 10.2, or the hardware variant is open.
- `smoke-ssh`'s hand checks run from the shell loop's own window, so the
  deploy window's frames and the "after hand checks" screenshot are
  identical to the stop frame; `hash-on-machine.out` has the output.
- RDP was checked with `/auth-only` (credentials), not a rendered session.
- The two update passes competing for the host's disk is the only
  concurrency load tried; two machines, not twenty.
- Nothing here ran on physical hardware.
