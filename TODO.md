# TODO

Ordered; the top item is the next thing to do. Details and rationale live in
`PLAN.md` (§3 target layout, §4 roadmap, §5 open questions). Ideas deliberately
parked are in `DEFERRED.md`, not here.

## Next

- [ ] Phase 5: real hardware over the network via iPXE (the goal): `pxe-lan`
  on the real LAN, machine allow-list gating destructive steps, per-model driver
  packs, Secure Boot, measured PXE→desktop time; one physical model deployed
  repeatably (PLAN.md §4). `pxe-lan` runs dnsmasq with `--log-dhcp`; physical
  debugging is `status`/`logs`, never a screen (PLAN.md §3.2).
  **First machine: a Dell Latitude E5570**, expected the week of 2026-10-13;
  its driver pack and model file are prepared
  (`spikes/2026-10-11-latitude-e5570-prep/`, with the first-boot checklist).
  The remote shell (`bin/shell`), the screen pusher (`bin/screen`) and the
  collector (`docs/COLLECTOR.md`: Linux in RAM, inventory, SSH,
  `pdt-pxe-next`) are in and verified in the lab. The laptop runs Kali today:
  over SSH, read its UUID/MAC, check AMT (`mei-amt-check`), and try to turn
  UEFI PXE on from Linux (`/sys/class/firmware-attributes/`, or Dell's
  `cctk`); after that the collector takes over. See `docs/REMOTE_VISIBILITY.md`.
- [ ] A Samba AD domain controller as a lab service (a Linux VM under
  `bin/lab-netns`, brought up with `serve`/`pxe-lan`), so that domain join
  can be a verified role feature instead of an untested one.

## After that

- [ ] The two-site spike of `REMOTE_SITES.md` §6: two `bin/lab-netns` sites,
  a WireGuard tunnel to the host as origin, one image synced and `lint`ed per
  site, one deploy per site, with the tunnel-down and stale-mirror controls.
  Output: `spikes/<date>-two-sites/` and a `docs/SITE_APPLIANCE.md` runbook
  (Tier A, zero code).

- [x] **Per-user SSH keys and the reference-image check (2026-10-24).**
  `users.txt` takes `name|group|policy|keys=<file>`; `users.ps1` installs the
  file as `C:\ProgramData\ssh\users\<name>\authorized_keys` (Administrators-owned,
  readable by the account) and `sshd_config` lists that path for
  non-administrators; lint, preflight and `60-unattend` know the field; the lab
  role gives `alice` a key of her own (`bin/fetch-tools openssh`, private half
  `build/lab-alice`). Verified with three refusal controls. Two machines
  deployed from one captured `SSH=on` image showed different host keys, and
  different from the reference's. Evidence:
  `spikes/2026-10-24-verified-packs-console-bootorder/`.

## Housekeeping

- [ ] **`bin/shell` command files are run with a plain `cmd /c`** in
  `shell-loop.cmd`, so a command that leaves with `exit /b !errorlevel!` from
  inside a parenthesized block reports exit code 0 (the `cmd` quirk `step.cmd`
  now works around with `cmd /v:on /c "… & exit !errorlevel!"`; see
  `spikes/2026-10-24-verified-packs-console-bootorder/`). One-line commands are unaffected; apply the same wrapper
  when `bin/shell` grows multi-line scripts.
- [ ] **`35-updates` with `--expect`: the success message** now carries the
  package and the pack's hash; the wording changed after the one run that
  exercised that path (build `26100.9550`, 2026-10-24), so the message itself
  has not been seen in a timeline yet [unknown]; the logic around it has.
- [ ] **Lab VMs sometimes hang at a guest-initiated reboot** (QEMU 10.2 host):
  twice on 2026-10-22, once after WinPE's `90-reboot` (PXE-first `r8`) and
  once after Setup's specialize reboot (disk-first `s3`), out of about ten
  reboots that day. Signature: no firmware output on the serial port, the
  display never initialised, vCPUs busy at one address; a monitor
  `system_reset` did not recover `r8`, `vm-stop --force` + `vm-boot` did and
  the guest carried on. Not seen on the previous QEMU (Phase 3, 2026-10-02).
  `spikes/2026-10-21-local-diskguard-ssh/` has both records. If it keeps
  happening: bisect QEMU 10.2 / OVMF / `-machine q35,smm=on`; `bin/await`
  cannot tell it from a slow boot, so a stuck VM looks like silence.
  2026-10-24, the TODO/DEFERRED session: eight VMs, ten guest-initiated
  reboots or shutdowns (WinPE `90-reboot` ×7, a sysprep shutdown, two
  specialize reboots counted once each), none hung.
  **2026-10-24, `bin/smoke` run 3: reproduced**, a third signature. `smoke-ssh`
  (AHCI disk + a USB stick on xHCI, resumed with `deploy 30` typed by
  `bin/keys`) sent `90-reboot ok` and `ts-done ok`, then nothing: the display
  stayed on WinPE's prompt (two "The process cannot access the file because
  it is being used by another process" lines after `90-reboot ...`, from the
  shutdown), the shell loop's last poll was 3 s after `ts-done`, QEMU said
  `running` at 110 % CPU, `info registers`: CPU#0 at `RIP=7bfe35d3` (just
  below TSEG at `7c000000`, i.e. the firmware's SMM-adjacent reset path),
  CPU#1-3 `HLT=1`, the same 2 s later; no serial output, `disk.qcow2` and
  `serial.log` untouched for 25 min. `system_reset` did not recover it
  (display and disk unchanged 20 s later); `vm-stop --force` + `vm-boot`
  did: Windows booted from the disk, `specialize` 30 s later, `deployed`
  at +1 min 41 s. Evidence: `spikes/2026-10-24-smoke-earlier-runs/run3/
  smoke-ssh-reboot-hang-by-hand.txt` and `shots/`. The other VM of the same
  run (`smoke-rdp`, virtio, an SD card) rebooted fine.
  **Run 4, the other reboot:** `smoke-rdp` (virtio disk and NIC, SD card)
  came through WinPE's reboot, sent `specialize ok`, and never sent
  `firstlogon`: 31 min later the display was black (never initialised),
  CPU#0 busy and moving (`RIP=7bf8689a`, then `7bf7c483`: the firmware
  region, not one spot), CPU#1-3 halted at `7ad65d71`, serial and disk
  untouched since the reboot, QEMU at 137 % CPU. The same forced stop and
  boot recovered it (first logon 1 min later). `smoke-ssh` of that run came
  through both reboots (`spikes/2026-10-24-smoke-earlier-runs/run4/smoke-rdp-reboot-hang-by-hand.txt`).
  **Run 5:** `smoke-rdp` again, this time at the reboot out of WinPE, with
  the *same* registers as run 4 (CPU#0 `RIP=7bf7c483`, CPU#1-3 halted at
  `7ad65d71`): a reproducible firmware state, not noise. `bin/smoke`'s
  watcher caught it at 300 s and recovered it unattended
  (`spikes/2026-10-24-smoke/smoke-rdp-reboot-hang.txt`). Score for
  guest-initiated reboots in the smoke runs: 3 hung of 10; the virtio + SD
  card VM hung twice, the AHCI + USB stick VM once.
  **2026-10-25, bisection (`spikes/2026-10-25-reboot-hang/`): 147 guest-initiated
  reboots, 0 hung**, same QEMU/OVMF/kernel as on the hang days: fresh WinPE
  30× with SMM on and 30× with the non-SMM OVMF (`bin/vm-boot --smm off`,
  new), 30× under a 48-thread host CPU hog, 4× after 10 min idle; three full
  deployments with the update pack (six installer reboots watched), 42 reboots
  of the installed Windows over SSH (counted from the guests' event logs), two
  deployments side by side, and `bin/smoke` itself again (5 reboots, 0 FAIL).
  So SMM, the removable media, host load, uptime and the install context are
  each ruled out on their own; the trigger is something those two days had
  and this one did not (unknown). What the five records *are*: the firmware's
  memory layout is deterministic, so their RIPs map to modules: the AHCI-variant
  hangs (10-22 r8, smoke run 3) are at the same `in eax,dx` of the ACPI PM
  timer read in **CpuMpPei** (a PEI MP-init delay/timeout loop); the
  virtio-variant hangs (10-22 s3, runs 4 and 5) alternate between the GCD
  map walk and `CoreRestoreTpl` in **DxeCore** with the APs in CpuDxe's halt
  loop. Likely the same as edk2 issue #12441 (QEMU 10.2, OVMF 202511, warm
  reset only, headless). Next time it happens: `bin/smoke` with
  `SMOKE_HANG_HOOK=spikes/2026-10-25-reboot-hang/smoke-hang-hook.sh` (or the
  spike's loops) dumps memory, stack, lapics and the I/O map before recovery;
  `find-module.py` names the frames. Untried: a real display instead of
  `-display none` (the upstream report says it matters), an older QEMU.
  `bin/smoke` now watches for it (no `specialize` within 5 min of `ts-done`),
  records QEMU's registers and recovers the same way; the row is a FAIL.
  **2026-10-25 03:00, caught with the recorder armed** (smoke rerun 3,
  `smoke-ssh`, AHCI variant, the reboot out of WinPE; `spikes/2026-10-25-reboot-hang/smoke-rerun-3/`,
  README section "Caught"): CPU#0 is in CpuMpPei's `TimedWaitForApFinish`
  with all 3 APs finished, waiting for **31** APs with a **71.6-minute**
  (`MAX_UINT32` µs) time limit: `PcdCpuBootLogicalProcessorNumber` (PEI PCD
  token 0x11, 4 on a healthy boot) read **32** at that warm reset. OVMF's
  PlatformPei derives it from fw_cfg `nb_cpus` and the CPU-hotplug register
  block at I/O 0xcd8 (`-smp 4`: four slots, so the block alone cannot say
  32); which input lied is open. Predicted, not yet observed: the VM boots
  by itself about 72 min after the reboot (untested). **Reruns 5 and 6 caught
  the other (DXE) variant with memory**, on the AHCI machine: PciHostBridgeDxe
  loops for ever in `AddMemoryMappedIoSpace`'s ASSERT-only verification loop
  because PlatformPei computed the 64-bit PCI aperture base as garbage
  (`0x800b201000000000`, `0xb00006e800000000`; healthy `0x380000000000`),
  from an `etc/e820` end-of-RAM candidate that was wrong during the boot's
  first e820 scan only; every other field of the HOB list is healthy. So
  both variants are one fault: a fw_cfg value PlatformPei reads at a warm
  reset comes back wrong now and then (cold boots hide it: zeroed RAM is
  harmless in both places). OVMF 2025.11 reads fw_cfg through the cache
  added in edk2 on 2025-03-20 (`QemuFwCfgCache.c`; a failed cached read
  leaves the caller's buffer untouched); OVMF 2024.11 has no cache. **Result
  of the firmware comparison (same smoke, same QEMU): 2025.11 3 hangs in 8
  runs / 80 reboots; 2024.11 (`VM_BOOT_FIRMWARE`, reruns 9-12) 0 in 4 runs /
  40 reboots.** Chance of 40 clean reboots at the new firmware's rate is
  about 0.22, so suggestive, not proof. Next: more 2024.11 runs or a 2025.11
  build with the cache compiled out; then upstream (edk2 #12441) with the
  dumps and the table.
- [ ] `bin/vm-stop` (the ACPI button) at an installed Windows's login screen
  is honoured within 60 s sometimes and ignored sometimes: smoke run 3 ignored,
  runs 4-5 and the 2026-10-25 reruns 1, 2, 4, 7-12 honoured, reruns 3, 5 and 6 ignored (all
  `demo-rdp`); the three `demo-ssh` machines of the 2026-10-25 reboot spike
  all ignored it and were ended by QEMU. Both roles have `FASTSTARTUP=off`. Not understood; `--full`
  (typed `shutdown /s`) is the reliable way. Lead, untested: the three ignoring
  runs are exactly the three in which the other machine hung and was recorded,
  so `smoke-rdp` sat at its login screen 20-40 min longer than usual; an idle
  login screen (display off, lock-screen timer) that stops honouring the power
  button would couple the two items.
- [ ] Real hardware has still seen none of this (Phase 5). In particular:
  enrolling the Secure Boot certificate in real firmware, and proxy-DHCP on a
  real switch next to a real router. (A bridge on the real host, and
  `bin/lab-netns` on a host that restricts user namespaces, were both verified
  on 2026-10-02 with root supplied by hand.)
- [ ] `bin/fetch-iso` has been run for 24H2 and 25H2, professional, en-us. Other
  editions and languages are untested.
- [ ] `http/unattend/default.xml` ships a blank-password local admin (`deploy`)
  for the lab; a role's `USERS` list re-passwords it at first logon, creates
  the real accounts, and `DEPLOY=remove` deletes it at the next boot (the
  lab role does all three). Still open: domain join (needs the Samba AD lab
  service above).
- [ ] Ports 8080 and 8088 are taken on this host by other software; `config.sh`
  here uses 8090.

## Done

- [x] **Every download verified, the console as text, the second-disk boot
  order (2026-10-24).** `ts/verified.cmd` behind `25-download`, `35-updates`,
  `40-drivers` and `45-winre` (sidecars with `sha256` for every pack and
  recovery image: `pack-* --rehash`, `stage-image --sidecars`; lint demands
  them, self-test 56/56); the controls found `45-winre` reporting `ok` after a
  mismatch, which led to the `cmd` quirk (`exit /b !errorlevel!` inside a
  parenthesized block exits the process with 0) and the `step.cmd` wrapper that
  ends it. The two-disk re-image loop was the lab's: `vm-boot` now gives the
  second disk a boot index and keeps the NVRAM once any disk has data; `50-boot`
  records the firmware's order and says whether Windows leads it (`bcdedit
  /enum firmware`; `bcdboot` puts it first, [read] and seen on OVMF; real
  firmware still [unknown]). `tools/pdt-console.exe` + `bin/console` + `bin/keys`
  (DEFERRED's spike, done). Evidence: `spikes/2026-10-24-verified-packs-console-bootorder/`.
- [x] **Local-boot handoff, disk guard, `SSH=on`, RDP credentials (2026-10-22).**
  `bin/netboot <m> local` (iPXE exits, the firmware boots the disk; two
  defects found and fixed in the embedded chainloader: it fell into `:failed`
  after a chain that returned, and it must return an *error* or edk2 shows
  its boot menu instead of trying the next entry; `lint` reads the binary for
  it). `17-diskguard` + `DISK=<n>` + `select disk @DISK@` (refuses to guess
  among several fixed disks, never picks USB or removable or < 32 GiB; verified
  on one-, two- and three-disk VMs, nothing wiped on a refusal). `SSH=on` +
  `SSHKEYS` (Win32-OpenSSH MSI pinned by `fetch-tools openssh`, key-only,
  `ssh` from this host, host-key fingerprint reported). `xfreerdp /auth-only`:
  right password accepted, wrong one, unknown and deleted accounts refused.
  winget now installs machine-wide first (a per-user install vanished with
  the `deploy` profile). Evidence: `spikes/2026-10-21-local-diskguard-ssh/`.
- [x] **Phase 3 (2026-10-02): post-install roles.** `ROLE=` → `http/roles/<name>/`
  (winget apps from packages pinned and served by `fetch-tools winget`, a post
  script, an unattend, `FASTSTARTUP=off`), checked by preflight and `lint`;
  `deployed` verdict; the every-boot probe with two triggers (which fires when,
  measured); a reference machine carries its role into the image and the
  sidecar records it. Evidence: `spikes/2026-10-02-phase3-roles/`.
- [x] **With root supplied by hand (2026-10-02):** a bridge on the real host
  with dnsmasq started under sudo (two deploys, a negative control, one bug
  fixed in `pxe-lan`), and `bin/lab-netns` under the user-namespace
  restriction with its generated AppArmor profile (a deploy inside).
- [x] **The "not verified" list (2026-10-02).** Update packs with several
  package types and the 25H2 combination; a generalized role image captured in
  WinPE and on Linux (`bin/capture-image`) and deployed as new machines;
  WinPE-side drivers via `drvload` (fully virtio VM); firmware PXE without an
  option ROM; Secure Boot enforcing with a signed `ipxe.efi`; proxy-DHCP beside
  another DHCP server; winget bootstrap at first logon; why the boot task never
  fired. Evidence: `spikes/2026-10-02-unverified-items/`.

- [x] **Phase 2 (2026-10-02): step-based task sequence.** Runner + fetched
  steps (`deploy NN` resumes without a reboot), `env.cmd`, `STOP_BEFORE` /
  `STOP_AFTER`, sequences per MODE, per-model defaults that cannot set MODE,
  the required recovery partition with a first-logon WinRE check, update packs
  (a 26100.1 image deployed at 26100.9550), capture mode, live log push, steps
  in child processes, and a `lint` that knows which programs WinPE has.
  Evidence: `spikes/2026-10-02-phase2-acceptance/`.

- [x] **Phase 1 (2026-10-02): modular `bin/` + `http/` layout.** 7z extraction
  (no sudo), pristine `boot.wim` with wimboot injection, pinned tools, `serve`
  with beacons / uploads / identity hand-off, the §3.2 beacon contract and log
  push in `deploy.cmd`, `lint` / `status` / `await` / `logs`, lab VM scripts,
  v1 retired to `docs/history/v1-setup-exe/`. Verified end to end in lab VMs,
  with negative controls; evidence in `README.md` "Verification".
  Pulled forward from later phases: `MODE` gating (default `shell`), a
  `preflight` step before anything destructive, `specialize`/`firstlogon`
  beacons and Panther log upload from the installed OS.
- [x] **Bridged networking tested (2026-10-02)** in a rootless network
  namespace (`bin/lab-netns`): `vm-create --net bridge:`, `pxe-lan --bridge`
  (real DHCP + TFTP), full deploy, with a no-dnsmasq negative control.
  Evidence: `spikes/2026-10-02-bridged-lab-netns/`.
- [x] **ISO builder ported (2026-10-02)** as `bin/fetch-iso` (UUP dump); a VM
  was deployed from the ISO it built.
