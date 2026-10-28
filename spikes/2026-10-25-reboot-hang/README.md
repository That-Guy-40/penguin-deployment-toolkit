# 2026-10-25: the firmware reboot hang, bisected as far as it would go

`TODO.md`'s "lab VMs sometimes hang at a guest-initiated reboot": 3 of 10
reboots in the 2026-10-24 smoke runs, 2 of about 10 on 2026-10-22. This
spike built a cheap reproduction harness, ran **147 guest-initiated reboots
under every condition that could be varied in one evening, and saw zero
hangs**; then the hooked `bin/smoke` reruns **caught three, with the
recorder armed** (reruns 3, 5 and 6; 272 reboots in all, 3 hung, none of
them on OVMF 2024.11). The
dumps say what the firmware is doing in each of the two variants, down to
the instruction and the wrong number that drives it:

- **PEI variant** (rerun 3): CpuMpPei is **waiting 71.6 minutes for 28 CPUs
  that do not exist**, because the boot-CPU count the firmware read at that
  warm reset was 32 instead of 4.
- **DXE variant** (reruns 5 and 6, both captured with memory): PciHostBridgeDxe
  is **looping for ever** verifying a 64-bit PCI aperture that PlatformPei
  placed at a garbage address (`0x800b201000000000`, then
  `0xb00006e800000000`) outside the 46-bit address space, in a RELEASE-build
  loop whose only error check is an `ASSERT`.

Both numbers are values OVMF's PlatformPei derives from fw_cfg at a warm
reset; everything else in the hung firmware's state (HOB list, memory map,
e820-derived ranges, CPU PCDs, QEMU's trace of every fw_cfg and CPU-hotplug
access) is identical to a healthy boot. OVMF 2025.11 reads fw_cfg through a
cache that is new in 2025 (`QemuFwCfgCache.c`, 2025-03-20); OVMF 2024.11,
the last release without it, reads `etc/e820` eight times per boot where
2025.11 reads it once. Whether the old firmware also hangs is the
experiment in progress (sections "Caught" and "What is left").

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

## Caught: smoke rerun 3, what the firmware is waiting for

`smoke-rerun-3/`: `smoke-ssh` (e1000e, AHCI disk, USB stick; the variant
of 10-22 r8 and smoke run 3) sent `ts-done ok` at 02:28:40 and nothing for
300 s; the hook recorded it at 02:33:40 (`hang-smoke-ssh-reboot-1.txt`, the
2 MB dump `-bsp-7be00000.bin.gz`, the stack, lapics, `-mtree.txt`, `.png`),
then `bin/smoke` force-stopped it and the run finished (50 PASS, 8 controls,
2 FAIL: this hang and `smoke-rdp` ignoring the ACPI button at its login
screen). What the dump shows [verified, every number from the dump or the
registers]:

- CPU#0 at `7bfe35d3` in both samples, the `ret` right after the `in eax,dx`
  of AcpiTimerLib's PM-timer read (port `0x608`), the same instruction as the
  two earlier AHCI records; the return addresses on its stack place it in
  **CpuMpPei** `TimedWaitForApFinish` (`+0x274e`), the loop that compares
  `FinishedCount` (`[rbx+0xa8]`) against the limit in `r13d` and calls
  `CheckTimeout`. CPU#1-3 at `7bfeb951`, `hlt; ret`: finished APs, parked.
- Its `CPU_MP_DATA` at `7bfd8388`: `FinishedCount = 3` (all three real APs
  checked in), the limit `r13d = 0x1f = 31`, `ExpectedTime = 15374028705`
  PM-timer ticks = `0xffffffff` µs = **71.6 minutes**, `TotalTime = 297 s`
  when captured.
- The caller (`CpuMpPei+0x6d04..0x6d22`): `mov ecx,0x11; call PcdGet32;
  mov edx,0xffffffff; lea esi,[rax-1]; call TimedWaitForApFinish`: the limit
  is `PcdGet32(token 0x11) - 1`, so **that PCD read 32** at this reset.
- Which PCD: the PEI PCD database of this firmware (`pcd-db.py`,
  `pcd-db.out`: parsed out of the decompressed volume and out of a healthy
  boot's memory) has 32 local tokens; token `0x11` defaults to **0** and
  token `0x12` to **64**, the DSC's `PcdCpuBootLogicalProcessorNumber|0` and
  `PcdCpuMaxLogicalProcessorNumber|64`; on a healthy boot both read **4**.
  MpInitLib's `WakeUpAP` [read, edk2-stable202511] waits for
  `PcdCpuBootLogicalProcessorNumber - 1` APs with a `MAX_UINT32` time limit
  ("approx. 71 minutes") exactly when that PCD is non-zero; the immediate
  `0xffffffff` in the caller is that branch. So the firmware believed the
  machine booted with 32 CPUs, saw 3 APs arrive, and sat down to wait for
  the other 28.

Where the count comes from [read, OvmfPkg/Library/PlatformInitLib/Platform.c
at edk2-stable202511; Ubuntu's PlatformPei carries this code,
`platformpei-ports.out`]: `PlatformMaxCpuCountInitialization` reads
`BootCpuCount` as a 16-bit value from fw_cfg item 5 (`nb_cpus`), then probes
QEMU's CPU-hotplug register block at I/O `0xcd8` (Q35): selector 0, command
0, read `CMD_DATA2`; if that is not 0 the block is "unavailable" and
`BootCpuCount` is used as read; otherwise it walks the selectors counting
present CPUs and `PlatformCpuCountBugCheck` *replaces* `BootCpuCount` with
the count it found whenever the two differ. QEMU 10.2 [read, hw/acpi/cpu.c]
gives the block one slot per possible CPU (`-smp 4`, no `maxcpus`: four) and
answers 0 to every read with a selector past the end. So with this QEMU the
probe cannot count more than 4, and a `BootCpuCount` of 32 needs **both** a
fw_cfg read of 32 and a non-zero `CMD_DATA2`, two I/O answers wrong at the
same reset; or a path not in this code. That is the open question, and it
is a QEMU/OVMF question, not a toolkit one. The trace of a healthy cold
boot and warm reboot (`qemu-trace-baseline-rh-base.log`, `bin/vm-boot` with
`QEMU_TRACE='fw_cfg_select,fw_cfg_read,cpuhp_acpi_*'`) shows the expected
sequence both times: `fw_cfg_select key 0x0005 'nb_cpus'`, then
`cpuhp_acpi_write_idx 0`, `write_cmd 0`, `read_cmd_data2 0`, `read_flags`
`0x1` for selectors 0-3, selector 4 answered by nothing. The fw_cfg *value*
is read by DMA and QEMU does not trace it; the probe's answers are all
there. Reruns 5-8 (queued at 03:14 with the trace, the hook and
`SMOKE_HANG_WAIT=4800`) will show which of the two inputs lied, if it
happens again.

One consequence for the lab: **the PEI-variant "hang" should end by
itself after 71.6 minutes** (the firmware then carries on with the 4 CPUs
it found); every recorded instance was force-stopped between 5 and 31
minutes in, so this has never been observed [unknown].
`smoke-hang-hook.sh` with `SMOKE_HANG_WAIT=<s>` now leaves a hung VM alone
and looks once a minute (`hang-record.sh` `wait_for_self_recovery`,
`hang-<label>-wait.txt`). Its first version had a wrong check and reported
rerun 5's hang as "recovered" after 60 s (the monitor prints RIP as 16
zero-padded digits; a length test passed its hand-typed control and failed
the real string); the fixed version's controls are in
`wait-helper-control.out`: a live VM is "recovered" at the first look,
`000000007ad5926e` is not. The wait is only worth it for this variant: the
DXE variant below is a loop with no exit condition, so from rerun 7 on the
hook waits only when the recorded RIP is inside CpuMpPei
(`SMOKE_HANG_WAIT_RIP`, controls appended to the same file) and writes a
one-line "not waited for, UNKNOWN" wait file otherwise. Rerun 6's DXE hang
had been waited on for 2400 s (still looping, as it must) when that wait
was cut short by hand (`smoke-rerun-6/hang-smoke-ssh-reboot-1-wait.txt`).

## Caught again, the other variant: reruns 5 and 6

Rerun 5 (`smoke-rerun-5/`, QEMU trace on): `smoke-ssh` again, the AHCI
variant, this time at Setup's reboot after `specialize` (03:32:48; recorded
03:39:45). CPU#0 at `7bf7c4b1`, then `7ad5926e`, `7ad59267`, `7bf7ce3e`,
`7bf7c483` on later looks: moving, `HLT=0`; CPU#1-3 at `7ad65d71` (CpuDxe
`hlt; ret`). The same registers as the three earlier DXE-variant records,
which were all on the virtio machine; so the variant is not tied to the
hardware. Rerun 6 (`smoke-rerun-6/`) caught the same thing at the reboot out
of WinPE (04:01:18; recorded 04:06:13), with the recorder now dumping the
whole PEI/DXE region (80 MB from `0x77000000`). What the dumps show
[verified, from the dumps, the registers and the stack]:

- The loop. CPU#0's stack holds the return address `7ad1286b` =
  **PciHostBridgeDxe** `+0x386b` (`pcihostbridge-addmmio-loop.out`: the
  image from the healthy layout dump, disassembled): the call just before it
  is `gDS->GetMemorySpaceDescriptor` in `AddMemoryMappedIoSpace`'s closing
  loop, `for (CheckBase = Base; CheckBase < Base + Length; CheckBase =
  Descriptor.BaseAddress + Descriptor.Length)`, whose status check is
  `ASSERT_EFI_ERROR` only [read, MdeModulePkg PciHostBridge.c at
  edk2-stable202511] and so compiled out of this RELEASE build. The search
  the BSP is in (`7bf7c4b1`, DxeCore `CoreSearchGcdMapEntry`) asks for
  address `RDI = 0x400000000000` with length 1: the first byte **past the
  end of the GCD map** (the healthy map's last entry ends at
  `0x3fffffffffff`: a 46-bit address space, `layout/hob-list-healthy.out`,
  `PhysMemAddressWidth = 0x2e`). That lookup fails, `Descriptor` keeps its
  previous value, `CheckBase` stays `0x400000000000`, and the loop never
  ends. Every sampled RIP of this variant (the GCD walk, `CoreRestoreTpl`,
  CpuDxe's `sti` in `CpuEnableInterrupt`) is inside that one call.
- The aperture. `R14` points at the root bridge's `MemAbove4G` aperture
  (`smoke-rerun-5/aperture-from-dump.out`): `Base = 0x800b201000000000`,
  `Limit = 0x800b2017ffffffff` (32 GiB, OVMF's classic default size) where a
  healthy boot has `0x380000000000..0x3fffffffffff` (8 TiB, the dynamic
  window at the top of the 46-bit space). Rerun 6's PlatformInfoHob has
  `PcdPciMmio64Base = 0xb00006e800000000`, size 32 GiB. With a base outside
  the address space, `Base + Length` can never be reached by a `CheckBase`
  that stops at the map's end.
- Everything else is healthy. Rerun 6's dump holds the PEI HOB list
  (`0x77f7e000`) and DXE's copy: `FirstNonAddress = 0x400000000000`,
  `PhysMemAddressWidth = 46`, `Uc32Base/Size`, all 16 resource HOBs (the
  e820-derived RAM ranges), the PCD database (`PcdCpuBootLogicalProcessorNumber
  = 4`, `PcdCpuMaxLogicalProcessorNumber = 4`) are byte-for-byte those of
  the healthy boot; the 64-bit aperture base is the only wrong field. The
  QEMU trace of the hung reset (`hang-*-qemu-trace.log`) has the same
  sequence of fw_cfg selects and DMA transfers as a healthy reset, and the
  CPU-hotplug probe answered 4 present CPUs both times.

Where that base comes from [read, OvmfPkg PlatformInitLib MemDetect.c at
edk2-stable202511]: `PlatformGetFirstNonAddress` scans `etc/e820` for the
end of RAM (6 GiB here), aligns it to the 32 GiB default aperture size, and
stores it as `PcdPciMmio64Base`; `PlatformAddressWidthFromCpuid` then sets
`FirstNonAddress = 2^46`; `PlatformDynamicMmioWindow` moves the aperture to
the top of the address space **only if** `PcdPciMmio64Base + 8 TiB` fits
below `2^46`, otherwise it keeps the classic base and size. The hung
values are exactly "classic base kept, because the base was garbage", and
the garbage base is `ALIGN_VALUE(FirstNonAddress, 32 GiB)` for a
`FirstNonAddress` that was garbage *at that moment* (the e820 end-of-RAM
candidate, `BaseAddr + Length` of an entry) and was overwritten by `2^46` a
few lines later, which is why the HOB shows a sane `FirstNonAddress`. The
e820 data itself was fine when it was scanned again for the resource HOBs.

So both variants are one fault: **a value PlatformPei reads from fw_cfg
comes back wrong once in a while at a warm reset**: the 16-bit `nb_cpus`
(rerun 3: 32 instead of 4) and an `etc/e820` entry during the first of the
boot's several e820 scans (reruns 5 and 6). Cold boots would not show it:
unwritten RAM is zero, and a zero in either place is harmless (`BootCpuCount
== 0` takes the 50 ms timeout path; a zero e820 end is below 4 GiB). That
is also what the upstream reporter saw ("warm reset only").

Why it is sometimes wrong is not established. Two facts point at the new
fw_cfg cache [read, OvmfPkg/Library/QemuFwCfgLib/QemuFwCfgCache*.c,
added 2025-03-20, so in edk2-stable202505 and later, not in 202502]:
PlatformPei's first act is `QemuFwCfgInitCache`, which reads the file
directory, `etc/e820`, `etc/system-states`, the boot menu flag and
`bootorder` into GUID HOBs; every later `QemuFwCfgReadBytes` of those items
is served from the HOB, and a cached read that fails (`RETURN_NOT_READY`,
`RETURN_ABORTED` past the item's end, `RETURN_NOT_FOUND`) **returns without
touching the caller's buffer** (`InternalQemuFwCfgReadBytes` ignores its
status). The trace matches that list exactly: a 2025.11 boot selects
`signature, id, file_dir, e820, system-states, boot_menu, bootorder` once
each and then `nb_cpus`; a 2024.11 boot of the same VM selects `etc/e820`
eight times and `file_dir` 38 times (`fw-cfg-items.out`,
`qemu-trace-ovmf-2024.11-rh-base.log`, `ovmf-2024.11.txt`). `nb_cpus` is
not a cached item, so the cache alone does not explain rerun 3; what the
two reads share is `InternalQemuFwCfgReadBytes` choosing between the cache
and DMA by the work area's `Reading` flag. Hypothesis, not a finding.

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
- The hooked `bin/smoke` reruns on OVMF 2025.11 (`smoke-rerun-1..8`, 80
  guest-initiated reboots): reruns 1, 2, 4, 7 and 8 clean (52 PASS, 8
  controls, 0 FAIL each), reruns 3, 5 and 6 each with one captured hang (and
  `smoke-rdp` ignoring the ACPI button at its login screen in those same
  three). 272 reboots this spike (147 harness + 80 smoke on 2025.11 + 5 + 40
  on 2024.11), 3 hung, all three on `smoke-ssh` (e1000e + AHCI + USB stick)
  during a smoke run on 2025.11.

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
- `bin/vm-boot` with `QEMU_TRACE=<events>` in the environment: QEMU's own
  trace events to `vms/<vm>/qemu-trace.log`; `record_hang` copies it to
  `hang-<label>-qemu-trace.log`. The reruns use
  `'fw_cfg_select,fw_cfg_read,cpuhp_acpi_*'` (about 470 lines per firmware
  run, nothing while Windows runs).
- `smoke-hang-hook.sh` with `SMOKE_HANG_WAIT=<s>`: wait for the firmware to
  move on by itself before `bin/smoke` recovers the VM (above).
- `pcd-db.py <dump|volume> <base>...`: the PCD databases and their UINT32
  tokens around `0x11`, for naming what `PcdGet32` returned.
- `record_hang` dumps 80 MB from `0x77000000` when the RIP is in the
  firmware region: the PEI HOB list (`0x77f7e000`: PlatformInfoHob, the PCD
  database, every resource HOB), DXE's copy of it, the GCD map, every DXE
  image and the pool. `layout/hob-list-healthy.out` is the healthy
  reference; the parsers used are in this README's history (the Python in
  the session log), `pcd-db.py` is the one kept.
- `bin/vm-boot --firmware <OVMF_CODE file>`, or `VM_BOOT_FIRMWARE=<file>` in
  the environment (reaches the vm-boot calls inside `bin/smoke` and the hang
  hook's recovery): boot from another firmware build; `ovmf-2024.11.txt`
  records which one was used and where it came from (not vendored). The
  status line prints the full path then, because the old and the installed
  file share a basename; `vm-boot-firmware-env-control.out` shows the env
  var reaching QEMU's pflash unit 0 and the unset case not.

## What is left

- Firmware comparison, same `bin/smoke`, same hook, same QEMU
  (`smoke-reruns.log`; each run is two installs, 10 guest-initiated reboots):

  | firmware | smoke runs | reboots | hangs | runs |
  |---|---|---|---|---|
  | OVMF 2025.11-3ubuntu7.3 (fw_cfg cache) | 8 | 80 | 3 | reruns 1-8 (hangs in 3, 5, 6) |
  | OVMF 2024.11-3 (no cache) | 4 | 40 | 0 | reruns 9-12, all 52 PASS / 8 controls / 0 FAIL |

  The old firmware was confirmed in QEMU's command line for both VMs of
  rerun 9 (`smoke-rerun-9/boot.out`, full path in vm-boot's line) and its
  WinPE loop (`winpe-ovmf-2024.11/`, 5 of 5, `etc/e820` read 8 times per
  firmware run, so no cache). What the numbers are worth: at 2025.11's
  observed rate (3 in 80 reboots), 40 clean reboots happen about one time in
  five by chance (0.217; per run, (5/8)^4 = 0.15). Suggestive, consistent
  with the cache hypothesis, **not proof**. More old-firmware runs would
  sharpen it at 22 minutes each; a firmware built with the cache disabled
  on the 2025.11 base is the clean bisection, and it is prepared in
  `ovmf-nocache/`: Ubuntu's source package (hashes from its `.dsc`), a
  5-line patch that makes the cache's select and read checks return FALSE,
  the build script with debian/rules' Secure Boot flags, and the alternating
  smoke schedule. Both images built on 2026-10-27 (`ovmf-nocache/builds.txt`,
  both boot WinPE, the nocache one reads `etc/e820` 9 times per run:
  `objdump-check.out`), and the eight alternating smoke runs started at 18:27
  (`smoke-reruns.log`, `smoke-{nocache,stock}-<n>/`). So far: `smoke-nocache-1`
  52 PASS / 0 FAIL; `smoke-stock-1` lost `smoke-rdp` at the restart after
  `deploy-remove` (no `deploy-removed` beacon, a black screen 12 min later,
  SSH banner timeouts, the ACPI button ignored, forced stop): the hang
  signature at the *third* guest-initiated reboot, which `bin/smoke` did not
  watch, so no hook ran and no dump exists; which variant it was is
  [unknown]. `bin/smoke` now records, hooks and recovers that reboot too
  (`reboot-3`), from `smoke-stock-2` on. The table above is updated when the
  queue ends.
- Side observation, untested: the `smoke-rdp` machine ignored the ACPI
  button at its login screen in exactly the three runs where the other
  machine hung (reruns 3, 5, 6) and in none of the nine clean runs. In those
  runs it sat at the login screen for 20-40 minutes longer while the hung
  machine was recorded; an idle login screen that stops honouring the
  power button (screen off, or the lock screen's own timer) would explain
  both TODO items' coupling. `TODO.md`.
- Upstream next: edk2 #12441 has the symptom and no analysis; the two
  dumps, the trace, the aperture values and this table are what a report
  needs. If the cache is cleared, the fault is below the firmware (QEMU's
  fw_cfg DMA or KVM) and QEMU is next.
- The 71.6-minute self-recovery of the PEI variant: `SMOKE_HANG_WAIT=4800`
  is armed for CpuMpPei RIPs only; rerun 6's DXE-variant hang was still
  looping after 40 minutes, as the analysis says it must, and was not waited
  out.
- Upstream: edk2 #12441 has the symptom and no analysis; the two dumps, the
  trace and the aperture values are what a report needs.

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
  the smoke reruns' `smoke-rdp` (demo-rdp) powered down within 60 s in
  reruns 1, 2 and 4 and ignored it in rerun 3. Five ignored, five honoured
  now across the smoke runs and this spike, both roles on both sides; the
  difference is not understood (TODO.md).
