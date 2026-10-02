# Penguin Deployment Toolkit

*Deploy Windows 11 over the network from a Linux host: iPXE + WinPE + DISM. A
small, Linux-hosted stand-in for Microsoft Deployment Toolkit: the penguin does
the deploying, Windows does the installing.*

No Windows machine, no ADK, no MDT, no SMB share. The Linux host serves files
over HTTP; Windows PE on the target does the install with Microsoft's own tools
(`diskpart`, `dism`, `bcdboot`, an unattend file), following a plain-text task
sequence the host serves.

> **Status (2026-10-02).** Phases 1 and 2 of `PLAN.md` are done: the layout
> below is what runs, verified end to end in lab VMs (see
> [Verification](#verification)). Real hardware (Phase 5) and an install guide
> for other people (Phase 6) are not done yet; `TODO.md` has the order of work. The first version of this repo
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
                 20-disk       diskpart (GPT: ESP, MSR, Windows, Recovery)
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

Needs Ubuntu 24.04 with KVM, plus: `qemu-system-x86 qemu-utils ovmf ipxe-qemu
nginx wimtools p7zip-full socat uuid-runtime curl unzip python3 python3-pil
build-essential liblzma-dev git`. And a Windows 11 ISO.

```bash
cp config.sh.example config.sh     # set ISO_PATH; pick a free HTTP_PORT
bin/fetch-iso                      # only if you have no ISO: builds one via UUP dump (4-6 GB)
bin/fetch-tools                    # wimboot, curl.exe, wimlib for Windows (pinned by hash)
bin/stage-winpe                    # boot.wim + boot files out of the ISO (7z, no sudo)
bin/stage-image                    # install.wim -> http/images/base.wim + sidecar
bin/build-ipxe                     # pxe/ipxe.efi, chaining to HTTP_HOST:HTTP_PORT
bin/serve                          # rootless nginx on HTTP_PORT, self-tested
bin/lint                           # every referenced file exists; exit 1 if not

bin/vm-create lab01                # empty disk + machines/<uuid>.cfg with MODE=deploy
                                   #   (--nic/--disk virtio, --reference, --image <role>: see --help)
bin/vm-boot lab01                  # headless; PXE → WinPE → install
bin/await lab01 firstlogon 900     # blocks until the desktop is reached (or fails)
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
unprivileged user namespaces (`kernel.apparmor_restrict_unprivileged_userns=0`).
The same lab on a real host bridge, with root, is `docs/LAB_FROM_SCRATCH.md`.

## Watching and debugging an install

| command | what it tells you |
|---|---|
| `bin/status [--watch]` | one row per machine: last event, age, mode, product, model slug. `FAIL` is flagged; a step running for long is `busy` while it keeps pushing logs and `STUCK?` when it has gone silent |
| `bin/status <id\|vm>` | every event of that machine's latest boot with timings (iPXE request, `boot.wim` transfer rate, each step) |
| `bin/await <id\|vm> <step> [secs]` | block until that step reports ok; exit 1 on any `fail`, 2 on timeout. Makes the lab scriptable |
| `bin/logs <id\|vm> [--cat ts.log]` | what the machine uploaded: `ts.log`, `dism.log`, `reagentc.txt`, Setup's Panther logs. Pushed every 20 s while a step runs, so `--tail 5 ts.log` follows a long step live |
| `bin/lint [-v]` | static check of `http/` and the host set-up; self-tests by injecting known defects |
| `bin/vm-shot`, `bin/vm-type` | screenshot / type into a lab VM through the QEMU monitor (last resort; VMs only) |

Raw data, if you prefer `tail -f`: `run/beacons.log` (one line per event),
`run/access.log` (every file request, with transfer time), `http/uploads/<id>/<run>/`.

## Repository map

| Path | What it is |
|---|---|
| `config.sh.example` | template for `config.sh`, the only place host-specific values live |
| `bin/lib.sh` | shared by every script: loads `config.sh`, helpers |
| `bin/fetch-iso` | optional: build a Windows 11 ISO from Microsoft's update servers via UUP dump, into `iso/` with a sidecar (base build only: no cumulative updates on Linux) |
| `bin/fetch-tools` | third-party binaries, pinned by SHA-256, into `http/winpe/` and `http/tools/`; `fetch-tools virtio` builds a virtio driver pack |
| `bin/stage-winpe` | `boot.wim`, `bootmgfw.efi`, `BCD`, `boot.sdi` from the ISO, unmodified |
| `bin/stage-image` | the ISO's install image → `http/images/base.wim` + `base.json` + `base.winre.wim`; `--from-upload <vm>` publishes an image captured by `MODE=capture` |
| `bin/capture-image` | capture a role image from a switched-off, generalized lab VM's disk on Linux (wimlib), publish it |
| `bin/pack-drivers` | a directory of drivers → `http/drivers/<name>.wim` |
| `bin/pack-updates` | a directory of `.msu`/`.cab` updates → `http/updates/<name>.wim`; `--target` names the update to install (others are prerequisites), `--expect` the package version that must end up installed |
| `bin/build-ipxe` | builds `pxe/ipxe.efi` from a pinned iPXE commit |
| `bin/serve` | rootless nginx: static files, `GET /beacon`, `GET /ts/id.cmd`, `PUT /uploads/` |
| `bin/pxe-lan` | dnsmasq + TFTP: proxy-DHCP for a real LAN (not yet run against hardware), or `--bridge` authoritative DHCP for a lab bridge (verified) |
| `bin/lab-netns` | a rootless host-only bridge in a private network namespace, for running the bridged lab without sudo |
| `bin/vm-create`, `vm-boot`, `vm-stop`, `vm-shot`, `vm-type` | the lab VM |
| `bin/status`, `await`, `logs`, `lint` | read-only tools over the logs and `http/` |
| `bin/teardown` | stop services; optionally delete lab state |
| `http/boot.ipxe` | the iPXE script every target runs (static, relative URLs) |
| `http/ts/` | the WinPE task sequence: `deploy.cmd` (bootstrap + runner), `env.cmd` (all state), `step.cmd`/`beacon.cmd`/`push.cmd` (helpers), `*.seq` (which steps a MODE runs), `steps/` (one file per step), `diskpart/` |
| `http/unattend/` | Panther unattend files (`default.xml`: local admin `deploy`, **blank password**, one autologon: lab defaults) |
| `http/post/` | scripts run by the installed system from `C:\pdt\`: `firstlogon.cmd`, `prepare-capture.cmd` (sysprep, for `REFERENCE=yes`), and your own (`POST=` in a cfg) |
| `http/winpe-drivers/` | drivers WinPE itself needs, injected per NIC PCI id or product (see its README; generated content not tracked) |
| `http/machines/` | `<uuid>.cfg` per machine: MODE and overrides (not tracked; see its README) |
| `http/models/` | `<product-slug>.cfg` per hardware model: defaults such as the driver pack (not tracked; see its README) |
| `http/winpe/ tools/ images/ drivers/ updates/ uploads/` | fetched, extracted, packed or uploaded content (not tracked) |
| `iso/` | ISOs built by `bin/fetch-iso` (not tracked) |
| `pxe/` | TFTP root: `ipxe.efi`, generated `dnsmasq.conf` (not tracked) |
| `run/` | nginx config, pid, logs, `beacons.log` (not tracked) |
| `vms/` | lab VMs: disk, NVRAM, `vm.conf` (not tracked) |
| `docs/` | `HOW_IT_WORKS.md` (tour), `LAB_FROM_SCRATCH.md` (bridged-lab runbook), `history/` (retired v1 and old reviews) |
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
fast startup (hibernation). Change VM hardware (`vm-boot --nic …`) only after a
full shutdown from inside Windows (`shutdown /s /t 0`).

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

Still not verified: anything on physical hardware (including enrolling a
certificate in real firmware), a bridge on the real host (needs root), and
`bin/lab-netns` on a host where unprivileged user namespaces are restricted.

## Documents

- `PLAN.md`: design and roadmap, each claim tagged verified / read / unknown.
- `TODO.md`: ordered next steps and open questions to spike.
- `docs/HOW_IT_WORKS.md`: a ground-up tour for newcomers.
- `docs/LAB_FROM_SCRATCH.md`: the same lab built by hand on a host-only bridge.
- `docs/history/v1-setup-exe/`: the retired Setup-based pipeline and its notes.
- `spikes/`: evidence behind the plan.
