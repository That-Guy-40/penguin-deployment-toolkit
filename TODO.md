# TODO

Ordered; the top item is the next thing to do. Details and rationale live in
`PLAN.md` (§3 target layout, §4 roadmap, §5 open questions).

## Next

- [ ] **Phase 3 (PLAN.md §4): post-install.**
  - [ ] winget: it is not in the image (verified). `fetch-tools` fetches and
    pins the release `msixbundle` + `DesktopAppInstaller_Dependencies.zip`,
    served from `http/post/`; the first-logon script installs them (works:
    `spikes/2026-10-02-unverified-items/winget-bootstrap-probe.cmd`), then
    `winget configure -f <role>.dsc.yaml` or an install list.
  - [ ] `ROLE=` in the machine/model cfg selecting `unattend/<role>.xml` and
    `post/<role>.*`; credentials handling instead of the lab's blank password.
  - [ ] Upload winget logs; a final `deployed` beacon after post-install.
  - [ ] An every-boot probe: two scheduled tasks, "at startup" and on System
    event Kernel-Boot 27 (verified: each covers what the other misses).
  - [ ] Role software into the reference machine before `prepare-capture`
    (the `POST=` hook exists), and the role file's hash into the image sidecar.

## After that

- [x] Phase 4: image capture from a reference VM → `http/images/<role>.wim`:
  mechanics done and verified (see Done). What is left arrives with Phase 3:
  the role's software in the reference, and its DSC hash in the sidecar.
- [ ] Phase 5: real hardware over the network via iPXE (the goal): `pxe-lan`
  on the real LAN, machine allow-list gating destructive steps, per-model driver
  packs, Secure Boot, measured PXE→desktop time; one physical model deployed
  repeatably (PLAN.md §4). `pxe-lan` runs dnsmasq with `--log-dhcp`; physical
  debugging is `status`/`logs`, never a screen (PLAN.md §3.2).
- [ ] Phase 6: deployable by others as infrastructure: `INSTALL.md`,
  `bin/preflight` (PASS/FAIL/UNKNOWN rows, with deliberate failing rows),
  systemd units for `serve`/`pxe-lan`, pinned and verified inputs, and a
  from-scratch run of `INSTALL.md` on a clean machine before tagging a release
  (PLAN.md §3.1); `bin/test-deploy` (vm-create → vm-boot → `await` each step →
  `vm-shot`) is that run; `INSTALL.md` gets a "watching an install" section.

## Later / optional (after Phase 6; spike first, then layer on)

- [ ] Streaming apply without the temp file: pipable WIM made on Linux,
  `curl … | wimlib-imagex.exe apply - 1 W:\` in WinPE. Spike: time it against
  download-then-`dism` on the same VM; adopt only if faster or needed for small
  disks (PLAN.md §4 "Later / optional").
- [ ] A 50-line Python dispatcher rendering `boot.ipxe`/`deploy.cmd` per
  identity instead of static `http/machines/` directories. Spike beside nginx
  for one machine; adopt only when hand-editing directories becomes the pain
  (PLAN.md §4 "Later / optional").

## Questions to explore through spikes

Each gets a dated directory under `spikes/` with its scripts, evidence and a
README stating the result. Answered ones are in `PLAN.md` §5.

- [ ] **Remote shell over HTTP for `MODE=shell` / failed physical machines**
  (PLAN.md §5 question 6). A `cmd` loop polling `machines/<uuid>/cmd.txt` with
  `curl`, running it, and `PUT`ting the output; try it on the VM first, measure
  whether a 2 s poll is usable, decide on a kill switch. No new binaries.
- [ ] **Updating WinRE.** The Safe OS dynamic update (a .cab in every UUP set)
  belongs in `images/<name>.winre.wim`. On Linux that needs DISM-like servicing
  wimlib cannot do; in WinPE it would be `dism /mount-image` + `/add-package`
  on the recovery image in `45-winre`. Is it worth it, and how long does it take?
- [ ] **`winget configure` (DSC)** from the first-logon script, once winget is
  bootstrapped: does it run unattended, and what does a role file look like?
- [ ] **LAN throughput of a 3.5 GB WIM over HTTP versus SMB** (expected: no
  difference that matters; measure once on the physical run).
- [ ] After a forced power-off neither boot-probe task reported within 150 s
  (one observation, `spikes/2026-10-02-unverified-items/`). Fast-startup resume
  or something else?

## Housekeeping

- [ ] Real hardware has still seen none of this (Phase 5). In particular:
  enrolling the Secure Boot certificate in real firmware, and proxy-DHCP on a
  real switch next to a real router. (A bridge on the real host, and
  `bin/lab-netns` on a host that restricts user namespaces, were both verified
  on 2026-10-02 with root supplied by hand.)
- [ ] `bin/fetch-iso` has been run for 24H2 and 25H2, professional, en-us. Other
  editions and languages are untested. A `bin/fetch-updates` that keeps just
  the update packages of a UUP set (today: `fetch-iso --keep`, then pick them
  out of `build/uupdump/*/UUPs/`) would make monthly update packs a command.
- [ ] `http/ts/diskpart/` has one layout (`uefi-gpt.txt`). BIOS/MBR machines
  and multi-disk machines are not handled.
- [ ] `http/unattend/default.xml` ships a blank-password local admin (`deploy`)
  for the lab. Per-role unattend files with real credentials handling belong
  to Phase 3.
- [ ] `bin/vm-stop` powers off through ACPI, which Windows turns into fast
  startup. Consider disabling fast startup on deployed lab machines
  (`powercfg /h off`), or give `vm-stop` a way to ask for a full shutdown.
- [ ] Ports 8080 and 8088 are taken on this host by other software; `config.sh`
  here uses 8090.

## Done

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
