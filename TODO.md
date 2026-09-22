# TODO

Ordered; the top item is the next thing to do. Details and rationale live in
`PLAN.md` (§3 target layout, §4 roadmap, §5 open questions).

## Next

- [ ] **Phase 1 (PLAN.md §4): restructure into the modular `bin/` + `http/` layout,
  replace the sudo mount with 7z extraction, and retire the WIM-injection script.**
  - [ ] Create `bin/` with one verb per script (`build-ipxe`, `stage-winpe`,
    `stage-image`, `pack-drivers`, `fetch-tools`, `serve`, `pxe-lan`, `vm-create`,
    `vm-boot`, `teardown`); each idempotent and confined to this directory tree.
  - [ ] `stage-winpe`: extract `boot.wim`, `bootmgfw.efi`, `BCD`, `boot.sdi` from
    the ISO with `7z x` (no loop mount, no sudo). Keep `boot.wim` pristine.
  - [ ] Retire `scripts/03-inject-autounattend.sh`; the task sequence
    (`winpeshl.ini`, `deploy.cmd`, steps, `diskpart.txt`) is served from `http/ts/`
    and injected by wimboot at boot (see `spikes/2026-09-22-wimboot-task-sequence/`).
  - [ ] `fetch-tools`: download the Windows `curl.exe` + `libcurl-x64.dll` into `http/tools/`.
  - [ ] `serve`: rootless nginx with a `/beacon` location logged to
    `run/beacons.log` (`$time_iso8601 $msec $remote_addr $args`), `$request_time`
    in the access log, and `PUT /uploads/<id>/<run>/…` (dav, `create_full_put_path`,
    write-only); `build-ipxe`: chain URL carries the iPXE identity query.
  - [ ] Beacon contract from PLAN.md §3.2 in the spike's `deploy2.cmd`: `id`
    (lowercase SMBIOS UUID), `run` token minted at `ts-start`, `step`/`ev`/`rc`;
    step output to `X:\pdt\ts.log`, DISM `/LogPath`, both pushed with `curl -T`
    after each step and on failure.
  - [ ] `bin/lint` (every `%SRV%`/`initrd` path referenced by `boot.ipxe` and the
    task sequence exists under `http/`; sidecars present; driver packs contain
    an `.inf`), `bin/status [--watch]`, `bin/await <id> <step> [timeout]`,
    `bin/logs <id>`; all read-only over `run/beacons.log` and `http/uploads/`.
  - [ ] `vm-boot`: `e1000e` NIC + AHCI disk (inbox WinPE drivers), headless option,
    QEMU monitor on TCP; `vm-shot` (screendump → png) and `vm-type` (sendkey)
    from the spike's `shot.sh`.
  - [ ] Move the v1 `setup.exe` flow to `docs/history/` as the documented fallback;
    update `README.md` to describe the new layout.

## After that

- [ ] Phase 2: split the task sequence into steps with beacons and per-model /
  per-UUID config directories; recovery partition + WinRE (`reagentc`) are
  required, with a first-boot `reagentc /info` check (PLAN.md §4).
  Driving/introspection (§3.2): `env.cmd` so every `steps\NN-*.cmd` runs
  standalone from the shell and `deploy NN` resumes; `ev=start` + `ev=ok|fail`
  per step; `STOP_BEFORE`/`STOP_AFTER` and `MODE=shell` in the machine cfg;
  `bin/timeline <id>` reproduces the §2.4 stage table from `beacons.log`.
- [ ] Phase 3: post-install (winget DSC at first logon, log upload, final
  beacon); reference-VM build + `prepare-capture` (sysprep) for a role.
  Carry `id`/`run` into `unattend.xml` so the installed OS continues the same
  timeline; upload Panther, DISM, `reagentc /info` and winget logs to
  `/uploads/<id>/<run>/`; a reliable "I booted" probe (see spikes).
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

- [ ] `config.sh`: port 8088 is taken on this host; pick a free port and re-run
  `00c` before using the v1 pipeline again (see `README.md`, "State of this host").
