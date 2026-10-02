# Plan: a small, Linux-hosted replacement for MDT

> **Status (2026-10-02):** this is the *current* plan. **Phases 1 and 2 are
> done** (§4), Phase 4 (role images) is done in its mechanics, and most of the
> open questions of §5 have been answered by experiment
> (`spikes/2026-10-02-unverified-items/`). Phase 3 is next. It supersedes the original design note (now in
> `docs/history/`, together with two early reviews and the retired v1 pipeline).
> What the repo does **today** is documented in `README.md`; this file says where
> it is going and why. Every claim below is tagged **[verified]** (run on this host),
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

WinPE does not have to rediscover the identity at all **[verified, Phase 1]**:
`boot.ipxe` requests `ts/id.cmd?id=${uuid}&mac=${netX/mac}`, nginx answers with
a generated three-line `.cmd` (`SRV` from the request's Host header, `ID`,
`MAC`), and wimboot injects it like any other file. The id a machine reports is
therefore by construction the one the server saw at boot (no SMBIOS byte-order
or case surprises between iPXE and WMI), and nothing under `http/` names a host
or port: `boot.ipxe` uses URLs relative to itself, so the only place the
server's address is written down is `config.sh` (baked into `ipxe.efi`).

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
  at the top of the task sequence with the driver's files injected by wimboot
  **[verified: virtio NIC and disk; `http/winpe-drivers/`, selected by NIC PCI
  id or product name]**; (c) as a last resort, add the driver to boot.wim with
  DISM from inside a WinPE session and capture the result **[unknown]**.

### 2.7 Image curation happens on Linux with wimlib, within known limits

Can do on Linux **[read/verified where marked]**: extract `boot.wim`/`install.wim`
from the ISO without root (`7z x`; today's `02` uses `sudo mount`, unnecessary)
**[verified]**; export a single edition (`wimexport`), recompress/optimise
(`wimoptimize`), add/replace files (`wimupdate`), split (`wimsplit`), build
driver/tool packs (`wimcapture`) **[verified for capture]**; offline registry
edits with `hivexregedit`/`chntpw` **[read]**.

Cannot do on Linux: integrate cumulative updates, add/remove Windows features,
remove provisioned Appx. (Cumulative updates are added in WinPE instead, by step
`35-updates` from an update pack: §4, Phase 2.) The UUP dump Linux converter says so explicitly
(`convert.sh`: "does not and cannot support the integration of updates") and it
is the reason `00b` produces build 26100.1 (24H2 RTM). Do those in WinPE on the
applied image (`dism /image:W:\ /add-package`) or accept Windows Update doing it
post-install.

### 2.8 Post-install configuration: unattend for the OS, winget for software **[partly verified]**

- The Panther `unattend.xml` (specialize + oobeSystem only) sets computer name,
  locale, local admin, autologon, hides OOBE, and runs `FirstLogonCommands`
  **[verified]**.
- winget only exists in the full OS. Plan: a first-logon step that runs
  `winget configure -f <role>.dsc.yaml` (declarative, idempotent) or a plain
  `winget install --id … ` list, with a fallback that installs the App Installer
  msixbundle first. **[verified]**: on an image built from UUP dump winget is
  absent and App Installer is not staged; the release's `msixbundle` with its
  `DesktopAppInstaller_Dependencies.zip` installs at first logon and
  `winget install` then works. `winget configure` (DSC) is still untested.
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
│   ├── fetch-iso             # optional: build a Windows ISO via UUP dump -> iso/
│   ├── build-ipxe            # ipxe.efi with the chain URL (+identity query)
│   ├── stage-winpe           # 7z-extract boot.wim/bootmgfw/BCD/boot.sdi from the ISO
│   ├── stage-image           # ISO -> images/base.wim (wimexport/optimize) + sidecar .json
│   ├── pack-drivers          # vendor pack dir -> drivers/<name>.wim (wimcapture)
│   ├── pack-updates          # dir of .msu/.cab -> updates/<name>.wim
│   ├── fetch-tools           # pinned + hash-checked curl.exe/dll, wimlib-imagex.exe, wimboot
│   ├── serve                 # rootless nginx: static + GET /beacon + PUT /uploads/ (3.2)
│   ├── lint                  # every file boot.ipxe/the task sequence reference exists; cfg + sidecars parse (3.2)
│   ├── status / timeline / await   # read beacons.log: fleet view, per-run step timings, block until a step (3.2)
│   ├── logs                  # what a machine uploaded for a run (3.2)
│   ├── vm-shot / vm-type     # QEMU monitor screendump / sendkey into the lab VM (3.2)
│   ├── vm-stop               # ACPI power-down, then by PID
│   ├── pxe-lan               # dnsmasq proxy-DHCP + TFTP for physical targets; --bridge for a lab bridge
│   ├── lab-netns             # rootless host-only bridge in a network namespace (bridged lab without sudo)
│   ├── vm-create / vm-boot   # lab VM (e1000e + AHCI; virtio once drvload is settled)
│   ├── capture-image         # switched-off, generalized VM disk -> images/<role>.wim (wimlib, on Linux)
│   └── teardown
├── http/                     # everything the target can see, all static
│   ├── boot.ipxe             # default iPXE script: identify, then chain per machines/ config
│   ├── winpe/                # pristine boot.wim, bootmgfw.efi, BCD, boot.sdi, wimboot
│   ├── tools/                # curl.exe, libcurl-x64.dll, wimlib-imagex.exe (+ its dlls)
│   ├── ts/                   # winpeshl.ini, deploy.cmd (runner), env.cmd, step/beacon/push.cmd, *.seq, steps/*.cmd, diskpart/*.txt
│   ├── images/               # base.wim, <role>.wim, each with a <name>.json sidecar
│   ├── drivers/              # <product-slug>.wim driver packs (+ drvload/ for WinPE-side drivers)
│   ├── unattend/             # <role>.xml Panther unattend files
│   ├── post/                 # <role>.dsc.yaml (winget) + first-logon scripts
│   ├── machines/             # <uuid>.cfg: MODE, IMAGE, DRIVERS, UPDATES, STOP_BEFORE/AFTER… (its README)
│   ├── models/               # <product-slug>.cfg: per-model defaults; can never set MODE (its README)
│   ├── updates/              # <name>.wim update packs (bin/pack-updates) for step 35-updates
│   ├── winpe-drivers/        # drivers WinPE itself lacks: <nic-pci-id>.ipxe / model-<product>.ipxe snippets (its README)
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
- Reproducible inputs: `fetch-tools` pins by SHA-256 and refuses anything else
  (curl.exe, wimboot, wimlib, virtio-win), `build-ipxe` pins an iPXE commit
  **[done, Phase 1]**; the README says which Windows build the flow was last
  verified against. Pin by hash, never by version: upstream replaced the
  `wimboot v2.9.0` asset with a different binary under the same tag.
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

- `id` is the SMBIOS UUID, lowercase, exactly as iPXE reported it: the server
  hands it to WinPE in `ts/id.cmd` (§2.2), and the task sequence leaves it in
  `C:\pdt\id.cmd` for the installed OS **[verified]**. `run` is a token the task sequence mints at
  `ts-start` (`%RANDOM%`-based is enough) and repeats on every later event and
  upload path, so two boots of the same machine never interleave. (`%RANDOM%`
  is seeded from the clock: two VMs started in the same second minted the same
  token **[verified]**. That is harmless, because events and uploads are always
  keyed by `id` *and* `run`; never treat `run` as globally unique.)
- Every step sends `ev=start` *and* `ev=ok|fail`. A `start` with nothing after
  it is the answer to "where is it stuck" (in DISM, in a download) without a
  screenshot. The first event of a run also carries `mode`, `product`, `mac`.
- `serve` logs `location = /beacon` to its own file with its own format:
  `log_format beacon '$time_iso8601 $msec $remote_addr $args'` →
  `run/beacons.log` **[verified]**. Append-only, never rotated away; boot-file
  requests stay in the access log. Two synthetic events are derived from the
  access log by the tools, not sent by anyone: `ipxe` (the `boot.ipxe?…`
  request with identity) and `wim` (`boot.wim` served in full, with
  `$request_time` in the access-log format so transfer rate falls out for free;
  open question 4).

**Logs.** Everything a step prints goes to `X:\pdt\ts.log` (console shows only
banners), DISM is pointed at `X:\pdt\dism.log` with `/LogPath` **[verified]**, and
`deploy.cmd` pushes both after every step and on failure:

```
curl -sS -T X:\pdt\ts.log %SRV%/uploads/%ID%/%RUN%/ts.log
```

The endpoint is defined once, here, and implemented by `serve` in Phase 1:
`PUT /uploads/<id>/<run>/…` via nginx's `http_dav_module` (present in Ubuntu's
nginx build **[verified]**), with `dav_methods PUT`, `create_full_put_path on`,
`client_max_body_size 0` **[verified]**; write-only (`limit_except PUT { deny all; }`:
a GET of an uploaded file is refused, and `serve` self-tests exactly that on
every start), never listed or served back.
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
box that PXE-boots shows up in `status` as "shell, waiting" **[verified]**. On
failure: `fail` beacon with `step`+`rc`, push logs, shell **[verified]**.
Nothing destructive happens before a `preflight` step has confirmed that every
file the install needs (image, unattend, diskpart script, driver pack, post
scripts) is on the server: a typo in a cfg costs a reboot, not a disk
**[verified: the first version wiped the disk and then failed the download]**. The VM screen (`vm-shot`) and blind
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

**Phase 1 — restructure. DONE 2026-10-02** (evidence: `README.md`
"Verification"). Delivered as planned, plus four things pulled forward because
they were cheaper to build in than to add: `MODE` gating from `machines/<uuid>.cfg`
(default `shell`), the `preflight` step, the iPXE→WinPE identity hand-off
(`ts/id.cmd`, §2.2), and `specialize`/`firstlogon` beacons with Panther log
upload from the installed OS. Follow-ups the same day: bridged networking with
real DHCP + TFTP verified inside a rootless network namespace (`bin/lab-netns`,
`spikes/2026-10-02-bridged-lab-netns/`), and the v1 ISO builder ported as
`bin/fetch-iso`. Still not exercised: proxy-DHCP on a real LAN. The original scope, for the record:
Move the verified spike into the layout above:
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

**Phase 2 — task sequence. DONE 2026-10-02** (evidence:
`spikes/2026-10-02-phase2-acceptance/`). What was built, and where it differs
from what was planned:

- *Steps are fetched, not injected.* wimboot can only inject flat files into
  System32, and injecting every step would mean touching `boot.ipxe` per step.
  Instead the injected `deploy.cmd` is a bootstrap + runner: it brings up the
  network, identifies the machine, then downloads `env.cmd`, the helpers, the
  sequence file for the machine's `MODE` and the steps it lists into `X:\pdt\`,
  **on every run**. So a step edited on the server is picked up by typing
  `deploy NN` at the prompt: no reboot **[verified]**. Network and identify
  therefore live in the bootstrap, not in `00-`/`10-` step files.
- *A MODE is a sequence file.* `ts/deploy.seq` and `ts/capture.seq` list step
  names; `MODE=shell` runs nothing. There is no separate `capture.cmd`. A new
  mode is a new `.seq`.
- *Steps:* `15-preflight`, `20-disk`, `25-download`, `30-apply`, `35-updates`,
  `40-drivers`, `45-winre`, `50-boot`, `60-unattend`, `90-reboot`; `70-capture`
  for capture. Each is a small file that `call`s `env.cmd` first, returns its
  exit code, and may leave one line in `step.msg` (why it failed, or that it had
  nothing to do). `step.cmd <name>` wraps one step with `start`/`ok`/`fail`
  beacons and the log push, exactly as the runner does **[verified]**.
- *`STOP_BEFORE` / `STOP_AFTER`* (step name or number) in the machine cfg leave
  a prompt with the environment loaded; `deploy NN` resumes and ignores them
  **[verified]**.
- *Per-model defaults* live in `http/models/<slug>.cfg`, the slug computed in
  WinPE by `ts/slug.js` from the SMBIOS product name. A model file can set
  `IMAGE`/`UNATTEND`/`DISKPART`/`DRIVERS`/`UPDATES` and **cannot** set `MODE` or
  `STOP_*`: `env.cmd` ignores them there and `lint` rejects them **[verified:
  a model file saying `MODE=deploy` left an unlisted VM at the prompt, disk
  untouched]**.
- *Recovery partition + WinRE, required:* the layout is ESP, MSR, Windows,
  1 GB Recovery (`de94bba4…`, attributes `0x8000000000000001`); `45-winre`
  copies `Winre.wim` there and runs `reagentc /setreimage`; at first logon the
  installed system beacons `winre ok` only if `reagentc /info` says Enabled
  **and** the location is not the Windows partition **[verified: Enabled on
  partition 4, Windows on 3]**. Two things learned: (1) with a recovery
  partition present Windows moves WinRE there by itself on first boot even when
  `45-winre` is skipped, so the partition is what matters and the step makes it
  deterministic; (2) without a recovery partition `45-winre` fails by name, and
  if it is bypassed the first-logon check reports `winre fail` (WinRE left on
  the Windows partition) **[both verified]**.
- *`35-updates`:* `bin/pack-updates` wraps `.msu`/`.cab` files in a WIM;
  `UPDATES=<name>` makes the step apply it and run `dism /add-package`.
  **[verified]**: a pack holding the 24H2 checkpoint update (KB5043080) and the
  cumulative update for 26100.9550, targeted at the latter, took a 26100.1 image
  to **26100.9550** offline in WinPE (about nine minutes), as reported by the
  installed system at first logon. This closes the gap left by §2.7 (no update
  integration on Linux): the image stays a stock base image and the update is a
  pack beside it. Two things the pack must say, both learned by running it:
  `--target <file>` (the update to install; anything else in the pack is a
  prerequisite DISM draws on. Given the folder instead, the 26100.1 DISM fails
  on the checkpoint as a package of its own and exits 552 after installing the
  cumulative update anyway), and `--expect <version>` (the step then judges by
  `dism /get-packages` listing that package as installed, not by DISM's exit
  code; a wrong expectation fails the step even when DISM exits 0).
- *Capture groundwork:* `MODE=capture` runs `70-capture`: `dism /capture-image`
  of the installed volume to `<vol>\pdt\capture.wim` (the `\pdt` tree is
  excluded from the image, which also keeps the reference machine's identity
  out of it), then `curl -T` to `/uploads/<id>/<run>/capture.wim`
  **[verified: 4.67 GB in 95 s, `wimlib-imagex verify` clean, no pagefile /
  hiberfil / `\pdt` inside, source disk untouched]**. Applied to a fresh VM the
  un-sysprepped image booted to a working desktop **[verified]**. It failed
  `45-winre` first, and rightly: a captured volume has no `Winre.wim`, because
  Windows moved it to the recovery partition. Phase 4 must deal with that.
- *Two properties of WinPE's `cmd` that shaped the runner* **[verified, the hard
  way]**: (1) the Setup `boot.wim` has `find` but **no `findstr`**; (2) a pipe
  to a program that does not exist ends batch processing altogether, callers
  included, silently: the first version of `35-updates` used `findstr` in a
  pipe and the whole sequence simply stopped, with no `fail` event. So every
  step now runs in a child `cmd` (an aborted step costs only itself and comes
  back as `rc=255`, reported with `msg=the step was cut short`), and `lint`
  reads the program list out of `boot.wim` and fails any `ts/` script that runs
  a program WinPE does not have.
- *Logs while a step runs:* `pushloop.cmd` pushes the logs every 20 s during a
  step, so a ten-minute DISM can be followed with `bin/logs`, and `bin/status`
  shows such a machine as `busy` rather than `STUCK?`. DISM's log moves to the
  Windows partition as soon as it exists (one cumulative update at the default
  log level wrote 444 MB; the RAM disk is no place for that).
- *`bin/timeline`* was not built: `bin/status <id>` prints every event of a
  boot with per-step timings, which is the §2.4 table computed.
- *`bin/lint`* knows sequences, steps, the fetched toolkit, `STOP_*`, model
  files and cfg hygiene; its self-test injects 21 defects.

**Phase 3 — post-install (next).** Known from the spikes: winget is not in
the image and has to be bootstrapped from the release's `msixbundle` +
`DesktopAppInstaller_Dependencies.zip` (so: fetched and pinned by `fetch-tools`,
served from `http/post/`, installed by the first-logon script before anything
uses it); the `POST=` key already lets a machine or model name a first-logon
script; a boot probe needs two triggers (§5.8). Then: winget DSC per role at first logon; upload
`C:\Windows\Panther\*.log`, DISM logs, `reagentc /info` and winget logs to the
`PUT /uploads/` endpoint from §3.2 (`curl -T`); final "deployed" beacon. The
installed OS carries `id` and `run` forward so the run's timeline continues
across the reboot (done in Phase 1 without templating XML: the task sequence
leaves `C:\pdt\id.cmd` + `beacon.cmd`, and the unattend calls them
**[verified]**), and a reliable every-boot "I booted" probe replaces the
`onstart` task that never fired (TODO, spikes; `beacon.cmd` already retries
until the network is up).
*Capture groundwork:* the same post-install path builds the **reference VM**
for a role (deploy `base.wim` + role DSC), and a `prepare-capture` step runs
`sysprep /generalize /oobe /shutdown` (with an `unattend.xml` that keeps the
DSC-installed software and drops the lab account) so the VM is left ready to
capture.

**Phase 4 — image capture from a reference VM (role images). Mechanics DONE
2026-10-02** (evidence: `spikes/2026-10-02-unverified-items/` §2):

- *Reference machine:* `REFERENCE=yes` in its cfg (`bin/vm-create --reference`).
  After first logon and the `POST=` script, `post/prepare-capture.cmd` stamps
  the image, runs `sysprep /generalize /oobe` and shuts down fully **[verified]**.
- *Linux-side capture* (`bin/capture-image <vm> <role>`, VM switched off):
  `qemu-img convert`, the Windows partition cut out with `dd`, `wimlib-imagex
  capture` in NTFS mode straight from that file, LZX, `--check`; 89 s
  **[verified]**.
- *WinPE-side capture* (`MODE=capture`, for machines whose disk the server
  cannot read): `dism /capture-image`, upload, then `bin/stage-image
  --from-upload <vm> --name <role>` **[verified]**. `70-capture` reports the
  image state read from the offline registry (generalized or not), because the
  generalized machine cannot report it itself: sysprep removes its NIC.
- *`Winre.wim`:* a captured volume never has one (and `reagentc /disable` does
  not bring it back). `stage-image` keeps `images/<name>.winre.wim` beside every
  image and `45-winre` falls back to it **[verified]**.
- *Round trip (the exit criterion):* machines deployed from both captures ran
  specialize and first logon as new machines, carried the reference's stamp,
  and reported `winre ok` **[verified]**.
- *Sidecars:* kind, source machine/VM/run, method, build, size, SHA-256, wimlib
  version; `lint` refuses an image whose sidecar is missing or does not match.

What remains of Phase 4 is what Phase 3 brings: the role's software in the
reference before capture, and its DSC file hash in the sidecar.

**Phase 5 — real hardware over the network (the goal).** Everything above
exists so this phase is small:

- `pxe-lan` (proxy-DHCP + TFTP) on the real LAN alongside the existing DHCP
  server (proxy mode beside a second DHCP server is **[verified in `lab-netns`]**
  for iPXE-ROM and firmware clients; a real switch and router are not); `build-ipxe` for the host's LAN IP; verify a UEFI client gets
  `ipxe.efi` and chains to `boot.ipxe` (access log shows its identity).
- Gate destructive steps: only MACs/UUIDs listed in `http/machines/` get the
  wiping task sequence; everyone else gets a diagnostic shell.
- Per-model driver packs from vendor CABs (`pack-drivers`), selected by model
  slug (`models/<slug>.cfg`); drivers WinPE itself lacks via
  `http/winpe-drivers/` + `drvload`, selected by NIC PCI id or product name
  **[both verified in VMs, including the firmware-PXE path with no option ROM]**.
- Secure Boot: rejection of the unsigned binary and a full deploy with our
  signed one are **[verified in a VM]** (`SB_KEY`/`SB_CERT`, `bin/build-ipxe`).
  What is left is real firmware: enrol the certificate in db on one machine and
  document the vendor's steps.
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
checklist; run inside `bin/lab-netns` it also covers DHCP + TFTP from dnsmasq
without needing root, which makes it usable in CI; `INSTALL.md` has a "watching an install" section built on `status`,
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

Answered on 2026-10-02 (`spikes/2026-10-02-unverified-items/`):

1. *`drvload` of wimboot-injected drivers:* **yes.** A VM with a virtio NIC and
   a virtio disk deploys end to end; `boot.wim` stays untouched. Inject every
   file the `.inf` names. Select the snippet by NIC PCI id or product name,
   never by iPXE's chip name (`SNP` on the firmware-PXE path).
2. *winget at first logon:* **absent** on an image built from UUP dump (App
   Installer is not staged). The release's `msixbundle` with
   `DesktopAppInstaller_Dependencies.zip` installs at first logon and winget
   then works. Phase 3 must fetch, pin and serve those packages.
3. *Secure Boot enforcing:* unsigned `ipxe.efi` is refused ("Access Denied");
   signed with our own key and the certificate enrolled in db, a VM deploys and
   Windows reports Secure Boot on. `wimboot` and Windows' boot files are
   Microsoft-signed already, so a shim is not needed. **Open:** enrolling a
   certificate in real firmware (manual, per vendor).
5. *Linux-side capture:* **yes.** wimlib's NTFS mode reads a volume from a
   plain file; `bin/capture-image` exists; the result deploys as a new machine.
7. *`${next-server}` instead of a baked-in server address:* **no.** Behind
   proxy-DHCP it is the router, not us.
8. *A reliable every-boot probe:* two scheduled tasks, "at startup" (restarts,
   cold boots) and one on System event Kernel-Boot 27 (fast-startup power-ons).

Still open:

4. Physical-LAN throughput of a 3.5 GB WIM over HTTP versus SMB (expected: no
   difference that matters; measure once).
6. Remote shell for physical machines in `MODE=shell` or after a failure: a
   `cmd` loop that polls `http/machines/<uuid>/cmd.txt` with `curl`, runs it,
   and `PUT`s the output back. Same trust boundary as editing `deploy.cmd`
   (whoever writes to `http/` already runs code as SYSTEM in WinPE), no new
   binaries. Is a 2 s poll usable, and does it need a kill switch? **[unknown]**
9. The Safe OS dynamic update is not applied to the recovery image, so WinRE
   stays at the base build while the OS is updated by `35-updates`.

## 6. Things deliberately not done

- No SMB/Samba, no credentials on the wire.
- No modification of `boot.wim` on Linux (everything is injected at boot).
- No PowerShell in WinPE (not in the stock image; `cmd` + `cscript` + `curl` cover
  the task sequence).
- No web app or database: static files, nginx, and an access log are the
  "database". Revisit only if per-machine dispatch outgrows directories.
- No serial console, sshd or VNC inside WinPE; introspection is pushed logs and
  beacons over the HTTP channel that already exists (§3.2).
