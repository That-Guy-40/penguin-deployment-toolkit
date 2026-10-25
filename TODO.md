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
- [ ] Per-user SSH keys for `Users` accounts (`SSH=on` serves the Administrators
  through `administrators_authorized_keys` only), and the reference-image
  check for `SSH=on`: two machines deployed from one captured image must show
  different host keys (`prepare-capture.cmd` removes them before sysprep;
  not yet exercised).

## Housekeeping

- [ ] **Verify driver and update packs on the machine too.** Since 2026-10-24
  `25-download` checks the OS image's SHA-256 against its sidecar with
  `tools/pdt-sha256.exe`, and `bin/pack-drivers` / `bin/pack-updates` write a
  `sha256` into their sidecars; `35-updates` and `40-drivers` do not check it
  yet, and packs made before that date carry none (re-pack them first). The
  separate `images/<name>.winre.wim` that `45-winre` fetches has no sidecar at
  all. Same mechanism, three more call sites; make lint demand the hash once
  the steps do (`spikes/2026-10-24-sha256-and-dism/`).
- [ ] **A `DISK=<n>` install on a disk the firmware does not boot first re-images
  itself** (seen 2026-10-24, demo for Noah): a two-disk lab VM deployed onto
  disk 1 with disk 0 left blank; at `90-reboot` the firmware tried disk 0
  (nothing), then the network, and the task sequence ran again, wiping disk 1
  (`MODE=deploy` was still set, as it is after every deploy). `bin/netboot <m>
  local` stops the loop, and the machine then boots from disk 1, but only after
  the firmware has timed out every network entry (several minutes per boot on
  OVMF). Options: have `90-reboot` or `50-boot` warn when the chosen disk is not
  disk 0; document that a multi-disk machine needs its boot order set (or the
  Windows disk made first) before `netboot local` is removed; or `bin/netboot
  <m> local` automatically at `ts-done` for machines whose cfg says `DISK=`.
  Not seen on real firmware yet [unknown]. Evidence: `spikes/2026-10-24-demo-for-noah/`.
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
