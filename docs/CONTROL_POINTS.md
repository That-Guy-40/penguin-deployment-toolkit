# Control points: where an admin changes what a machine gets, and when it takes effect

Everything a target does is driven by files under `http/`, served as they
are by `bin/serve`. This page lists every point in a machine's life where
you have a say, which file carries that say, and when an edit takes
effect. Companion to `docs/HOW_IT_WORKS.md` (the tour) and
`http/roles/README.md` (the role keys). Grounded against the code on
2026-10-02; `bin/lint` checks that the files named here exist and agree.

## The timeline

| # | moment | what runs | you control it by editing | an edit takes effect |
|---|---|---|---|---|
| 1 | firmware PXE | `pxe/ipxe.efi` chains to `http://HOST:PORT/boot.ipxe?uuid=…&mac=…&product=…` | `config.sh` (`HTTP_HOST`, `HTTP_PORT`, `SB_KEY`/`SB_CERT`), then `bin/build-ipxe` | next PXE boot. **The one thing baked into a binary** |
| 2 | iPXE | `http/boot.ipxe`: loads `winpe/boot.wim` and *injects* files into `X:\Windows\System32` (`winpeshl.ini`, `deploy.cmd`, `id.cmd`, `curl.exe`, `libcurl-x64.dll`), then `winpe-drivers/<nic-pci-id>.ipxe` or `model-<product>.ipxe` if present | `http/boot.ipxe`, `http/ts/winpeshl.ini`, `http/winpe-drivers/` (`bin/fetch-tools virtio` generates the virtio ones) | next boot |
| 3 | WinPE start | `winpeshl.ini` runs `deploy.cmd`: network up, toolkit fetched, machine identified, `models/<slug>.cfg` ← `machines/<uuid>.cfg` layered, `ts/<MODE>.seq` chosen | `http/machines/<uuid>.cfg` (`MODE`, `IMAGE`, `UNATTEND`, `DISKPART`, `DRIVERS`, `UPDATES`, `POST`, `ROLE`, `REFERENCE`, `STOP_BEFORE`/`STOP_AFTER`), `http/models/<slug>.cfg` (the same minus `MODE`, `STOP_*`, `REFERENCE`) | next boot, or `deploy` typed at the WinPE prompt: it re-fetches everything, no reboot |
| 4 | task sequence | `ts/steps/NN-*.cmd` in the order `ts/deploy.seq` gives: preflight, disk, download, apply, updates, drivers, winre, boot, unattend, reboot | the step files, `ts/*.seq`, `ts/diskpart/*.txt` | same as 3. `STOP_BEFORE=NN` stops there with the environment loaded; `deploy NN` resumes |
| 5 | the image | `30-apply` lays down `images/<IMAGE>.wim`; `35-updates` adds the packages in `updates/<pack>.wim`; `40-drivers` adds `drivers/<pack>.wim`; `45-winre` puts `images/<IMAGE>.winre.wim` on the recovery partition | `bin/stage-image` (ISO → `base.wim`), `bin/pack-updates`, `bin/pack-drivers`, `bin/capture-image` (a role image) | the next deploy that names it |
| 6 | `60-unattend` | writes `C:\Windows\Panther\unattend.xml` and recreates `C:\pdt\`: `id.cmd` (server, id, run token), `beacon.cmd`, `firstlogon.cmd`, `boot-probe.cmd`, the role's files under `role\`, `winget.cmd`/`users.ps1` if the role needs them, `post.cmd` (`POST=`), `prepare-capture.cmd` (`REFERENCE=yes`) | `http/unattend/<file>.xml` or the role's own `UNATTEND=`; `http/post/*`; `http/roles/<role>/*` | next deploy: this is the moment the installed system's scripts are frozen onto its disk |
| 7 | Windows first boot | Setup runs the unattend: specialize (computer name; `specialize` beacon), oobeSystem (creates `deploy`, autologon once) | `unattend.xml` | — |
| 8 | **first logon, once** | `FirstLogonCommands` → `C:\pdt\firstlogon.cmd`, elevated, as `deploy`: `winre` check → `skel` → `users` → `winget` + `apps` → `faststartup` → boot probe registered → role `post.cmd` → machine `post.cmd` → `deployed` → `prepare-capture` if `REFERENCE=yes` | `http/roles/<role>/role.cfg` and what it names: `apps.txt`, `users.txt`, `skel/` + `skel.txt`, `post.cmd` (+ `FILES=`), `UNATTEND`, `FASTSTARTUP`; `POST=` in the machine or model cfg | next deploy (copied to the disk in 6). Idempotent on a machine that already has it |
| 9 | **every boot, for ever** | two scheduled tasks (`PDT-boot-onstart`, `PDT-boot-event`) run `C:\pdt\boot-probe.cmd <trigger>` as SYSTEM → `boot ok trigger=…` | `http/post/boot-probe.cmd` | next deploy; on a running machine only by hand |

## What is in the .wim: three layers

- **WinPE's `boot.wim`** is never modified. Everything WinPE runs is
  injected at boot by iPXE (row 2). Changing the install is editing a text
  file under `http/ts/` and rebooting the target.
- **The OS image** is `images/<IMAGE>.wim` as staged from the ISO, plus
  what `35-updates` and `40-drivers` add *at apply time* (row 5). Updates and
  drivers are packs, not image edits; the image file stays what its sidecar
  says it is.
- **A role image** is a machine that was deployed with `REFERENCE=yes` and a
  `ROLE`, generalized and captured (`bin/capture-image <vm> <name>`). It
  carries the role's apps, accounts, skel and the boot-probe tasks; its
  sidecar's `provenance` records the role and the SHA-256 of the apps list.
  A machine deployed from it still runs row 8 for *its own* role.

## Scripts that run on the installed machine, and when

| when | what | from |
|---|---|---|
| once, first logon | `firstlogon.cmd` and everything it calls (row 8): the only place accounts, software and policy are applied | `http/post/`, `http/roles/<role>/` |
| every boot | the boot probe (row 9), and nothing else: there is no agent, service or startup script of the toolkit's on a deployed machine | `http/post/boot-probe.cmd` |
| something of yours, every boot | not provided; a role `post.cmd` can register its own scheduled task the way `boot-probe.cmd` does | your role |

## Users

`roles/<role>/users.txt`, one `name|group|policy` per line, applied once at
first logon by `post/users.ps1`. An account that exists (the unattend's
`deploy`) is re-passworded, not recreated; new accounts are created; both
join the named group. `random` passwords are uploaded to
`uploads/<id>/<run>/users.txt` on the server (`bin/logs <m> --cat users.txt`)
and removed from the machine. New profiles inherit `skel/`
(`C:\Users\Default`). The unattend itself only ever creates `deploy`;
`http/roles/README.md`, "Accounts and passwords", has the details and the
limits (no domain join, no registry-hive templating).

## Applications

`roles/<role>/apps.txt`, winget ids, installed once at first logon after
winget is bootstrapped from packages *this server* serves
(`bin/fetch-tools winget`; `http/post/winget/`). The packages themselves
come from winget's sources, i.e. the internet. What winget cannot express
goes in the role's `post.cmd`. To make software part of the image instead,
deploy a reference machine with the role and capture it.

## Safety, which is also a control point

- A machine with no `machines/<uuid>.cfg` boots WinPE, reports itself and
  stops at a prompt. Nothing is written.
- Only `MODE=deploy` wipes a disk, and only the machine file can set `MODE`
  (a model file saying so is ignored).
- `15-preflight` checks every file the whole run will need, the role's
  included, before `20-disk` runs `diskpart`. `bin/lint` checks the same
  from the server side, plus the things preflight cannot see (sidecars,
  cfg hygiene, programs WinPE lacks).

## Edges: what is not controllable from files today

The firmware → `ipxe.efi` hop (a rebuild); anything on a machine after
first logon except the boot beacon; domain join; the Default profile's
registry hive. All four are in `TODO.md` or `DEFERRED.md`.
