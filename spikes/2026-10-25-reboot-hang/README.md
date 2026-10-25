# 2026-10-25: the firmware reboot hang, bisected as far as it would go

`TODO.md`'s "lab VMs sometimes hang at a guest-initiated reboot": 3 of 10
reboots in the 2026-10-24 smoke runs, 2 of about 10 on 2026-10-22. This
spike built a cheap reproduction harness, ran **147 guest-initiated reboots
under every condition that could be varied in one evening, and saw zero
hangs**, including four more reboots of the one known reproducer, `bin/smoke`
itself. The hang is not reproduced today; it is not explained; but it is
now characterised: the five recorded instances sit at exactly two firmware
sites, both in the CPU bring-up after a warm reset, and a recorder stands
ready to dump the firmware's memory, stack and I/O map the next time it
happens.

Software is the same as on the days it hung: no package changed since
2026-10-06 (`ovmf 2025.11-3ubuntu7.3`, `qemu-system-x86 10.2.1+ds-1ubuntu3.2`,
kernel 7.0.0-38), host up since 2026-10-19.

## What was tried (every row a negative result)

| experiment | reboots | hung | what it varied |
|---|---|---|---|
| `winpe-smm-on/` | 30 | 0 | a `--mode shell` WinPE (virtio disk and NIC, SD card: smoke-rdp's hardware) rebooted by `wpeutil reboot`, 20 s per cycle |
| `winpe-smm-off/` | 30 | 0 | the same with `bin/vm-boot --smm off`: the non-SMM OVMF build on `-machine q35,smm=off`, no secure pflash (new option, for this) |
| `winpe-hostload/` | 30 | 0 | SMM on, under 48 busy threads on the 32-thread host (cycles took 60 s instead of 20) |
| `winpe-idle600/` | 4 | 0 | SMM on, WinPE left idle 10 min before each reboot (uptime) |
| `win/` | 2 + 10 | 0 | a full deployment with the update pack (role demo-ssh, virtio + SD card), its two installer reboots watched, then `shutdown /r /t 0` over SSH ten times |
| `win-hostload/` | 15 | 0 | the same installed Windows, fifteen more reboots under the host hog |
| `pair-w2/`, `pair-w3/` | 2 + 9, 2 + 8 | 0 | two deployments side by side (virtio + SD card, AHCI + USB stick), the smoke's shape, partly under the hog; the SSH reboots counted from the guests' System event logs (`boots-eventlog.txt`: event 1074 then 6005 per reboot), not from the loop, which double-counted one reboot on each (a cycle that saw sshd "back" 7 s after `shutdown /r` was the old session; the next cycle's command hit a machine already going down) |
| `smoke-rerun-1/` | 5 | 0 | `bin/smoke` itself, with `SMOKE_HANG_HOOK` set: 52 PASS, 8 controls, 0 FAIL, 21 min; also the first full run of the `45-winre` message fix and the `20-disk` `override` fix below |
| `smoke-rerun-2..4` | | | three more hooked smoke runs, queued after this README was written; their reports are added here only if one catches a hang |

`detector-control/`: the harness with `HANG_AFTER=1` on a healthy VM, so
the hang path ran end to end (record, force-stop, boot, exit 1) before any
real run. `winpe-idle600-false-hang-driver-bug/`: the first idle run declared
a hang because the driver started its 300 s await *before* the 10 min idle
sleep; the "hung" VM was a freshly rebooted WinPE (kernel address, HLT), the
server log shows the shell loop polling every 2 s until it got the reboot.
Kept because it is exactly the kind of false positive the global rules warn
about; the loop was fixed (`reboot-loop.sh`, the sleep before the await).

## What the recorded hangs are, from the memory layout

The firmware's DXE memory layout is identical across both hardware variants
and across boots (`layout/`: 32 MB of guest memory `0x7a000000..0x7c000000`
dumped 4 s into a boot of each variant with `pmemsave`; the two gzipped
dumps, 13 MB, are not committed, `layout/images.txt` is their `find-module.py`
listing, 193 PE images at the same addresses in both). So the RIPs from the five hang
records can be placed:

| hang | CPU#0 at | module, offset | what the code is | other CPUs |
|---|---|---|---|---|
| 2026-10-22 r8 (AHCI), smoke run 3 smoke-ssh (AHCI + USB stick) | `7bfe35d3` | **CpuMpPei** +0x25d3 | `in eax,dx; ret`: the port read of the ACPI PM timer inside AcpiTimerLib (`imul 0x369e99` = 3579545 Hz and `div 1000000` are right after it), i.e. a `MicroSecondDelay` or timeout loop of the PEI-phase MP init | HLT |
| 2026-10-22 s3, smoke run 4 and run 5 smoke-rdp (virtio + SD card) | `7bf7c483` and `7bf8689a` | **DxeCore** +0x483 and +0xa89a | a walk of the GCD map's linked list (the compare against `0x6d646367` = `'gcdm'`, the GCD entry signature) and the tail of `CoreRestoreTpl` (the `gEfiCurrentTpl` store, the `0x1e` compares): GCD memory-space operations in a loop | `7ad65d71` = **CpuDxe** +0xcd71, `hlt; ret`: the AP park loop; 10-22 also `7ad59266` = CpuDxe +0x266, `sti` |

`layout/*.img` are the three images as loaded (relocated), extracted from
the dumps; `objdump -D -b binary -m i386:x86-64 --adjust-vma=<base>` on them
gives the listings above. Ubuntu's OVMF carries no `.pdb` paths; the names
come from the UI sections of the firmware volume (`find-module.py --extract-fv`
decompresses it, 150 named images).

So: two sites, both the firmware's CPU bring-up after a warm reset, one per
hardware variant, each hit twice or three times at the *same* instruction.
A deterministic state, reached by something the lab did on 2026-10-22 and
2026-10-24 and did not do today. The reporter of
[edk2 #12441](https://github.com/tianocore/edk2/issues/12441) (QEMU 10.2.0,
OVMF 202511, warm reset only, one vCPU spinning at a fixed firmware address,
no serial output, headless only) is very likely looking at the same thing;
no analysis or fix there either.

## Ruled out today (each with the count that rules it out)

- SMM / the Secure-Boot OVMF build: 30 clean with it, 30 clean without.
- The SD card or USB stick as such: both variants clean, in WinPE and installed.
- Host CPU oversubscription: 45 clean reboots under 48 busy threads.
- WinPE uptime to 10 min: 4 clean; installed-Windows uptime up to 30 min: clean.
- A fresh VM versus one that has installed Windows (NVRAM holds Windows's
  boot entry, the disk boots first): 42 clean installed-Windows reboots.
- The installer's own two reboots after a 15-minute WinPE session with the
  update pack applied: 10 clean (three deployments, the smoke rerun).
- Two deployments side by side: clean.

Not varied: the host's other load at those hours (another KVM guest,
`openbios-lab`, was running during this spike too), `-display none` versus a
real display (the upstream report says a display changes it), QEMU and OVMF
versions (nothing older is installed), the time of day.

## The harness, for next time

- `reboot-loop.sh <vm> <n> <out> [vm-boot opts]`: WinPE reboot cycles with
  `HANG_AFTER` (300 s), `IDLE`, `PRE`, `LOAD`; `win-reboot-loop.sh <vm> <n>
  <out> <ssh-port>`: deploy (or `REJOIN=1`, `SKIP_DEPLOY=1`), watch the two
  installer reboots, then SSH reboots. Both use `hang-record.sh`.
- `hang-record.sh`: `record_hang <vm> <label> <out> <why>`: QEMU status,
  registers twice 2 s apart, 48 code bytes at RIP, 2 MB of memory around
  CPU#0's RIP and 128 KB around CPU#1's (`pmemsave`, only for identity-mapped
  addresses under 4 GiB), 64 qwords of CPU#0's stack (the return addresses
  name the callers), `info lapic` for each CPU, `info mtree` (is the PM
  timer's I/O region there?), a screendump.
- `bin/smoke` gained `SMOKE_HANG_HOOK=<exe>`, run as `<vm> <vm>-<label>
  <out>` before it force-stops a hung VM; `smoke-hang-hook.sh` is that hook.
- `find-module.py [--fv <volume>] <dump> <base> <rip>...`: which image, which
  offset. `aggregate.sh`: the table above from every `result.txt`.
- `bin/vm-boot --smm off`: the non-SMM firmware, documented in the script.

Gotchas met: this QEMU has no disassembler (`x /i` says "Asm output not
supported on this arch"), so dump bytes and objdump them; HMP parses an
unquoted `/path` in `pmemsave` as a division, quote it; `bin/await` counts
only events after it starts, so start it after any idle sleep; a loop that
calls sshd "back" must compare boot times, not just see a session.

## Two toolkit findings on the way, both fixed

- `20-disk` on `rh-w2` under the host hog: diskpart's `set id=` on the
  recovery partition, right after `assign letter=R`, failed with "The device
  is in use ... use the OVERRIDE parameter" (`pair-w2-diskpart-race/`, the
  ts.log). `ts/diskpart/uefi-gpt.txt` now says `set id="..." override`;
  verified by the next three deployments and the smoke rerun.
- `bin/vm-stop` (ACPI) at the login screen: the three `rh-w*` machines all
  ignored it for 60 s and were ended by QEMU (`FASTSTARTUP=off`, demo-ssh);
  the smoke rerun's `smoke-rdp` (demo-rdp) powered down within 60 s. Four
  observations each way now across the smoke runs and this spike; the
  difference is not understood (TODO.md).
