# 2026-10-24: the smoke test's first runs, and what each one smoked out

`bin/smoke` was written this evening and run five times. The last run's
evidence is `../2026-10-24-smoke/`; this directory keeps what the earlier
runs found, because the point of the exercise was to find errors in the
workflow and in the expected outcomes, and most of what it found was in
the test itself, the lab, and the firmware, not in the task sequence.

Every run: two VMs created and booted within a second of each other,
`smoke-ssh` (role `demo-ssh`, AHCI disk + 8 GB USB stick, `STOP_AFTER=25-download`)
and `smoke-rdp` (role `demo-rdp`, virtio disk and NIC + the virtio-w11 driver
pack, 8 GB SD card); host Ubuntu 26.04.1, QEMU 10.2.1, OVMF secboot build
in setup mode, nginx on 8090. All VMs purged after each run.

| run | ended | finding | whose defect | fixed by |
|---|---|---|---|---|
| 1 | at the media preparation, 4 s in | `guestfish` cannot start its appliance as an unprivileged user: `/boot/vmlinuz-*` is mode 0600 on this host (`supermin exited with error status 1`), which `spikes/2026-10-20-libguestfs-hivex/` had already recorded. The driver was written on a stale assumption | the driver | the media are built with `sfdisk`, `mkfs.vfat --offset` and mtools on a raw file, converted with `qemu-img`; read back the same way (`run2/`: nothing kept, the run never reached the lab) |
| 2 | at the first control, 95 s in, silently | `bin/lib.sh` sets `-e`; the lying-sidecar control did exactly what it should (`bin/shell` returned 1) and the script died without a word. Every row before it had passed, including `verified.cmd` with the truthful sidecar | the driver | `set +e` after sourcing `lib.sh`, with a comment; a guard against reusing a non-empty output directory (`run2/run2-smoke.log`, `run2-hash-on-machine.out`: the hashes by hand up to and including the control's own output, `MISMATCH` and the download deleted) |
| 3 | 46 min, 38 PASS / 8 controls / 10 FAIL | see below: one firmware hang, five test-expectation errors, one driver bug, two toolkit visibility gaps | mixed | `run3/` |
| 4 | 52 min, 44 PASS / 8 controls / 8 FAIL | a second firmware hang (the other reboot), and one driver regex | firmware, the driver | `run4/` |

## Run 3, row by row

**`smoke-ssh` hung at its reboot out of WinPE** (`run3/smoke-ssh-reboot-hang-by-hand.txt`,
`run3/shots/smoke-ssh-211319-deployed.png`). `90-reboot ok`, `ts-done ok`,
then nothing: the display stayed on WinPE's prompt with two lines "The
process cannot access the file because it is being used by another process"
after `90-reboot ...`; the shell loop's last poll was 3 s after `ts-done`;
QEMU `running` at 110 % CPU; `info registers`: CPU#0 at `RIP=7bfe35d3`, the
same 2 s later, CPU#1-3 `HLT=1`; `RIP` is just below TSEG (`7c000000`), the
firmware's reset path. `serial.log` and `disk.qcow2` untouched for 25 min.
`system_reset` from the monitor did not recover it (`shots/smoke-ssh-after-system-reset.png`:
the same frozen screen); `vm-stop --force` + `vm-boot` did: Windows booted
from the disk, `specialize` 30 s later, `deployed` 1 min 41 s later, and
every SSH row then passed. This is `TODO.md`'s "lab VMs sometimes hang at a
guest-initiated reboot", reproduced with registers; the row is a true FAIL.
It cost seven more rows: `bin/await ... deployed` timed out, and the driver
then sat for ever at a bare `wait` (it waited for its own status-monitor
loop too); it was released by hand after the recovery (`kill` of that loop's
PID), which is why the SSH rows have timestamps 25 min after the deploy rows.

**Test-expectation errors** (the machine was right, the row was wrong):

- `17-diskguard on smoke-rdp chose the one fixed disk`: the row expected
  `disk 0:`; WinPE enumerated the SD card as disk 0 (`0|Removable Media|SCSI|8|Generic QEMU! SD Card|not eligible: removable media`)
  and the virtio disk as disk 1, and the guard chose disk 1. The toolkit did
  exactly the right thing; the row now accepts any number and asserts the SD
  line. So: **WinPE does see an SDHCI card as a `Win32_DiskDrive`**, and
  `disks.js` rejects it as removable media [verified].
- `45-winre ... the recovery image verified`, both VMs: `base.wim` carries
  its own `Winre.wim`, so `45-winre` copies that and fetches nothing; there
  was no `msg=` at all. The server's `.winre.wim` is for images captured from
  installed machines. The step now says `Winre.wim from the image itself`
  (a visibility gap: the row could not tell "nothing to verify" from
  "did not run"), and the row accepts either outcome.
- `users on smoke-rdp: helpdesk and bob created`, `post.cmd ... reads its
  marker`, both VMs: the beacons carried `created=helpdesk,bob` and
  `disks=2 markers=1`, but `bin/status` printed only a fixed list of keys
  and dropped them. **`bin/status` now prints every key a beacon carries**,
  the known ones first; the rows read the timeline and pass.
- `carol ... whoami says carol`: PowerShell over SSH answers in CRLF, the
  regex was anchored at `$`. (Run 4 found a second cause, below.)
- `the deploy window's text frame shows the stop`: the frame follows the
  beacon by one loop pass and an upload, 2-4 s; the driver read the frame of
  25 s earlier. Now `bin/console --await`.
- `DEPLOY=remove on smoke-rdp`: `bin/await` counts only events after it
  starts, and `deploy-removed ok` had arrived 15 min earlier while the other
  VM was still being recovered. Now `--from-start` for that one.

**Everything else passed**: the hashes by hand in WinPE (`pdt-sha256.exe`
hashes itself to the recorded `cd096583…`, `curl` fetched `openssl.exe` whose
hash is the recorded `53842107…`, `openssl dgst -sha256` of the 3.5 GB image
equals the sidecar, `pdt-sha256 --check` matches, `verified.cmd` keeps the
file with a truthful sidecar and deletes it with a lying one, `rc=1`),
`bin/keys` typing `deploy 30`, the update pack (`35-updates ok` in 790 s with
the hash in the message), the driver pack, the USB stick and SD card listed
and refused by the guard, both markers read back intact after the installs,
ops and carol over SSH with every refusal, helpdesk and bob over RDP with
every refusal, no RDP on the SSH machine and no SSH on the RDP machine, the
host key fingerprint, the generated passwords uploaded (masked here).

Also seen in run 3: `vm-stop smoke-rdp` (the ACPI button, at the login
screen after `DEPLOY=remove`'s restart) was not honoured within 60 s and
QEMU was ended; in run 4 the same VM powered down within the 60 s. One
instance each way; the final run has a row for it.

## Run 4

Both machines took the update pack (`UPDATES=lcu` on both: 35-updates ran
twice at once, 699 s on `smoke-rdp` and 771 s on `smoke-ssh`, two DISM passes side by side; 790 s alone earlier today), the driver
waited for the stop frame, read every beacon key, and watched the reboot out
of WinPE. **Both VMs came through that reboot.** Then `smoke-rdp` sent
`specialize ok` and never sent `firstlogon`: 31 min later the display was
black (never initialised), CPU#0 busy and moving in the firmware region
(`RIP=7bf8689a`, 2 s later `7bf7c483`), CPU#1-3 halted at `7ad65d71`, serial
and disk untouched since the reboot, QEMU at 137 % CPU
(`run4/smoke-rdp-reboot-hang-by-hand.txt`, `run4/shots/smoke-rdp-222026-hung-after-specialize.png`).
The same forced stop and boot recovered it (first logon 1 min later), the
driver's `deploy-removed` wait caught the restart, and all four RDP rows
passed. The seven `smoke-rdp` FAIL rows are the deploy timeout and the six
timeline rows read before the recovery; the eighth is carol's `whoami`
again, for a new reason: this agent's shell exports a function named `grep`
that runs `ugrep`, whose BRE dialect rejects `\?`; the row is an ERE now,
the same under both.

So, in eight guest-initiated reboots across runs 3 and 4, two hung, once at
each of the two reboots, once on each hardware variant (AHCI + USB stick,
virtio + SD card). `bin/smoke` now watches both reboots (no `specialize`
within 5 min of `ts-done`, no `firstlogon` within 7 min of `specialize`),
records QEMU's registers and recovers the same way; the row stays a FAIL.
Not touched here: the hang itself (`TODO.md`).

## What the toolkit changed because of these runs

- `bin/status`: every beacon key is printed (`created=`, `set=`, `disks=`,
  `markers=`, and whatever a role's post script invents).
- `ts/steps/45-winre.cmd`: `Winre.wim from the image itself (...)` as the
  step message when the image carries one.
- `bin/vm-create --sd-card`, `bin/vm-boot`: an SD card behind `sdhci-pci`.
- `bin/fetch-tools keys`: the lab keys into every role with `SSH=on`
  (`SSHKEYS` and each `keys=<file>` account), not just `lab-apps`.
- The roles `demo-ssh` and `demo-rdp`, with `post.cmd` + `disks.ps1`
  reporting what the installed Windows sees (`disks.txt`, `role-post ok disks=N markers=N`).
