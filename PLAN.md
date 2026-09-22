# Plan: a small, Linux-hosted replacement for MDT

> **Status (2026-09-22):** this is the *current* plan. It supersedes the original
> design note (now in `docs/history/`, together with two early reviews). What the
> repo does **today** is documented in `README.md`; this file says where it is
> going and why. Every claim below is tagged **[verified]** (run on this host),
> **[read]** (derived from source or docs, not executed) or **[unknown]**.

## 1. North star

Deploy Windows 11 onto VMs and physical machines from a Linux host, with no
Windows machine, no ADK, no MDT/SCCM, using Microsoft's own deployment machinery
inside WinPE (diskpart, DISM, bcdboot, unattend, winget) and Linux tools for
everything that happens before the target boots (wimlib, iPXE, nginx, QEMU).

Properties we optimise for, in order: **understandable, maintainable, easily
extended, modular**. Elegance means fewer moving parts, not cleverer ones.

Two outcomes define "done":

1. **Real hardware over the network.** A physical machine on a LAN is set to
   PXE boot, powers on, and ends at a configured Windows desktop with the right
   drivers, with no media and nobody at the keyboard. The VM lab exists to make
   that path cheap to develop and test; it is not the product.
2. **Deployable by others as infrastructure.** Someone with an Ubuntu box, a
   Windows 11 ISO and a LAN can clone this repo, follow `INSTALL.md`, and have a
   working deployment server. Nothing host-specific is baked into scripts;
   everything host-specific lives in `config.sh`.

## 2. What is settled (decisions and the evidence behind them)

### 2.1 Boot chain stays iPXE → wimboot → WinPE **[verified]**

```
firmware PXE ──TFTP──▶ ipxe.efi (embeds one line: chain http://HOST:PORT/boot.ipxe?<identity>)
   └─ iPXE ──HTTP──▶ boot.ipxe ──HTTP──▶ wimboot + bootmgfw.efi + BCD + boot.sdi + boot.wim
        └─ wimboot injects extra HTTP-fetched files into X:\Windows\System32 and boots WinPE
             └─ winpeshl.ini ──▶ deploy.cmd  (the task sequence; plain text on the Linux host)
```

The only binary we build is `ipxe.efi`, and the only thing baked into it is the
chain URL. Everything else is a file on the HTTP server.

### 2.2 Machine identity is captured by iPXE, before Windows runs **[verified]**

iPXE exposes SMBIOS and NIC facts as variables; the embedded script passes them
as query parameters, so the server sees who is booting in its access log and can
answer per machine/model. Observed request from a QEMU guest:

```
GET /boot.ipxe?mfr=QEMU&product=Standard PC (Q35 + ICH9, 2009)&uuid=…&serial=&mac=52:54:00:12:34:56&chip=82574l&busid=01:80:86:10:d3
```

Available: `${manufacturer}`, `${product}`, `${serial}`, `${uuid}`, `${asset}`,
`${board-serial}`, `${netX/mac}`, `${netX/chip}`, `${netX/busid}` (PCI
vendor:device of the NIC). Inside WinPE the same facts come from the registry
(`HKLM\HARDWARE\DESCRIPTION\System\BIOS`, no WMI needed) and `wmic csproduct`
(still present in build 26100 WinPE) **[verified]**.

### 2.3 boot.wim is used **pristine**; customisation is injected by wimboot **[verified]**

wimboot places every extra `initrd` file into `X:\Windows\System32` of the
booted image (wimboot source: `WIM_INJECT_DIR = "\Windows\System32"`). Tested:
`winpeshl.ini`, `deploy.cmd`, `http.js`, `curl.exe`, `libcurl-x64.dll` injected
into an untouched `sources/boot.wim`, and the task sequence ran. Negative
control: the same boot with wimboot's `rawwim` option (injection off) landed in
stock Windows Setup and sent no beacon.

Consequences:

- No more `wimlib-imagex update` of boot.wim per change (today's `03` script).
  Editing the task sequence is editing a text file on the server.
- **Use `winpeshl.ini`, not `startnet.cmd`.** wimboot *appends* directory
  entries and does not check for an existing name **[read]**; `startnet.cmd`
  already exists in the WIM, `winpeshl.ini` does not. With a `winpeshl.ini`
  present WinPE does not run `wpeinit` for you, so the task sequence calls it.
- Anything that must be *inside* the WIM for the kernel (boot-critical
  storage/NIC drivers for WinPE itself) is the one thing this cannot do; see 2.6.

### 2.4 Install with `diskpart` + `dism /apply-image` + `bcdboot`, not `setup.exe` **[verified]**

This is what MDT does and it is the shape that lets us do things *between*
apply and first boot (drivers, unattend, files). Verified end to end on a
throwaway QEMU VM on 2026-09-22 (timestamps from the server log):

| stage (beacon)  | time     | what happened |
|-----------------|----------|---------------|
| ts-start        | 03:55:54 | WinPE up, network up (inbox e1000e), curl.exe works |
| downloaded      | 03:56:09 | 3.5 GB `install.wim` fetched over HTTP to `W:\` |
| applied         | 03:56:57 | `dism /apply-image` of the 15.7 GB image |
| drivers-added   | 03:56:57 | virtio driver pack applied + `dism /image:W:\ /add-driver` |
| ts-done         | 03:56:57 | `bcdboot`, `unattend.xml` into `W:\Windows\Panther`, reboot |
| specialize      | 03:57:27 | installed Windows booted from disk, ran the Panther unattend |
| firstlogon      | 03:58:03 | autologon, `ComputerName=SPIKE2` applied, desktop shown |
| (virtio reboot) | 04:01:34 | rebooted with a **virtio** NIC instead of e1000e: the guest got an address and opened TCP sessions, so the driver injected in WinPE works (QEMU `info usernet`) |

### 2.5 Transport is HTTP only; no SMB **[verified]**

Stock WinPE has no `curl.exe`, no PowerShell and no `bitsadmin`/`certutil`
(inventory of build 26100 boot.wim, image 2). It does have `cscript` + MSXML
(usable for text fetches; `http.js` in the spike) and, once injected, the
official Windows `curl.exe` build handles binaries at full speed. One nginx
serves boot files, images, driver packs, task-sequence text and receives
progress "beacons" (`GET /beacon?…`, one line per event; contract in §3.2). No Samba,
no credentials, works through QEMU user-net (`10.0.2.2`) and on a LAN.

### 2.6 Drivers: packs are WIMs built on Linux; injection happens in WinPE **[verified]**

- Vendor packs (virtio-win ISO, Dell/Lenovo/HP CABs) are unpacked on Linux
  (`7z`, `cabextract`) and captured per model with `wimlib-imagex capture`
  (LZX, 21 MB → 6.5 MB for virtio net/stor/scsi).
- In WinPE: `curl` the pack → `dism /apply-image … /applydir:W:\Drivers` →
  `dism /image:W:\ /add-driver /driver:W:\Drivers /recurse`. Verified with the
  signed virtio-win w11 drivers.
- Selection key: iPXE `${product}` (or `${uuid}` for one-offs). Start with a
  directory per product slug; a tiny dispatcher can come later.
- Drivers **WinPE itself** needs (a NIC or storage controller with no inbox
  driver) cannot be registered offline from Linux (DISM only). Options, in
  preference order: (a) pick hardware WinPE already supports for VMs (`e1000e`
  NIC, AHCI disk, both inbox **[verified]**); (b) `drvload X:\Windows\System32\<x>.inf`
  at the top of the task sequence with the .inf/.sys/.cat injected by wimboot
  **[unknown, untested]**; (c) as a last resort, add the driver to boot.wim with
  DISM from inside a WinPE session and capture the result **[unknown]**.

### 2.7 Image curation happens on Linux with wimlib, within known limits

Can do on Linux **[read/verified where marked]**: extract `boot.wim`/`install.wim`
from the ISO without root (`7z x`; today's `02` uses `sudo mount`, unnecessary)
**[verified]**; export a single edition (`wimexport`), recompress/optimise
(`wimoptimize`), add/replace files (`wimupdate`), split (`wimsplit`), build
driver/tool packs (`wimcapture`) **[verified for capture]**; offline registry
edits with `hivexregedit`/`chntpw` **[read]**.

Cannot do on Linux: integrate cumulative updates, add/remove Windows features,
remove provisioned Appx. The UUP dump Linux converter says so explicitly
(`convert.sh`: "does not and cannot support the integration of updates") and it
is the reason `00b` produces build 26100.1 (24H2 RTM). Do those in WinPE on the
applied image (`dism /image:W:\ /add-package`) or accept Windows Update doing it
post-install.

### 2.8 Post-install configuration: unattend for the OS, winget for software **[unknown]**

- The Panther `unattend.xml` (specialize + oobeSystem only) sets computer name,
  locale, local admin, autologon, hides OOBE, and runs `FirstLogonCommands`
  **[verified]**.
- winget only exists in the full OS. Plan: a first-logon step that runs
  `winget configure -f <role>.dsc.yaml` (declarative, idempotent) or a plain
  `winget install --id … ` list, with a fallback that installs the App Installer
  msixbundle first (fresh images sometimes ship a winget that cannot run until
  updated). Untested.
- Progress and logs go back to the server with `curl`: beacons now, DISM/Setup
  logs via `curl -T` to the `PUT /uploads/` endpoint (§3.2).

### 2.9 Lab: QEMU VM with hardware WinPE already understands **[verified]**

`e1000e` NIC + AHCI disk + OVMF secboot build in Setup Mode + no TPM needed for
the apply path. WinPE boot to task-sequence start is ~10 s after `boot.wim`
finishes downloading.

## 3. Target layout (modular)

```
penguin-deployment-toolkit/
├── config.sh                 # host settings (port, IPs, paths); from config.sh.example
├── bin/                      # one verb per script, no numbering
│   ├── preflight             # PASS/FAIL/UNKNOWN per prerequisite (with known-failing rows)
│   ├── build-ipxe            # ipxe.efi with the chain URL (+identity query)
│   ├── stage-winpe           # 7z-extract boot.wim/bootmgfw/BCD/boot.sdi from the ISO
│   ├── stage-image           # ISO -> images/base.wim (wimexport/optimize) + sidecar .json
│   ├── pack-drivers          # vendor pack dir -> drivers/<product-slug>.wim (wimcapture)
│   ├── fetch-tools           # pinned + hash-checked curl.exe/dll, wimlib-imagex.exe, wimboot
│   ├── serve                 # rootless nginx: static + GET /beacon + PUT /uploads/ (3.2)
│   ├── lint                  # every file boot.ipxe/the task sequence reference exists; cfg + sidecars parse (3.2)
│   ├── status / timeline / await   # read beacons.log: fleet view, per-run step timings, block until a step (3.2)
│   ├── vm-shot / vm-type     # QEMU monitor screendump / sendkey into the lab VM (3.2)
│   ├── pxe-lan               # dnsmasq proxy-DHCP + TFTP for physical targets (today's 07)
│   ├── vm-create / vm-boot   # lab VM (e1000e + AHCI; virtio once drvload is settled)
│   ├── capture-image         # sysprepped VM disk -> images/<role>.wim (Linux-side, Phase 4)
│   └── teardown
├── http/                     # everything the target can see, all static
│   ├── boot.ipxe             # default iPXE script: identify, then chain per machines/ config
│   ├── winpe/                # pristine boot.wim, bootmgfw.efi, BCD, boot.sdi, wimboot
│   ├── tools/                # curl.exe, libcurl-x64.dll, wimlib-imagex.exe (+ its dlls)
│   ├── ts/                   # winpeshl.ini, deploy.cmd, capture.cmd, env.cmd, steps/*.cmd, diskpart/*.txt
│   ├── images/               # base.wim, <role>.wim, each with a <name>.json sidecar
│   ├── drivers/              # <product-slug>.wim driver packs (+ drvload/ for WinPE-side drivers)
│   ├── unattend/             # <role>.xml Panther unattend files
│   ├── post/                 # <role>.dsc.yaml (winget) + first-logon scripts
│   ├── machines/             # <uuid>.cfg / <mac>.cfg: MODE, ROLE, IMAGE, DRIVERS, STOP_AFTER… (Phase 2, 3.2)
│   └── uploads/              # PUT target for logs and captured WIMs (never served back)
├── run/                      # STATE_DIR: nginx pid, access.log, beacons.log (append-only; the "database")
├── systemd/                  # unit files for serve and pxe-lan (Phase 6)
├── INSTALL.md                # server install for other people (see 3.1)
├── TODO.md                   # ordered next steps
├── docs/history/             # superseded plans and reviews
└── spikes/                   # dated experiments with their evidence
```

Rules: `bin/` scripts are idempotent and only touch this directory tree; the
task sequence is plain `cmd` with one step per file; nothing on the server needs
sudo except the LAN proxy-DHCP; every host-specific value (LAN interface, IP,
port, ISO path, model list) is read from `config.sh`, never hard-coded.

### 3.1 Deployable as infrastructure

The repo must work on a machine that is not this one. Concretely:

- `INSTALL.md`: prerequisites (Ubuntu 24.04, packages, firewall ports UDP 67/69/4011
  + TCP `HTTP_PORT`, an ISO), a first-run walkthrough (`bin/preflight`,
  `bin/build-ipxe`, `bin/stage-winpe`, `bin/stage-image`, `bin/serve`,
  `bin/pxe-lan`), then "boot a VM" and "boot a real machine" sections, and how
  to add a model (driver pack) or a role (unattend + winget DSC).
- `bin/preflight`: checks every prerequisite and prints PASS/FAIL/UNKNOWN per
  row, including deliberate failing rows so an all-PASS run is distinguishable
  from a run that checked nothing.
- `config.sh.example` stays the single template; `bin/*` refuse to run without
  a `config.sh` and validate what they need from it.
- Running as a service: a `systemd` unit (or `--daemon` flag) for `serve` and
  `pxe-lan`, so the server survives reboots. Logs and state under the repo (or a
  configurable `STATE_DIR`), never in `/tmp`.
- Reproducible inputs: `fetch-tools` pins versions and verifies sizes/hashes
  (curl.exe, wimboot, iPXE commit, virtio-win); the README says which Windows
  build the flow was last verified against.
- Safety rails for a shared LAN: proxy-DHCP only answers PXE clients, an
  allow-list of MACs/UUIDs in `http/machines/` gates who gets a wiping task
  sequence (unknown machines get a shell, not `diskpart clean`), and the default
  `boot.ipxe` requires an explicit opt-in before anything destructive.
- Tested from scratch: a "clean box" run (fresh VM or container) of `INSTALL.md`
  is part of releasing; the walkthrough's first command must work.
- Licensing: pick a licence for this repo (MIT is the default suggestion);
  third-party pieces (iPXE and wimboot are GPL, curl is MIT-style, virtio-win
  is GPL/BSD, Windows media is Microsoft's) are **fetched, never vendored**, so
  the repo contains only our scripts and docs. `INSTALL.md` says that users
  bring their own Windows licence/keys (the answer files ship without a product
  key).

### 3.2 Driving and introspecting installs

An install runs on a machine nobody is logged into, across three environments
in turn (firmware + iPXE, WinPE, the installed OS), and the only channel back is
HTTP to `serve`. Today's failure mode is "it sat there for twenty minutes, then a
screenshot". Every phase below adds steps that must be watched, stopped before,
and re-run without a full reboot, and Phase 5 adds machines that have no screen
we can capture. The tooling for that is small and static, and it is built *with*
each phase, not after (see the *introspection groundwork* notes in §4).

Principles: the server clock is the only clock (WinPE and real RTCs are not
trusted); one line per event, greppable; static files are the control channel
(no dispatcher, no database); every step is re-runnable by hand from the WinPE
shell; nothing new goes into WinPE beyond `curl.exe` (a `cscript` helper at most).

**Events (beacons).** One contract, used by iPXE-era log lines, the task
sequence, `unattend.xml` and first-logon scripts alike:

```
GET /beacon?id=<uuid>&run=<token>&step=<name>&ev=start|ok|fail[&rc=<n>][&msg=<text>][&k=v…]
```

- `id` is the SMBIOS UUID, lowercase (iPXE `${uuid}`, WinPE `wmic csproduct`;
  the tools normalise case). `run` is a token the task sequence mints at
  `ts-start` (`%RANDOM%`-based is enough) and repeats on every later event and
  upload path, so two boots of the same machine never interleave.
- Every step sends `ev=start` *and* `ev=ok|fail`. A `start` with nothing after
  it is the answer to "where is it stuck" (in DISM, in a download) without a
  screenshot. The first event of a run also carries `mode`, `product`, `mac`.
- `serve` logs `location = /beacon` to its own file with its own format:
  `log_format beacon '$time_iso8601 $msec $remote_addr $args'` →
  `run/beacons.log` **[read]**. Append-only, never rotated away; boot-file
  requests stay in the access log. Two synthetic events are derived from the
  access log by the tools, not sent by anyone: `ipxe` (the `boot.ipxe?…`
  request with identity) and `wim` (`boot.wim` served in full, with
  `$request_time` in the access-log format so transfer rate falls out for free;
  open question 4).

**Logs.** Everything a step prints goes to `X:\pdt\ts.log` (console shows only
banners), DISM is pointed at `X:\pdt\dism.log` with `/LogPath` **[read]**, and
`deploy.cmd` pushes both after every step and on failure:

```
curl -sS -T X:\pdt\ts.log %SRV%/uploads/%ID%/%RUN%/ts.log
```

The endpoint is defined once, here, and implemented by `serve` in Phase 1:
`PUT /uploads/<id>/<run>/…` via nginx's `http_dav_module` (present in Ubuntu's
nginx build **[verified]**), with `dav_methods PUT`, `create_full_put_path on`,
`client_max_body_size 0` **[read]**; write-only, never listed or served back.
Phase 3 adds the installed-OS files to it (`C:\Windows\Panther\setupact.log`,
`setuperr.log`, `Logs\DISM\dism.log`, `reagentc /info` output, winget's
`DiagOutputDir`); Phase 4 uses it for captured WIMs.

**Driving.** `deploy.cmd` is a ten-line loop over `steps\NN-*.cmd`; all state
(server URL, `ID`, `RUN`, `MODE`, drive letters, the machine cfg) lives in
`env.cmd`, which every step `call`s first, so `steps\40-drivers` works typed at
the shell exactly as it does in the sequence, and `deploy 40` resumes from a
step. Control keys in the machine cfg (`http/machines/<uuid>.cfg`, fetched
once at `ts-start`): `STOP_BEFORE=<step>` / `STOP_AFTER=<step>` drop to the
shell with `env.cmd` loaded (this is how a new step is developed: run up to it,
try it by hand, then let the sequence own it); `MODE=shell` is the default for
unknown machines and still identifies, beacons and pushes logs, so a strange
box that PXE-boots shows up in `status` as "shell, waiting". On failure: `fail`
beacon with `step`+`rc`, push logs, shell. The VM screen (`vm-shot`) and blind
typing (`vm-type`, QEMU `sendkey`) stay the last resort for VMs; physical boxes
have no equivalent, which is why logs are pushed and not merely kept.

**Server-side tools (read-only, over `beacons.log` + `uploads/`).**

- `lint`: parse `boot.ipxe`, `deploy.cmd`, `steps/*` and `machines/*` for every
  `%SRV%/…` and `initrd` path and check the file exists under `http/`; check
  each `images/*.wim` has its sidecar and driver packs contain an `.inf`
  (`wimlib-imagex dir`). A 404 today shows up three minutes into a boot.
- `status [--watch]`: one row per `id`: product, mode, last step and event, age,
  run; `fail` and stale `start` rows highlighted. `timeline <id> [run]`: the
  step table from §2.4 with durations, computed, not typed. `logs <id>`: what
  was uploaded for the last run.
- `await <id> <step> [timeout]`: block until that event lands (exit non-zero
  on `fail` or timeout). It is the primitive that makes the lab scriptable:
  `vm-boot && await $ID firstlogon 900 && vm-shot done` is the Phase 4
  round-trip test and the Phase 6 clean-box check, not a person watching.

**Not done, and why.** No EMS/SAC console over serial in WinPE (would need BCD
edits and only helps VMs, which already have `vm-shot`; physical targets have no
serial port); no sshd/VNC in WinPE (new binaries and accounts for something
`STOP_BEFORE` + pushed logs cover); no live web dashboard (`status --watch` is a
terminal; if the *Later* dispatcher ever lands, it hosts the same view over the
same log). The one open item is a curl-polling remote shell for `MODE=shell`
machines (open question 6).

## 4. Roadmap

**Phase 1 — restructure (next).** Move the verified spike into the layout above:
`stage-winpe` via 7z (drops sudo), delete WIM injection (`03`), `serve` with a
`/beacon` location and a log format that keeps query strings, `vm-boot` with
`e1000e` + AHCI, `fetch-tools` for curl. Keep the old `setup.exe` path only as a
documented fallback in `docs/history/`.
*Capture groundwork:* `http/images/` holds one WIM per role (`<role>.wim`, the
ISO's `install.wim` becomes `base.wim`); `fetch-tools` also pins the wimlib
Windows binaries (`wimlib-imagex.exe`) for the WinPE-side capture variant.
*Introspection groundwork (§3.2):* `serve` writes `run/beacons.log` and
implements `PUT /uploads/`; the spike's `deploy2.cmd` beacons gain `id`/`run`
and push `ts.log`; `bin/lint`, `bin/status`, `bin/await` and `bin/vm-shot`
exist before Phase 2 starts splitting steps, because they are how Phase 2 is
debugged.

**Phase 2 — task sequence.** Split `deploy2.cmd` into steps (`00-net`,
`10-identify`, `20-disk`, `30-apply`, `35-updates` (optional `dism /add-package`
for an LCU, see 2.7), `40-drivers`, `45-winre`, `50-boot`, `60-unattend`,
`90-reboot`), each reporting a beacon and aborting to a shell on failure.
Per-machine/-model config by product slug, then by UUID/MAC, with one
`MODE` per machine defined here and used everywhere: `deploy` (wipe and
install), `capture` (no wipe, capture `W:\`), `shell` (diagnostic prompt; the
default for any machine not listed). **Recovery partition + WinRE are required,
not optional:** `diskpart.txt` adds a 1 GB recovery partition after the Windows
partition (MS layout: ESP, MSR, Windows, Recovery with the `de94bba4…` GPT type
and `gpt attributes=0x8000000000000001`), the task sequence copies
`W:\Windows\System32\Recovery\Winre.wim` to `R:\Recovery\WindowsRE\` and runs
`reagentc /setreimage /path R:\Recovery\WindowsRE /target W:\Windows`, and a
first-boot check confirms `reagentc /info` reports WinRE enabled (beacon).
*Capture groundwork:* `30-apply` reads the image name from the machine/role
config (so a captured role image is a one-line change), and a second task
sequence `capture.cmd` exists beside `deploy.cmd`: boot WinPE, **no wipe**,
capture `W:\` with `wimlib-imagex.exe capture` (or `dism /capture-image`) and
push the WIM to the server. It is only served to machines whose config says
`MODE=capture`.
*Introspection groundwork:* `env.cmd` + re-runnable steps, `start`/`ok`/`fail`
per step, `STOP_BEFORE`/`STOP_AFTER` in the machine cfg, logs pushed after each
step; `bin/timeline` reproduces the §2.4 table from `beacons.log`.

**Phase 3 — post-install.** winget DSC per role at first logon; upload
`C:\Windows\Panther\*.log`, DISM logs, `reagentc /info` and winget logs to the
`PUT /uploads/` endpoint from §3.2 (`curl -T`); final "deployed" beacon. The
installed OS carries `id` and `run` forward (the task sequence writes them into
`unattend.xml` before copying it to Panther) so the run's timeline continues
across the reboot, and a reliable "I booted" probe replaces the `onstart` task
that never fired (TODO, spikes).
*Capture groundwork:* the same post-install path builds the **reference VM**
for a role (deploy `base.wim` + role DSC), and a `prepare-capture` step runs
`sysprep /generalize /oobe /shutdown` (with an `unattend.xml` that keeps the
DSC-installed software and drops the lab account) so the VM is left ready to
capture.

**Phase 4 — image capture from a reference VM (role images).** Two capture
paths, Linux-side first:

- *Linux-side (preferred, no upload, no WinPE):* after sysprep shutdown,
  `bin/capture-image <vm> <role>`: `qemu-img convert -O raw` the disk, find the
  Windows partition offset with `parted`/`sgdisk`, and run `wimlib-imagex
  capture` on the NTFS volume. The man page documents this libntfs-3g mode
  for block devices; whether it accepts a regular raw file is the first thing
  the spike checks (fallbacks: a loop device or `qemu-nbd`, both needing root,
  or a udisks loop mount). Use a WimScript config that excludes pagefile,
  hiberfil, swapfile, `$Recycle.Bin`, `System Volume Information`. Output
  `http/images/<role>.wim`, LZX, with `--check`. **[unknown, spike first]**
- *WinPE-side (for physical reference machines):* the `capture.cmd` task
  sequence from Phase 2 (`wimlib-imagex.exe capture W:\` or
  `dism /capture-image`), uploaded with `curl -T` to the `PUT /uploads/`
  endpoint (§3.2). **[unknown]**
- *Round-trip test (exit criterion):* deploy `<role>.wim` to a fresh VM with
  the normal task sequence; it must reach the "deployed" beacon with the role's
  software present and WinRE enabled. Keep `base.wim` deployable at all times so
  a bad capture never blocks deployments.
- Keep images honest: record in `http/images/<role>.json` the source VM, date,
  base build, DSC file hash and wimlib version; `stage-image` refuses to serve a
  WIM whose sidecar is missing.

**Phase 5 — real hardware over the network (the goal).** Everything above
exists so this phase is small:

- `pxe-lan` (proxy-DHCP + TFTP) on the real LAN alongside the existing DHCP
  server; `build-ipxe` for the host's LAN IP; verify a UEFI client gets
  `ipxe.efi` and chains to `boot.ipxe` (access log shows its identity).
- Gate destructive steps: only MACs/UUIDs listed in `http/machines/` get the
  wiping task sequence; everyone else gets a diagnostic shell.
- Per-model driver packs from vendor CABs (`pack-drivers`), selected by iPXE
  `${product}`; boot-critical drivers for WinPE via `drvload` (open question 1).
- Secure Boot: reproduce rejection of unsigned `ipxe.efi` in the VM with the
  enforcing vars, then sign with our own key or chain a signed shim, and document
  the enrolment steps for real firmware (open question 3).
- Measure: PXE→desktop time and image transfer rate on the LAN (open question 4):
  `timeline` and the `wim` transfer event give both without extra instrumentation.
- Physical debugging has no screen: `pxe-lan` logs DHCP/TFTP (`dnsmasq
  --log-dhcp`) so "never reached iPXE" is distinguishable from "iPXE never
  chained"; everything after that is `status`/`logs` (§3.2).
- Exit criterion: one physical model deployed repeatably from power-on to a
  configured desktop, documented in `INSTALL.md` "boot a real machine".

**Phase 6 — deployable by others.** `INSTALL.md`, `bin/preflight`, systemd units,
pinned/verified inputs, and a from-scratch run of the install instructions on a
clean machine (see 3.1). The clean-box run is `bin/test-deploy` (vm-create,
vm-boot, `await` each step, `vm-shot` at the end) so it is a command, not a
checklist; `INSTALL.md` has a "watching an install" section built on `status`,
`timeline`, `logs`. Cut a tagged release when that run passes.

**Later / optional — after Phase 6, each spiked before it is layered on.**
Neither is needed for the goal; both are attractive once the static design is
in production and its limits are felt.

- *Streaming apply without the temp file.* On Linux make a pipable WIM
  (`wimexport --pipable` / `wimoptimize --pipable`), and in WinPE run
  `curl … | wimlib-imagex.exe apply - 1 W:\`. Saves the 3.5 GB write + read on
  the target and the space for it. Spike: measure end-to-end time against the
  download-then-`dism` path on the same VM; layer on only if it is faster or
  needed for small disks. **[unknown]**
- *A 50-line dispatcher.* A small Python service that renders `boot.ipxe` and
  `deploy.cmd` per identity (`uuid`, `product`, MAC) instead of static
  per-model directories, and records beacons in a file. Spike: run it beside
  nginx for one machine; layer on only when the directory scheme in
  `http/machines/` becomes the thing people edit by hand most. **[unknown]**

## 5. Open questions

1. Does `drvload` of wimboot-injected .inf/.sys/.cat work for a virtio NIC in
   WinPE? (Decides whether VMs can use virtio end to end without touching
   boot.wim.)
2. winget availability at first logon on a fresh 24H2 Pro image without Store
   access: does `winget configure` run, or is the msixbundle bootstrap needed?
3. Secure Boot enforcing on physical hardware: sign our `ipxe.efi` with our own
   key and enrol it, or chain through a signed shim?
4. Physical-LAN throughput of a 3.5 GB WIM over HTTP versus SMB (expected: no
   difference that matters; measure once).
5. Linux-side capture: does `wimlib-imagex capture` in NTFS mode on a raw
   partition extracted from a sysprepped qcow2 produce a WIM that deploys and
   boots (Phase 4 round-trip)? What must the WimScript exclude?
6. Remote shell for physical machines in `MODE=shell` or after a failure: a
   `cmd` loop that polls `http/machines/<uuid>/cmd.txt` with `curl`, runs it,
   and `PUT`s the output back. Same trust boundary as editing `deploy.cmd`
   (whoever writes to `http/` already runs code as SYSTEM in WinPE), no new
   binaries. Is a 2 s poll usable, and does it need a kill switch? **[unknown]**

## 6. Things deliberately not done

- No SMB/Samba, no credentials on the wire.
- No modification of `boot.wim` on Linux (everything is injected at boot).
- No PowerShell in WinPE (not in the stock image; `cmd` + `cscript` + `curl` cover
  the task sequence).
- No web app or database: static files, nginx, and an access log are the
  "database". Revisit only if per-machine dispatch outgrows directories.
- No serial console, sshd or VNC inside WinPE; introspection is pushed logs and
  beacons over the HTTP channel that already exists (§3.2).
