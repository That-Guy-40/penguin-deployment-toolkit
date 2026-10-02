# TODO

Ordered; the top item is the next thing to do. Details and rationale live in
`PLAN.md` (§3 target layout, §4 roadmap, §5 open questions).

## Next

- [ ] **Phase 2 (PLAN.md §4): split the task sequence into steps, add the
  recovery partition, per-model configuration.**
  - [ ] `http/ts/env.cmd` (SRV, ID, RUN, MODE, drive letters, the machine cfg)
    that every step `call`s first; `deploy.cmd` becomes a short loop over
    `steps\NN-*.cmd`; `deploy NN` resumes from a step; each step runs standalone
    when typed at the WinPE prompt. boot.ipxe injects each step file.
  - [ ] Steps: `00-net`, `10-identify`, `15-preflight`, `20-disk`, `30-apply`,
    `35-updates` (optional `dism /add-package`), `40-drivers`, `45-winre`,
    `50-boot`, `60-unattend`, `90-reboot`; `ev=start` + `ev=ok|fail` each (the
    helpers already exist in today's `deploy.cmd`).
  - [ ] `STOP_BEFORE=<step>` / `STOP_AFTER=<step>` in the machine cfg.
  - [ ] **Recovery partition + WinRE (required):** 1 GB recovery partition in
    the diskpart script, `Winre.wim` copied, `reagentc /setreimage`, and a
    first-boot `reagentc /info` beacon proving it is enabled.
  - [ ] Per-model config: `machines/<product-slug>/` defaults under the
    per-UUID cfg (driver pack by `${product}`); `MODE=capture` + `capture.cmd`.
  - [ ] `bin/timeline <id>`: `bin/status <id>` already prints per-step timings;
    decide whether a separate command is still wanted or fold it in.
  - [ ] Teach `bin/lint` the step files (it already resolves `for` lists and
    machine cfgs) and add self-test defects for them.

## After that

- [ ] Phase 3: post-install (winget DSC at first logon, log upload, final
  beacon); reference-VM build + `prepare-capture` (sysprep) for a role.
  Already in place from Phase 1: the installed OS continues the run's
  timeline (`C:\pdt\id.cmd` + `beacon.cmd`) and uploads Setup's Panther logs.
  Still to do: `reagentc /info` and winget logs to `/uploads/<id>/<run>/`, a
  final "deployed" beacon, and a reliable every-boot probe (see spikes).
- [ ] Phase 4: image capture from a reference VM → `http/images/<role>.wim`:
  Linux-side `bin/capture-image` (qemu-img convert + wimlib NTFS capture) first,
  WinPE-side `capture.cmd` for physical reference machines; round-trip deploy
  of the captured image is the exit criterion; sidecar metadata per image
  (PLAN.md §4). Capture groundwork is threaded into Phases 1–3 (image-per-role
  layout, wimlib Windows binaries, `30-apply` reads image from role config,
  `capture.cmd` gated by `MODE=capture`, sysprep step).
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
README stating the result (verified / unknown), like
`spikes/2026-09-22-wimboot-task-sequence/`. Cross-referenced in `PLAN.md` §5.

- [ ] **`drvload` of wimboot-injected drivers for WinPE's own NIC/storage.**
  Inject `netkvm.inf/.sys/.cat` (virtio) via wimboot, run
  `drvload X:\Windows\System32\netkvm.inf` before `wpeinit`, boot a VM with a
  `virtio-net-pci` NIC and see whether WinPE gets an address. Decides whether
  VMs can be virtio end to end without ever touching `boot.wim`.
- [ ] **winget availability at first logon on a fresh 24H2 Pro image.** From
  `FirstLogonCommands`, run `winget --version` and `winget configure -f <role>.dsc.yaml`
  and beacon the exit codes; if winget is missing or stale, test bootstrapping
  the App Installer msixbundle (+ VCLibs/UI.Xaml) with `Add-AppxPackage` first.
- [ ] **Secure Boot enforcing on physical hardware.** Boot with the `.ms.fd`
  vars (enforcing) in the VM first: does the unsigned `ipxe.efi` get rejected as
  expected? Then try (a) `sbsign` with our own key enrolled in db, (b) chaining
  through a signed shim; pick one and document the enrolment steps for real
  firmware.
- [ ] **Remote shell over HTTP for `MODE=shell` / failed physical machines**
  (PLAN.md §5 question 6). A `cmd` loop polling `machines/<uuid>/cmd.txt` with
  `curl`, running it, and `PUT`ting the output; try it on the VM first, measure
  whether a 2 s poll is usable, decide on a kill switch. No new binaries.
- [ ] **Every-boot beacon via a scheduled task never fired.** Find out why
  (`schtasks` registration failed at first logon, or the `onstart` task ran
  before the network was up). Try a network-triggered task or a startup script
  with a retry loop; confirm what a reliable "I booted" probe looks like. Until
  then, do not use `onstart` tasks as network probes.
- [ ] **LAN throughput of a 3.5 GB WIM over HTTP versus SMB** (expected: no
  difference that matters; measure once on the physical run).
- [ ] **Linux-side image capture.** Sysprep a reference VM, `qemu-img convert`
  its disk to raw, cut out the Windows partition, `wimlib-imagex capture` it in
  NTFS mode with a WimScript exclusion list, then deploy the result to a fresh
  VM and confirm it boots and reaches the "deployed" beacon. Decides whether
  role images can be built without WinPE or an upload path (PLAN.md §4 Phase 4,
  open question 5).

## Housekeeping

- [ ] `bin/pxe-lan` in **proxy-DHCP** mode has never been run (needs sudo and
  a LAN with its own DHCP server); only its generated config is validated by
  `dnsmasq --test`. `--bridge` mode is verified (below). First real use is Phase 5.
- [ ] A bridge on the real host (setuid `qemu-bridge-helper`,
  `/etc/qemu/bridge.conf`, firewall) is untested; `docs/LAB_FROM_SCRATCH.md`
  describes it. The rootless equivalent, `bin/lab-netns`, is verified.
- [ ] `bin/fetch-iso` has only been run for 24H2 / professional / en-us
  (25H2, other editions and languages are untested).
- [ ] Would `HTTP_HOST='${next-server}'` in the embedded iPXE script remove the
  need to rebuild `ipxe.efi` per network? Cheap to try in `bin/lab-netns` now.
- [ ] `http/unattend/default.xml` ships a blank-password local admin (`deploy`)
  for the lab. Per-role unattend files with real credentials handling belong
  to Phase 3.
- [ ] Ports 8080 and 8088 are taken on this host by other software; `config.sh`
  here uses 8090.

## Done

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
