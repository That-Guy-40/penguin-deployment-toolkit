# Penguin Deployment Toolkit

*Deploy Windows 11 over the network from a Linux host: iPXE + WinPE + DISM. A
small, Linux-hosted stand-in for Microsoft Deployment Toolkit: the penguin does
the deploying, Windows does the installing.*

No Windows machine, no ADK, no MDT, no SMB share. The Linux host serves files
over HTTP; Windows PE on the target does the install with Microsoft's own tools
(`diskpart`, `dism`, `bcdboot`, an unattend file), following a plain-text task
sequence the host serves.

> **Status (2026-10-02).** Phase 1 of `PLAN.md` is done: the layout below is
> what runs, verified end to end in a lab VM (see [Verification](#verification)).
> Real hardware (Phase 5) and an install guide for other people (Phase 6) are
> not done yet; `TODO.md` has the order of work. The first version of this repo
> (Windows Setup + `autounattend.xml`) is retired to `docs/history/v1-setup-exe/`.

## How a machine gets installed

```
firmware PXE ─TFTP→ pxe/ipxe.efi            the one binary we build; embeds one URL
  └─ iPXE ─HTTP→ http/boot.ipxe             static; loads wimboot + a PRISTINE boot.wim
       └─ wimboot injects into X:\Windows\System32:
            winpeshl.ini, deploy.cmd, id.cmd, curl.exe
            └─ WinPE runs deploy.cmd (the task sequence):
                 machines/<uuid>.cfg says MODE=deploy?  no → report, stop at a prompt
                 disk      diskpart (GPT: ESP, MSR, Windows)
                 download  images/base.wim over HTTP
                 apply     dism /apply-image
                 drivers   optional driver pack → dism /add-driver
                 boot      bcdboot
                 unattend  Panther unattend.xml + C:\pdt\ scripts, reboot
                 └─ installed Windows: specialize → first logon → desktop
```

Every step reports `start` and `ok`/`fail` to the server and pushes its logs
there, so an install can be followed, and a failure diagnosed, without looking
at the machine's screen.

**Nothing is wiped unless you list the machine.** A machine is deployed only if
`http/machines/<its SMBIOS UUID>.cfg` exists and says `MODE=deploy`. Any other
machine that PXE-boots gets WinPE at a prompt, shows up in `bin/status`, and is
left untouched.

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
| `bin/status [--watch]` | one row per machine: last event, age, mode, product. `FAIL` and `STUCK?` are flagged |
| `bin/status <id\|vm>` | every event of that machine's latest boot with timings (iPXE request, `boot.wim` transfer rate, each step) |
| `bin/await <id\|vm> <step> [secs]` | block until that step reports ok; exit 1 on any `fail`, 2 on timeout. Makes the lab scriptable |
| `bin/logs <id\|vm> [--cat ts.log]` | what the machine uploaded: `ts.log`, `dism.log`, Setup's Panther logs |
| `bin/lint` | static check of `http/` and the host set-up; self-tests by injecting known defects |
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
| `bin/stage-image` | the ISO's install image → `http/images/base.wim` + `base.json` |
| `bin/pack-drivers` | a directory of drivers → `http/drivers/<name>.wim` |
| `bin/build-ipxe` | builds `pxe/ipxe.efi` from a pinned iPXE commit |
| `bin/serve` | rootless nginx: static files, `GET /beacon`, `GET /ts/id.cmd`, `PUT /uploads/` |
| `bin/pxe-lan` | dnsmasq + TFTP: proxy-DHCP for a real LAN (not yet run against hardware), or `--bridge` authoritative DHCP for a lab bridge (verified) |
| `bin/lab-netns` | a rootless host-only bridge in a private network namespace, for running the bridged lab without sudo |
| `bin/vm-create`, `vm-boot`, `vm-stop`, `vm-shot`, `vm-type` | the lab VM |
| `bin/status`, `await`, `logs`, `lint` | read-only tools over the logs and `http/` |
| `bin/teardown` | stop services; optionally delete lab state |
| `http/boot.ipxe` | the iPXE script every target runs (static, relative URLs) |
| `http/ts/` | the WinPE task sequence: `winpeshl.ini`, `deploy.cmd`, `diskpart/` |
| `http/unattend/` | Panther unattend files (`default.xml`: local admin `deploy`, **blank password**, one autologon: lab defaults) |
| `http/post/` | scripts copied to `C:\pdt\` and run by the installed system |
| `http/machines/` | `<uuid>.cfg` per deployable machine (not tracked; see its README) |
| `http/winpe/ tools/ images/ drivers/ uploads/` | fetched, extracted or uploaded content (not tracked) |
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
- **Lab hardware WinPE already understands.** e1000e NIC and AHCI disk (inbox
  drivers). No TPM: the apply path performs no Windows 11 hardware check.
- **Pinned by hash, not by version.** The `wimboot` `v2.9.0` release asset was
  replaced upstream with different contents under the same version; `fetch-tools`
  refuses a download whose SHA-256 is not the reviewed one.
- **Secure Boot capable, not enforcing** (OVMF secboot build with empty
  variables), so the unsigned `ipxe.efi` loads. Enforcing mode is Phase 5.

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

Not verified: proxy-DHCP mode (`bin/pxe-lan` without `--bridge`) next to a real
DHCP server, a bridge on the real host (setuid helper, `/etc/qemu/bridge.conf`,
firewall), and anything on physical hardware.

## Documents

- `PLAN.md`: design and roadmap, each claim tagged verified / read / unknown.
- `TODO.md`: ordered next steps and open questions to spike.
- `docs/HOW_IT_WORKS.md`: a ground-up tour for newcomers.
- `docs/LAB_FROM_SCRATCH.md`: the same lab built by hand on a host-only bridge.
- `docs/history/v1-setup-exe/`: the retired Setup-based pipeline and its notes.
- `spikes/`: evidence behind the plan.
