# Penguin Deployment Toolkit

*Deploy Windows 11 over the network from a Linux host: iPXE + WinPE + DISM. A
small, Linux-hosted stand-in for Microsoft Deployment Toolkit: the penguin does
the deploying, Windows does the installing.*

No Windows machine, no ADK, no MDT, no SMB share. The Linux host serves files
over HTTP; Windows PE on the target does the install with Microsoft's own tools
(`diskpart`, `dism`, `bcdboot`, an unattend file), following a plain-text task
sequence the host serves.

> **Status (2026-10-02).** Phases 1 to 4 of `PLAN.md` are done: install,
> step-based task sequence, post-install roles (winget, scripts, policy) and
> role images. The layout below is what runs, verified end to end in lab VMs
> (see [Verification](#verification)). Real hardware (Phase 5) and an install
> guide for other people (Phase 6) are not done yet; `TODO.md` has the order of work. The first version of this repo
> (Windows Setup + `autounattend.xml`) is retired to `docs/history/v1-setup-exe/`.

## How a machine gets installed

```
firmware PXE ─TFTP→ pxe/ipxe.efi            the one binary we build; embeds one URL
  └─ iPXE ─HTTP→ http/boot.ipxe             static; loads wimboot + a PRISTINE boot.wim
       └─ wimboot injects into X:\Windows\System32:
            winpeshl.ini, deploy.cmd, id.cmd, curl.exe
            └─ WinPE runs deploy.cmd, which fetches the rest from the server:
                 machines/<uuid>.cfg says MODE=deploy?  no → report, stop at a prompt
                 then the steps listed in ts/deploy.seq, one file each:
                 15-preflight  everything this install needs is on the server
                 17-diskguard  which disk: the only fixed one, or DISK=<n>; else refuse
                 20-disk       diskpart on that disk (GPT: ESP, MSR, Windows, Recovery)
                 25-download   images/base.wim over HTTP
                 30-apply      dism /apply-image
                 35-updates    optional update pack → dism /add-package
                 40-drivers    optional driver pack → dism /add-driver
                 45-winre      recovery environment onto the recovery partition
                 50-boot       bcdboot
                 60-unattend   Panther unattend.xml + C:\pdt\ scripts
                 90-reboot
                 └─ installed Windows: specialize → first logon → WinRE check → desktop
```

Every step reports `start` and `ok`/`fail` to the server and pushes its logs
there, so an install can be followed, and a failure diagnosed, without looking
at the machine's screen.

**Nothing is wiped unless you list the machine.** A machine is deployed only if
`http/machines/<its SMBIOS UUID>.cfg` exists and says `MODE=deploy`. Any other
machine that PXE-boots gets WinPE at a prompt, shows up in `bin/status`, and is
left untouched. Per-model defaults (`http/models/<slug>.cfg`, typically the
driver pack) can never set `MODE`.

**Developing or debugging a step.** Put `STOP_BEFORE=40-drivers` in the
machine's cfg and boot it: the sequence stops there with a prompt and the whole
environment loaded. Run the step by hand to watch it
(`X:\pdt\steps\40-drivers.cmd`), edit it on the server, then type `deploy 40`:
that re-fetches every step and carries on from 40. No reboot, nothing rebuilt.

## Quick start (lab VM on this host)

Needs Ubuntu 24.04 or 26.04 with KVM, plus: `qemu-system-x86 qemu-utils ovmf ipxe-qemu
nginx wimtools p7zip-full socat uuid-runtime curl unzip python3 python3-pil
build-essential liblzma-dev git`. And a Windows 11 ISO. Plus podman or docker
(or `gcc-mingw-w64-x86-64` for `bin/build-tools host`) for `bin/build-tools`, which
builds the hasher `25-download` verifies every image with (WinPE has no certutil)
and the screen pusher, reproducibly in a pinned container. Optional:
`mmdebstrap zstd` for the collector (`bin/build-collector`).

```bash
cp config.sh.example config.sh     # set ISO_PATH; pick a free HTTP_PORT
bin/fetch-iso                      # only if you have no ISO: builds one via UUP dump (4-6 GB)
bin/fetch-tools                    # wimboot, curl.exe, wimlib for Windows (pinned by hash)
bin/fetch-tools winget             # if roles install apps: winget + dependencies, served to first logon
bin/fetch-tools openssh            # if roles say SSH=on: Win32-OpenSSH (MSI), then the lab keys into every such role (fetch-tools keys)
bin/stage-winpe                    # boot.wim + boot files out of the ISO (7z, no sudo)
bin/stage-image                    # install.wim -> http/images/base.wim + sidecar
bin/build-ipxe                     # pxe/ipxe.efi, chaining to HTTP_HOST:HTTP_PORT
bin/serve                          # rootless nginx on HTTP_PORT, self-tested
bin/lint                           # every referenced file exists; exit 1 if not

bin/vm-create lab01                # empty disk + machines/<uuid>.cfg with MODE=deploy
                                   #   (--role <name>, --nic/--disk virtio, --reference, --image <role>: see --help)
bin/vm-boot lab01                  # headless; PXE → WinPE → install
bin/await lab01 deployed 900       # blocks until first logon has done the role (or something fails)
bin/status lab01                   # every event of that boot, with timings
bin/vm-shot lab01                  # screenshot, if you want to look
```

None of it needs root. `bin/teardown` stops everything; `bin/teardown --purge`
also deletes the lab VMs and logs.

## The bridged lab, without root

The quick start uses QEMU's user-mode network, where QEMU itself plays DHCP and
TFTP server. To exercise what real hardware does (DHCP and TFTP from dnsmasq,
VMs on a bridge) without sudo, run the lab inside a private network namespace:

```bash
# config.sh: HTTP_HOST="10.42.0.1"   then: bin/build-ipxe
bin/lab-netns up                                  # bridge br0 = 10.42.0.1/24, visible only inside
bin/lab-netns run bin/serve
bin/lab-netns run bin/pxe-lan --bridge br0 10.42.0.100,10.42.0.199 start
bin/vm-create lab01 --net bridge:br0
bin/lab-netns run bin/vm-boot lab01
bin/await lab01 firstlogon 900                    # reads log files: works from outside
bin/lab-netns run bin/vm-shot lab01               # talks to QEMU: must run inside
bin/lab-netns down                                # stops everything inside
```

Nothing on the host's network is touched and the VMs have no internet. It needs
unprivileged user namespaces; on a stock Ubuntu 24.04 host that restricts them,
`bin/lab-netns up` says so and `bin/lab-netns profile` prints the AppArmor
profile that allows exactly this tool (two sudo commands to install). The same
lab on a real host bridge, with root, is `docs/LAB_FROM_SCRATCH.md`.

## Watching and debugging an install

| command | what it tells you |
|---|---|
| `bin/status [--watch]` | one row per machine: last event, age, mode, product, model slug. `FAIL` is flagged; a step running for long is `busy` while it keeps pushing logs and `STUCK?` when it has gone silent |
| `bin/status <id\|vm>` | every event of that machine's latest boot with timings (iPXE request, `boot.wim` transfer rate, each step) |
| `bin/await <id\|vm> <step> [secs]` | block until that step reports ok; exit 1 on any `fail`, 2 on timeout. Makes the lab scriptable |
| `bin/logs <id\|vm> [--cat ts.log]` | what the machine uploaded: `ts.log`, `dism.log`, `reagentc.txt`, Setup's Panther logs. Pushed every 20 s while a step runs, so `--tail 5 ts.log` follows a long step live |
| `bin/lint [-v]` | static check of `http/` and the host set-up; self-tests by injecting known defects |
| `bin/tests [-v] [name...]` | the host-side suite: every lab-driving `bin/` script against a sandbox repo and a fake QEMU, the Python helpers, the reboot-hang spike's tools; a test file that fires no control fails (`tests/README.md` says what is covered where) |
| `bin/vm-shot`, `bin/vm-type` | screenshot / type into a lab VM through the QEMU monitor (last resort; VMs only) |
| `bin/shell <id\|vm> '<command>'` | the same for any machine in WinPE, over HTTP: output in ~2 s, exit code passed through; `--off` stops the loop (`docs/REMOTE_VISIBILITY.md`) |

Raw data, if you prefer `tail -f`: `run/beacons.log` (one line per event),
`run/access.log` (every file request, with transfer time), `http/uploads/<id>/<run>/`.

## Repository map

| Path | What it is |
|---|---|
| `config.sh.example` | template for `config.sh`, the only place host-specific values live |
| `bin/lib.sh`, `bin/_pdt.py` | shared by every script: loads `config.sh`, paths, helpers (bash and python) |
| `bin/fetch-iso` | optional: build a Windows 11 ISO from Microsoft's update servers via UUP dump, into `iso/` with a sidecar (base build only: no cumulative updates on Linux) |
| `bin/fetch-tools` | third-party binaries, pinned by SHA-256, into `http/winpe/` and `http/tools/`; `fetch-tools virtio` builds a virtio driver pack; `fetch-tools winget` serves winget and its dependencies from `http/post/winget/`; `fetch-tools openssh` serves the Win32-OpenSSH installer from `http/post/openssh/`; `fetch-tools keys` (also run by `openssh`) writes the lab keys into every role with `SSH=on`: its `SSHKEYS` file from `~/.ssh/id_*.pub`, and a key pair of its own for each `keys=<file>` account (private half `build/lab-<account>`) |
| `bin/stage-winpe` | `boot.wim`, `bootmgfw.efi`, `BCD`, `boot.sdi` from the ISO, unmodified |
| `bin/stage-image` | the ISO's install image → `http/images/base.wim` + `base.json` + `base.winre.wim` + `base.winre.json`; `--from-upload <vm>` publishes an image captured by `MODE=capture`; `--sidecars` describes recovery images staged before they had sidecars |
| `bin/capture-image` | capture a role image from a switched-off, generalized lab VM's disk on Linux (wimlib), publish it |
| `bin/pack-drivers` | a directory of drivers → `http/drivers/<name>.wim` + a sidecar with its SHA-256 (`--rehash <name>` adds the hash to a pack made before 2026-10-24) |
| `bin/fetch-drivers` | a vendor driver pack by URL (Dell/Lenovo/HP `.CAB`/`.zip`), pinned by SHA-256 on the second run, unpacked and packed as above; the sidecar records the source |
| `bin/pack-updates` | a directory of `.msu`/`.cab` updates → `http/updates/<name>.wim` + a sidecar with its SHA-256; `--target` names the update to install (others are prerequisites), `--expect` the package version that must end up installed; `--rehash <name>` as above |
| `bin/build-ipxe` | builds `pxe/ipxe.efi` from a pinned iPXE commit |
| `bin/serve` | rootless nginx: static files, `GET /beacon`, `GET /ts/id.cmd`, `PUT /uploads/` |
| `bin/pxe-lan` | dnsmasq + TFTP: proxy-DHCP for a real LAN (not yet run against hardware), or `--bridge` authoritative DHCP for a lab bridge (verified) |
| `bin/lab-netns` | a rootless host-only bridge in a private network namespace, for running the bridged lab without sudo |
| `bin/vm-create`, `vm-boot`, `vm-stop`, `vm-shot`, `vm-type` | the lab VM |
| `bin/status`, `await`, `logs`, `lint` | read-only tools over the logs and `http/` |
| `bin/shell` | run a command on a machine in WinPE over HTTP (`ts/shell-loop.cmd` polls for it); for machines with no screen, i.e. every physical one |
| `bin/console`, `bin/keys` | the text frames of the machine's deploy window (`tools/pdt-console.exe` reads the console buffer; one frame per change, `--watch`, `--frames`, `--diff`, `--await TEXT`), and keystrokes into that window (`bin/keys <m> 'deploy 20{enter}'` answers the prompt a stopped or failed sequence sits at, which a new `cmd` from `bin/shell` cannot) |
| `bin/screen`, `bin/build-tools` | the latest screen a machine pushed (needs `tools/pdt-screen.exe`); `build-tools` builds it, `tools/pdt-sha256.exe` (the hash every image, pack and recovery image is checked with on the machine) and `tools/pdt-console.exe` from `tools-src/` with mingw-w64 in a pinned container, reproducibly: two builds must be identical; `build-tools openssl` cross-builds a static `tools/openssl.exe` from the pinned OpenSSL source the same way, as an independent second opinion on the machine; `check` verifies the served binaries against `tools/built.json` (lint runs it) |
| `bin/build-collector`, `bin/netboot`, `bin/enroll` | the collector: a small Debian that PXE-boots into RAM, inventories a machine, takes commands and SSH, and reboots it into Windows PE; which machines boot it; `machines/<uuid>.cfg` from its inventory (`docs/COLLECTOR.md`) |
| `bin/teardown` | stop services; optionally delete lab state |
| `bin/smoke` | the whole toolkit end to end on two lab VMs at once (roles `demo-ssh` and `demo-rdp`, a USB stick and an SD card beside the one fixed disk, every download's hash, the console frames and keys, SSH and RDP from this host with controls), every check a PASS/FAIL row in `report.md` beside the screenshots, timelines and uploads; exits 0 only if nothing failed and at least one control fired |
| `http/boot.ipxe` | the iPXE script every target runs (static, relative URLs) |
| `http/ts/` | the WinPE task sequence: `deploy.cmd` (bootstrap + runner), `env.cmd` (all state), `step.cmd`/`beacon.cmd`/`push.cmd` (helpers), `verified.cmd` (every large download, checked against its sidecar's SHA-256 before use), `shell-loop.cmd` (the remote shell, screen pusher and console frames), `*.seq` (which steps a MODE runs), `steps/` (one file per step), `diskpart/` |
| `tools-src/` | source of the toolkit's own Windows programs (`pdt-screen.c`, `pdt-sha256.c`, `pdt-console.c`), built by `bin/build-tools` |
| `http/unattend/` | Panther unattend files (`default.xml`: local admin `deploy`, **blank password**, one autologon: lab defaults) |
| `http/post/` | scripts run by the installed system from `C:\pdt\`: `firstlogon.cmd` (orchestrates the rest), `winget.cmd` (bootstrap + the role's apps), `users.ps1` (the role's accounts; generated passwords uploaded, then removed), `boot-probe.cmd` (a `boot` beacon after every boot), `prepare-capture.cmd` (sysprep, for `REFERENCE=yes`), and your own (`POST=` in a cfg); `winget/` holds the fetched packages (not tracked) |
| `http/roles/` | `<name>/role.cfg` + files: what a machine becomes after Windows is on it (winget apps, local accounts, a skel for new profiles, post script, unattend, fast-startup policy); `ROLE=<name>` in a cfg selects it (see its README) |
| `http/winpe-drivers/` | drivers WinPE itself needs, injected per NIC PCI id or product (see its README; generated content not tracked) |
| `http/boot/`, `http/collector/` | per-machine boot overrides written by `bin/netboot`; the collector image built by `bin/build-collector` (both not tracked) |
| `http/machines/` | `<uuid>.cfg` per machine: MODE and overrides (not tracked; see its README) |
| `http/models/` | `<product-slug>.cfg` per hardware model: defaults such as the driver pack (not tracked; see its README) |
| `http/winpe/ tools/ images/ drivers/ updates/ uploads/` | fetched, extracted, packed or uploaded content (not tracked) |
| `iso/` | ISOs built by `bin/fetch-iso` (not tracked) |
| `pxe/` | TFTP root: `ipxe.efi`, generated `dnsmasq.conf` (not tracked) |
| `run/` | nginx config, pid, logs, `beacons.log` (not tracked) |
| `vms/` | lab VMs: disk, NVRAM, `vm.conf` (not tracked) |
| `docs/` | `HOW_IT_WORKS.md` (tour), `CONTROL_POINTS.md` (where an admin changes what a machine gets, and when it takes effect), `REMOTE_VISIBILITY.md` (machines you cannot sit at), `COLLECTOR.md` (the Linux inventory image), `LAYERS.md` (each layer and how to extend it), `MANUAL_TESTING.md` (the hand-run procedure), `LAB_FROM_SCRATCH.md` (bridged-lab runbook), `REVIEW-2026-10-12.md` (outside review before the first physical machine), `history/` (retired v1 and old reviews) |
| `spikes/` | dated experiments with their evidence |

## Design points worth knowing

- **`boot.wim` is never modified.** wimboot copies extra files into
  `X:\Windows\System32` at boot. Changing the install is editing a text file
  under `http/ts/` and rebooting the target.
- **`winpeshl.ini`, not `startnet.cmd`.** wimboot appends files without checking
  for an existing name; `startnet.cmd` already exists in the image.
- **Identity is decided once, by iPXE.** `boot.ipxe` requests
  `ts/id.cmd?id=${uuid}&mac=…`; nginx answers with a three-line `.cmd` (`SRV`,
  `ID`, `MAC`) that wimboot injects. WinPE therefore knows who it is and where
  the server is without detecting anything, and the id it reports is by
  construction the one the server saw at boot.
- **HTTP only.** Stock WinPE has no `curl`, PowerShell or `bitsadmin`, so the
  official Windows `curl.exe` is injected too.
- **What a machine becomes is a directory.** `ROLE=<name>` names
  `http/roles/<name>/`: a winget list, local accounts, a skel (files for
  `C:\Users\Default`, Windows' `/etc/skel`), a post script, an unattend, the
  fast-startup policy. Generated passwords travel one way, machine → server's
  write-only uploads, and are deleted from the machine. First logon works through it and ends with a `deployed`
  beacon; a reference machine with a role bakes it into the image it becomes,
  and the image's sidecar records which role and which apps list.
- **A recovery partition, always.** The disk layout ends with a 1 GB recovery
  partition and step `45-winre` puts WinRE on it; the installed system then
  reports whether WinRE is enabled and *not* on the Windows partition.
- **Lab hardware WinPE already understands.** e1000e NIC and AHCI disk (inbox
  drivers). No TPM: the apply path performs no Windows 11 hardware check.
- **Pinned by hash, not by version.** The `wimboot` `v2.9.0` release asset was
  replaced upstream with different contents under the same version; `fetch-tools`
  refuses a download whose SHA-256 is not the reviewed one.
- **Secure Boot.** The lab VM's firmware is capable but not enforcing (OVMF
  secboot build with empty variables), so an unsigned `ipxe.efi` loads.
  Enforcing firmware refuses it; set `SB_KEY`/`SB_CERT` in `config.sh` and
  `bin/build-ipxe` signs it, after which the certificate has to be enrolled in
  each machine's firmware. `wimboot` and Windows' boot files are already signed
  by Microsoft. Verified in a VM with enforcing variables; not on hardware.

## Verification

Five passes, all on this host, all in lab VMs, each with its evidence under
`spikes/`: the Phase 1 acceptance, the bridged lab and ISO builder, the Phase 2
acceptance, the "not verified" list worked through (twice, the second time
with root supplied by hand), and the Phase 3 acceptance. Nothing has run on
physical hardware.

Verified on 2026-10-02 on this host (Ubuntu 24.04, QEMU 8.2, Windows 11 Pro
24H2 build 26100.1), entirely through `bin/`, as an unprivileged user. Evidence:
`spikes/2026-10-02-phase1-acceptance/`.

| what | result |
|---|---|
| Full deploy, lab VM, with a driver pack | PXE to `firstlogon` in 140 s (preflight 0.2 s, disk 4 s, 3.5 GB download 12 s, `dism` apply 47 s, drivers 1.5 s, first boot to first logon 67 s); desktop confirmed by screenshot |
| Unlisted machine (no `machines/` entry) | boots WinPE, reports `shell`, disk untouched |
| Cfg naming a missing image | `preflight fail` naming the file, disk untouched, `bin/await` exits 1, log uploaded |
| Driver pack | VM deployed with `virtio-w11` has network on a virtio NIC; VM deployed without it has none (same NIC, cold boot) |
| `bin/lint` | 11/11 injected defects reported; real tree all PASS; FAILs on a deliberately broken cfg |
| `bin/serve` | self-test on every start: uploads stored, not readable back; malformed id rejected |

Two things the timings do not mean: `firstlogon` is sent while Windows still
shows its first-sign-in animation (the desktop followed within two minutes),
and the numbers come from a fast local disk over a loopback network.

Lab caveat: `bin/vm-stop` uses the ACPI power button, which Windows turns into
fast startup (hibernation) unless the machine's role says `FASTSTARTUP=off`.
`bin/vm-stop --full` types a real `shutdown /s` into the desktop instead;
change VM hardware (`vm-boot --nic …`) only after one of those.

Later the same day (evidence: `spikes/2026-10-02-bridged-lab-netns/`):

| what | result |
|---|---|
| Bridged lab: `vm-create --net bridge:br0`, `pxe-lan --bridge`, inside `bin/lab-netns` | dnsmasq leased an address and served `ipxe.efi` over TFTP (the path real hardware takes); full deploy to `firstlogon` in 122 s. With dnsmasq stopped the same VM never left "Start PXE over IPv4" |
| `bin/fetch-iso --release 24H2` | built a 4.1 GB ISO in about two minutes on this connection; a VM deployed from it reached `firstlogon` in 156 s (evidence: `spikes/2026-10-02-fetch-iso/`) |

**Phase 2, 2026-10-02** (evidence: `spikes/2026-10-02-phase2-acceptance/`):

| what | result |
|---|---|
| Full deploy through the step files, driver pack supplied by `models/lab-vm.cfg` | all ten steps `ok`; `firstlogon`; `winre ok`: Enabled, on partition 4, Windows on partition 3 |
| Model file saying `MODE=deploy`, machine not listed | stays at `shell`, disk untouched |
| `STOP_AFTER=15`, `STOP_BEFORE=45-winre`, then `deploy 50` typed at the prompt | stops where told, prompt has the environment loaded, resumes from 50 and finishes |
| cfg and steps changed on the server, `deploy` re-typed (no reboot) | the re-run uses the new cfg and steps |
| Layout without a recovery partition | `45-winre fail: no recovery partition R:`; bypassed, the first-logon check reports `winre fail` (WinRE on the Windows partition) |
| Update pack: checkpoint + cumulative update for 26100.9550 (5 GB), `--target` the cumulative update | `35-updates ok` in about nine minutes; the installed system reports build **26100.9550** (base image is 26100.1); WinRE still ok |
| Same pack with a wrong `--expect` | `35-updates fail: expected package … is not installed in the image` |
| Same pack without `--target` | DISM exits 552 although the update is installed; the step passes on the package list and says so |
| A step that pipes into a program WinPE lacks | reported `fail rc=255: the step was cut short` (before the fix: the whole sequence vanished without a `fail` event) |
| `MODE=capture` on a deployed VM | 4.67 GB `capture.wim` uploaded in 95 s, `wimlib-imagex verify` clean, source disk untouched; applied to a fresh VM it boots to a desktop |
| `bin/lint` | 22/22 injected defects reported, among them a step using `findstr`, which WinPE does not have |

A cumulative update makes a deploy take about twelve minutes instead of two
and a half (three VMs were applying one at the same time).

**The "not verified" list, worked through, 2026-10-02** (evidence:
`spikes/2026-10-02-unverified-items/`):

| what | result |
|---|---|
| Update packs: cumulative + .NET update; and cumulative + 25H2 enablement | installed systems report 26100.9550 and **26200.9550** (25H2) from the same 26100.1 base image. A file that is not a servicing package fails the step |
| Generalized role image: `REFERENCE=yes` VM runs sysprep; captured in WinPE (`MODE=capture`) and on Linux (`bin/capture-image`, 89 s); each deployed to a fresh VM | both run specialize and first logon as new machines, carry the reference's stamp, `winre ok` |
| WinPE-side drivers via `drvload` | a VM with a virtio NIC *and* a virtio disk deploys; without the injected drivers WinPE never reaches the server |
| Firmware PXE without an iPXE option ROM (the path real hardware takes) | boots and deploys; drivers are selected by NIC PCI id because iPXE calls every chip `SNP` there |
| Secure Boot enforcing | unsigned `ipxe.efi`: "Access Denied". Signed with our own enrolled key: full deploy, Windows reports `secureboot=True` |
| Proxy-DHCP beside another DHCP server (in `bin/lab-netns`) | an iPXE-ROM client and a firmware client both boot; with our proxy stopped, neither does |
| winget at first logon | absent on this image; bootstrapping from the release packages works and it then installs software |
| A task that reports every boot | needs two triggers: "at startup" covers restarts, a Kernel-Boot event trigger covers fast-startup power-ons |

Later the same day, with root supplied from another shell:

| what | result |
|---|---|
| A bridge on the real host (`ip link add`, `/etc/qemu/bridge.conf`, setuid `qemu-bridge-helper`, `pxe-lan --bridge … start` under sudo) | an iPXE-ROM VM and a firmware-PXE virtio VM both deployed; with dnsmasq stopped nothing booted. Found: dnsmasq must keep running as the repo's owner after binding its ports, or it cannot read `pxe/` under a 750 home directory |
| `bin/lab-netns` on a host that restricts unprivileged user namespaces (`kernel.apparmor_restrict_unprivileged_userns=1`) | fails with a message that says what to do. The narrow fix, an AppArmor profile from `bin/lab-netns profile`, was enough: a full deploy ran inside the namespace with the restriction on |

**Phase 3, 2026-10-02** (evidence: `spikes/2026-10-02-phase3-roles/`):

| what | result |
|---|---|
| `vm-create --role lab-apps` (7-Zip, Notepad++, `FASTSTARTUP=off`, a post script) | PXE to `deployed` in 3 m 20 s: `winget ok` 8 s after first logon, `apps ok installed=7zip.7zip,Notepad++.Notepad++ failed=`, `faststartup ok state=off`, `boot-tasks ok`, `role-post ok sevenzip=yes` |
| The fast-startup policy | after it, `vm-stop` (ACPI) is a full shutdown; in the guest `powercfg /a`: "Fast Startup: Hibernation is not available", no `hiberfil.sys` |
| The every-boot probe, which trigger fires | cold boot: `onstart` only; restart: both; forced power-off: `onstart`; fast-startup power-on: `event` only. Two triggers are needed, and suffice |
| `ROLE=ghost` | `15-preflight fail msg=missing: roles/ghost/role.cfg`, disk untouched |
| A role with an app id that does not exist | `apps fail installed=7zip.7zip failed=No.Such.Package.Zzz(…)`, still `deployed` |
| Reference VM with the role, captured on Linux | first attempt: sysprep refused (winget's per-user source package; fixed in `prepare-capture.cmd`); second: generalized, captured in 82 s, sidecar `provenance` names the role and the apps list's SHA-256, equal to the served file's |
| Deployed from that image without a role, with a probe script | `firstlogon … image=reference … role lab-apps apps 7516a7ad…`; probe: `sevenzip=yes npp=yes stale_role=no`; no winget/apps events; `deployed role=`. The boot probe baked into the image reported the *new* machine's id on its first boot |
| Deployed from that image with the same role again | idempotent: `winget ok` in 4 s, `apps ok installed=7zip.7zip,Notepad++.Notepad++` (winget: "already installed", 0x8A15002B, counted as installed), `deployed` in 3 m 10 s |
| `bin/lint` | 28/28 injected defects reported, four of them about roles |

**Accounts and skel, 2026-10-02** (evidence: `spikes/2026-10-02-users-skel/`):

| what | result |
|---|---|
| Role with `SKEL=` (two files) and `USERS=` (`deploy\|Administrators\|random`, `alice\|Users\|random`) | `skel ok files=2`, `users ok created=alice set=deploy failed=`, `users-upload ok`; the role's probe logged on as both accounts with the uploaded passwords and found the skel files in alice's freshly created profile; `C:\pdt\users-out.txt` gone afterwards (guest checked) |
| A users list with a bad name and a bad policy | `users fail created=bob … failed=bad_name(…),carol(…)`, still `deployed`; `lint` had refused the file |
| `bin/lint` | 32/32 injected defects, four new (users line, skel manifest both ways, FILES companion) |
| First attempt, for the record | `New-LocalUser -PasswordNeverExpires $true` is a switch, not a bool (alice was not created); an `icacls` call left the passwords file unreadable by anyone, so the upload failed and the file stayed. Both fixed; the second fault is why `users-upload fail` keeps the file and says where it is |

**Housekeeping batch, 2026-10-11** (evidence: `spikes/2026-10-11-vmstop-deploy-skelreg/`), on a host upgraded to Ubuntu 26.04 / QEMU 10.2 in between (`vm-boot` now finds the iPXE ROMs in their new place):

| what | result |
|---|---|
| `SKELREG=skel.reg` (values merged into the Default profile's hive) | `skelreg ok`; the role's probe reads `SkelFrom=lab-apps` back from alice's freshly created hive |
| `DEPLOY=remove` (role; `USERS` creates `admin`) | account deleted at the end of first logon (`deploy-remove ok account=deleted`), restart, profile removed by a one-shot SYSTEM task 5 s into the next boot (`deploy-removed ok profile_gone=ok`); the first sign-in screen shows `admin` and `alice` only. Took five rounds: the unattend's autologon retried the deleted account (fixed: `firstlogon.cmd` clears it), and a `deploy` tile that survived every registry cleanup turned out to be the sign-in UI's in-memory list from before the deletion, which is why the account now goes *before* the restart |
| `vm-stop --full` on a role-less VM (fast startup on) | ACPI `vm-stop` → next boot `trigger=event` only (a resume); `vm-stop --full` → `trigger=onstart` (a real boot) |
| `bin/lint` | 35/35 injected defects, three new (`DEPLOY=remove` without another administrator, a `.reg` key outside `HKEY_CURRENT_USER`, `post/remove-deploy.cmd` missing) |
| Latitude E5570 prep | `bin/fetch-drivers` fetched Dell's Win10 A18 pack (912 MB, 403 without a browser User-Agent), 116 `.inf` → `drivers/latitude-e5570.wim`; `models/latitude-e5570.cfg`; lint all PASS. Nothing verified on the machine yet (`spikes/2026-10-11-latitude-e5570-prep/`) |

**Remote shell and screen pusher, 2026-10-12** (evidence: `spikes/2026-10-12-remote-shell/`, design: `docs/REMOTE_VISIBILITY.md`):

| what | result |
|---|---|
| `bin/shell <vm> '<command>'` on a VM at the WinPE prompt | output in 2.2 s; a failing command comes back as exit 1; the WinPE environment is loaded; `--off` ends the loop and the next `bin/shell` times out (exit 2) |
| `bin/screen <vm>` vs `bin/vm-shot` a second apart | 1280×800, 100.00 % identical pixels; a 3 MB BMP every ~6 s; after `--off` the age grows instead |
| both during `30-apply` on a deploying VM | `dir W:\` of the half-applied volume, a screen of DISM's progress; the deploy finishes (`deployed`) |
| `bin/build-tools` | `tools/pdt-screen.exe` 43 KB from 62 lines of C, hashes of source and binary recorded; `check` flags a stale or changed binary |

**A hash on the machine, 2026-10-24** (evidence: `spikes/2026-10-24-sha256-and-dism/`):

| what | result |
|---|---|
| `tools-src/pdt-sha256.c` compiled natively on Linux | FIPS vectors, 23 boundary-sized files and a 4.4 GB file agree with `sha256sum`; both served images match their sidecars; every exit code provoked (28/28) |
| `bin/build-tools` (pinned container, two builds each) | `pdt-screen.exe` unchanged (`31f25d28…`), `pdt-sha256.exe` 45 KB (`cd096583…` after the review's fixes); control without `--no-insert-timestamp`: "differ (2 byte(s))", nothing recorded; after the source changed, `check` called the served binary stale until the rebuild |
| An independent security review before the commit | twelve findings, eight fixed (a partial download could reach a resumed `deploy 30`; `check` trusted the record over the tool list; an `IMAGE` not ending in `.wim`; a non-running hasher read as "mismatch"; smaller ones); `30-apply` now demands the same-boot token `25-download` writes, shown refusing on a VM |
| `bin/build-tools openssl` | OpenSSL 3.5.9 from the pinned tarball, static `openssl.exe` 7.3 MB, identical across two passes and a third container run (`53842107…`); runs in WinPE, `dgst -sha256` agrees with `pdt-sha256` on the tools and the 3.5 GB image |
| `25-download` on a plain deploy | `ok msg=sha256 0c947e48… matches images/base.json` (24.8 s download + hash; the hash alone is 9.4 s in the VM), then `deployed` |
| Control: `base.wim` with one byte flipped, sidecar still claiming base's hash | `25-download fail rc=1 … download deleted, nothing applied`; `W:\` holds only `Scratch` |
| The same corrupt file with a truthful sidecar (does DISM notice?) | `25-download ok`, then `30-apply fail rc=1392`, `dism.log`: `0x80070570 The file or directory is corrupted and unreadable`, 39 s in, `W:\Windows` half written |
| `bin/lint` | 208 PASS, self-test 49/49 (hasher not built; sidecar without `sha256`); a flipped byte in `tools/pdt-sha256.exe` → `build-tools check` and `lint` FAIL "not the binary that was recorded" |

**The collector, 2026-10-12** (evidence: `spikes/2026-10-12-collector/`, design: `docs/COLLECTOR.md`):

| what | result |
|---|---|
| `bin/build-collector` (rootless mmdebstrap, Debian trixie) | kernel 11 MiB + initramfs 134 MiB, 179 packages, 19 s with a warm cache; two cpio-writer bugs found by the kernel's own "no cpio magic" / "malformed archive" (a non-ASCII CA certificate name) |
| An unlisted VM with `bin/netboot <vm> collector` | `collect ok product=lab-vm serial=… amt=absent firmware=none pxe_entry=0003 ssh=up` 4.5 s after the iPXE request; `inventory.json` uploaded; `bin/shell` works against Linux (1.2 s); sshd key-only with fresh host keys (the first good boot said `ssh=down`, honestly: the keys were missing) |
| `bin/enroll <vm> --role lab-apps`, `bin/netboot <vm> winpe`, `bin/shell <vm> 'pdt-pxe-next --reboot'` | `machines/<uuid>.cfg` from the inventory; the VM rebooted into Windows PE and ran the full role deploy to `deployed` in 245 s |
| BootNext, on the disk that now boots Windows | set from the collector, disk-first boot → the collector again (`BootCurrent: 0003`); control without it → Windows (`boot ok`), no `collect` |

**SSH and RDP from the host, 2026-10-12** (evidence: `spikes/2026-10-12-ssh-rdp/`; `bin/vm-boot --fwd` is the new piece):

| what | result |
|---|---|
| `ssh -p 2222 -i ~/.ssh/id_ed25519 root@127.0.0.1` into a collector VM | logs in (hostname, uid, kernel, boot entries); password methods and a wrong key: `Permission denied (publickey)` |
| Role key `RDP=on` | `rdp ok listening=yes`; the RDP listener selects CredSSP (NLA) in the first protocol exchange; a VM without the key answers nothing on 3389. Credentials over RDP not yet exercised (no `xfreerdp` on this host) |

**Local boot, disk guard, SSH, RDP credentials, 2026-10-22** (evidence: `spikes/2026-10-21-local-diskguard-ssh/`):

| what | result |
|---|---|
| `xfreerdp … /auth-only` against a `RDP=on` machine | `admin` and `alice` with their generated passwords: exit 0 (authenticated); a wrong password, an unknown account and the deleted `deploy`: `ERRCONNECT_LOGON_FAILURE` |
| `bin/netboot <vm> local` on a PXE-first VM | iPXE prints "local boot requested", exits with an error, the firmware walks its remaining network entries and starts the disk: `firstlogon ok` from the installed Windows, no `ts-start`. Control: `netboot <vm> winpe` → `ts-start`, WinPE again. Two chainloader defects found and fixed on the way (a returned chain fell into `:failed`; edk2 shows its boot menu when the option returns success, so it must `exit 1`) |
| `17-diskguard` | one disk: "the only fixed disk"; a 32 G disk and an 8 G USB stick beside it: both "not eligible", disk 0 deployed; two 64 G disks and no `DISK=`: `17-diskguard fail`, both disks left blank; `DISK=9`: refused; `DISK=1`: the partitions on disk 1, disk 0 still blank |
| Role key `SSH=on` + `SSHKEYS` | `ssh ok port=22 keys=1 listening=yes`; `ssh -i ~/.ssh/id_ed25519 admin@…` logs in, host-key fingerprint equals the uploaded `ssh.txt`; no key, `alice` (group Users) and the deleted `deploy`: `Permission denied (publickey)`, no password prompt. With PowerShell 7 among the apps (`Microsoft.PowerShell --installer-type wix`: the MSI, not the MSIX winget picks by default), `shell=pwsh` and `Invoke-Command -HostName … -Port 2223` from this host's `pwsh` runs a script block on the machine |

**Every download verified, the console as text, the second-disk boot order, 2026-10-24** (evidence: `spikes/2026-10-24-verified-packs-console-bootorder/`):

| what | result |
|---|---|
| `ts/verified.cmd` behind `25-download`, `35-updates`, `40-drivers`, `45-winre` | a deploy with a 5.2 GB update pack (the 24H2 checkpoint + the September 2026 cumulative update) and the virtio driver pack: every step `ok` with `sha256 … matches <sidecar>` in its message, `35-updates` 790 s, first logon reports `build=26100.9550`; a deploy from the captured `lab-apps.wim` fetched its recovery image from the server and verified it the same way |
| Controls: each pack's sidecar made to claim a hash of all zeros | `40-drivers fail rc=1 … download deleted`, `35-updates fail rc=1 … download deleted`, no `W:\drivers.wim`, `W:\updates.wim`, `W:\Drivers`, `W:\Updates`; `45-winre` first reported **`ok`** with the mismatch as its message (a liar) |
| The liar: an `exit /b` reached through `\|\|` or an `if` inside a multi-line parenthesized block | measured with twelve one-line test scripts on the VM: `cmd /c script` exits **0** for every such form (after `call` or a program, with a literal code or `!errorlevel!`, the exit parenthesized or not), while the same lines at top level or in a one-line block, and a bare literal `exit /b 9` in a multi-line block, propagate; the shell's errorlevel is right in every case. `step.cmd` now runs each step as `cmd /v:on /c "<step> & exit !errorlevel!"`; lint pins that line (self-test 56/56); the control re-run: `45-winre fail rc=1`, nothing on `R:` |
| A two-disk VM with `DISK=1`, disk 0 blank | `50-boot ok msg=… the firmware boots Windows Boot Manager first` (`bcdedit /enum firmware` in the log: `{bootmgr}` leads `displayorder`), `ts-done`, then `specialize` 49 s later and `deployed`: Windows from disk 1, no second `ts-start`. The 2026-10-24 demo's re-image loop was the lab's doing: `vm-boot` gave the second disk no QEMU `bootindex` (OVMF then lists it after the network) and reset the NVRAM when disk 0 alone looked empty; both fixed |
| `tools/pdt-console.exe` + `bin/console` + `bin/keys` | a VM stopped before `20-disk`: the first frame is the deploy window (title `Administrator:  pdt-deploy`, 459 B), `bin/keys vd 'dir X:\pdt{enter}'` shows the listing in the next frame, `bin/keys vd 'deploy 20{enter}'` resumes the sequence (`bin/console --await 30-apply` returned 34 s later) and the VM reached `deployed`. Frames: 6 in a 2-minute WinPE session, 0.5–1.5 KB each, against 3 MB per screenshot. Controls: `dump` against a title nobody has → exit 2, no file; `bin/shell --off` → the frame count stays at 6 while the sequence beacons on to `ts-done` |
| `bin/lint` | 231 PASS; self-test 56/56 (new: a pack sidecar without `sha256`, a recovery image without a sidecar or with another file's, a captured image with no recovery image, `step.cmd` without the exit wrapper) |
| `SSH=on` on a captured image | a reference VM with the lab role generalized itself (`prepare-capture` deletes sshd's host keys first), captured on Linux, two VMs deployed from the image: `ssh-keyscan` shows three different ED25519 keys for the reference and the two machines (RSA, ECDSA too); the role's key logs in as `admin` on both, no key is refused |
| Per-user SSH keys: `alice\|Users\|random\|keys=alice.pub` in the lab role | `users ok … keys=alice`; `ssh -i build/lab-alice alice@…` logs in (the file `C:\ProgramData\ssh\users\alice\authorized_keys`, Administrators-owned, alice read; `sshd_config` lists `__PROGRAMDATA__/ssh/users/%u/authorized_keys`); controls: `alice` with the admins' key, `admin` with alice's key and an account that does not exist are all refused |

Still not verified: anything on physical hardware, including enrolling a
Secure Boot certificate in real firmware.

## Documents

- `PLAN.md`: design and roadmap, each claim tagged verified / read / unknown.
- `TODO.md`: ordered next steps and open questions to spike.
- `DEFERRED.md`: ideas deliberately parked, with the reason, so they are not
  rediscovered as gaps.
- `REMOTE_SITES.md`: running the toolkit for sites you never visit, over
  Tailscale or a VPN: what must stay on the LAN, the appliance-per-site design
  in two tiers, how to prove it with two `lab-netns` sites, and why multicast
  and BITS are not the answer.
- `docs/HOW_IT_WORKS.md`: a ground-up tour for newcomers.
- `docs/CONTROL_POINTS.md`: every point where an admin controls what a
  machine gets (image, scripts, users, apps), the file that carries it, and
  when an edit takes effect.
- `docs/REMOTE_VISIBILITY.md`: seeing and driving a machine you cannot sit
  at: the remote shell and screen pusher over HTTP, and what RDP, serial
  consoles and Intel AMT can and cannot do.
- `docs/COLLECTOR.md`: the Linux that PXE-boots into RAM to inventory a
  machine, take commands and SSH, and send it on into Windows PE.
- `docs/LAYERS.md`: every layer on its own, with the recipes for adding or
  changing things in it and how each change is proved.
- `docs/MANUAL_TESTING.md`: the whole toolkit by hand, step by step, with
  the expected result and the control for each.
- `docs/LAB_FROM_SCRATCH.md`: the same lab built by hand on a host-only bridge.
- `docs/REVIEW-2026-10-12.md`: an outside review before the first physical
  machine: what is sound, what bites a real fleet first, and what a lab or
  small business needs added, in order.
- `docs/history/v1-setup-exe/`: the retired Setup-based pipeline and its notes.
- `spikes/`: evidence behind the plan.
