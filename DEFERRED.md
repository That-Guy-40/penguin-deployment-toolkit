# DEFERRED

Ideas that were considered and deliberately parked, with the reason. They are
not gaps and not next steps (`TODO.md` has those); they are here so nobody
rediscovers them as surprises. Each says what would make it worth picking up.

## Design changes, after Phase 6 (PLAN.md §4 "Later / optional")

- **Streaming apply without the temp file.** A pipable WIM made on Linux,
  `curl … | wimlib-imagex.exe apply - 1 W:\` in WinPE. Saves the 3.5 GB write
  and read on the target and the space for it. Spike first: time it against
  download-then-`dism` on the same VM. Pick up if it is faster or a target has
  too small a disk.
- **A small dispatcher.** A Python service that renders `boot.ipxe` and
  `deploy.cmd` per machine instead of static `machines/` and `models/`
  directories. Pick up when hand-editing those directories is the main pain.

## Parked with a reason

- **Remote shell over HTTP for `MODE=shell` or failed physical machines**
  (PLAN.md §5 question 6): a `cmd` loop polling `machines/<uuid>/cmd.txt`,
  running it, `PUT`ting the output. Same trust boundary as editing
  `deploy.cmd`, no new binaries. Parked until physical machines exist to need
  it; `STOP_BEFORE` plus pushed logs cover the lab.
- **Updating the recovery image.** The Safe OS dynamic update in every UUP set
  belongs in `images/<name>.winre.wim`; today WinRE stays at the base build
  while `35-updates` updates the OS. Would need `dism /mount-image` +
  `/add-package` on the recovery image inside WinPE, or Windows-side tooling.
  Parked until an updated WinRE matters (Reset this PC, repair).
- **`bin/fetch-updates`.** Keep just the update packages of a UUP set; today
  it is `fetch-iso --keep` and picking files out of `build/uupdump/*/UUPs/`.
  Pick up when update packs are made monthly.
- **BIOS/MBR and multi-disk layouts.** One `ts/diskpart/uefi-gpt.txt` exists.
  UEFI-only is a deliberate scope choice; add a layout file when a machine
  needs one.
- **`bin/timeline`.** Folded into `bin/status <id>`, which already prints a
  boot's events with durations. Revive only if per-run comparison is wanted.
- **`${next-server}` as the server address** in the embedded iPXE script, to
  avoid rebuilding `ipxe.efi` per network. Verified not to work behind
  proxy-DHCP (it is the router). Closed, not parked.
- ~~**Disabling fast startup on deployed machines**~~ **Done 2026-10-02 as a role
  setting:** `FASTSTARTUP=off` in `roles/<name>/role.cfg` runs `powercfg /h off`
  at first logon (`http/roles/README.md` says why it is a property of the role,
  not of the toolkit). Machines without a role keep Windows' default.
- **`capture.ini` as a per-role exclusion list.** One list serves every capture
  today. Pick up when a role needs different exclusions.
- **A shim instead of signing `ipxe.efi` with our own key.** Verified
  unnecessary: `wimboot` and Windows' boot files are Microsoft-signed; only
  `ipxe.efi` needs our signature. A shim would only matter where enrolling a
  certificate in firmware is impossible.
