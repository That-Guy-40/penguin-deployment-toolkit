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
  for the lab; a role's `USERS` list re-passwords it at first logon (the lab
  role does) and creates the real accounts. Still open: domain join; removing
  `deploy` altogether; the Default profile's registry hive (`SKEL` copies
  files only).
- [ ] `bin/vm-stop` powers off through ACPI, which Windows turns into fast
  startup unless the machine's role says `FASTSTARTUP=off` (the lab role
  does). A VM deployed without such a role still hibernates on `vm-stop`.
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
