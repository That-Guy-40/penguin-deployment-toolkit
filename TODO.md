# TODO

Ordered; the top item is the next thing to do. Details and rationale live in
`PLAN.md` (§3 target layout, §4 roadmap, §5 open questions). Ideas deliberately
parked are in `DEFERRED.md`, not here.

## Next

- [ ] **Local-boot handoff** (`docs/REVIEW-2026-10-12.md`, finding 1). A
  machine that is PXE-first in firmware redeploys itself after every
  `90-reboot` (`bin/vm-boot --pxe` says so); disk-first needs a person at F12
  for every re-image. Neither is "nobody at the keyboard". The collector
  commit gave `boot.ipxe` per-machine overrides (`boot/<uuid>.ipxe` and
  `boot/default.ipxe`, one-liners written by `bin/netboot`), `bin/enroll`,
  and `pdt-pxe-next` (BootNext from Linux), so what is left is small: a
  third `pdt_boot` value, `local`, one line in `boot.ipxe`
  (`iseq ${pdt_boot} local && exit ||`: iPXE returns to the firmware, which
  boots the next entry, Windows after `bcdboot`), `bin/netboot <m> local`,
  and `lint` accepting the third one-liner. With that, PXE-first firmware
  is safe: `netboot <m> local` after a deploy, `netboot <m> winpe` to
  re-image, no keyboard. Verify on a VM booted `--pxe`: deploy, `netboot
  local`, the next boot lands on the desktop (`boot ok`, no `ts-start`);
  `netboot winpe` and it is back in WinPE. Still open after that: a
  disk-first installed Windows has no agent to set BootNext, so re-imaging
  one needs `bcdedit /set {fwbootmgr} bootsequence` over RDP or a hand at
  F12; and a watcher that runs `netboot local` on a machine's `deployed`
  beacon (the first use for the dispatcher parked in `DEFERRED.md`). Do the
  `local` override before the Latitude's first deploy.
- [ ] **Disk guard** (review, finding 2). `ts/diskpart/uefi-gpt.txt` says
  `select disk 0` then `clean`. Build a step before `20-disk` that lists the
  disks (`diskpart list disk` into a file), refuses to continue if the chosen
  disk is removable or smaller than a minimum, and takes `DISK=<n>` from the
  machine or model cfg (default: the only fixed disk; fail if there are
  several and none is named). Write the number into the diskpart script with
  a token (`select disk @DISK@`) at run time; `lint` learns the key and the
  token. Negative control on a VM with two disks and no `DISK=`: the step
  fails, nothing is wiped.
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

- [ ] Phase 6: deployable by others as infrastructure: `INSTALL.md`,
  `bin/preflight` (PASS/FAIL/UNKNOWN rows, with deliberate failing rows),
  systemd units for `serve`/`pxe-lan`, pinned and verified inputs, and a
  from-scratch run of `INSTALL.md` on a clean machine before tagging a release
  (PLAN.md §3.1); `bin/test-deploy` (vm-create → vm-boot → `await` each step →
  `vm-shot`) is that run; `INSTALL.md` gets a "watching an install" section.

## Questions to explore through spikes

Each gets a dated directory under `spikes/` with its scripts, evidence and a
README stating the result. Answered ones are in `PLAN.md` §5.

- [ ] **LAN throughput of a 3.5 GB WIM over HTTP versus SMB** (expected: no
  difference that matters; measure once on the physical run).

## Housekeeping

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
