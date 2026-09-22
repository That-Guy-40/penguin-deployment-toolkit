# Penguin Deployment Toolkit

*Windows 11 unattended install via iPXE + WinPE, from Linux. A small, Linux-hosted stand-in for Microsoft Deployment Toolkit: the penguin does the deploying, Windows does the installing.*

Install Windows 11 into a QEMU/KVM VM (or onto a physical machine) by PXE-booting
WinPE from the Linux host and running Setup unattended. All infrastructure (TFTP,
HTTP, the VM) runs on the host. No Windows machine and no Windows ADK.

> **Where things stand (2026-09-22).** This README documents the pipeline that
> exists in `scripts/` today (the "v1", `setup.exe`-driven flow, verified working
> on 2026-06-02). The project's direction has changed: `PLAN.md` describes the
> next design (pristine boot.wim, task sequence injected at boot, DISM
> apply-image, HTTP-only, driver packs), which was proven in throwaway spikes on
> 2026-09-22 (see `spikes/`). The v1 scripts still work and are the fallback.

## Boot chain (v1, as implemented)

```
QEMU VM (UEFI/OVMF Secure-Boot-capable firmware + TPM 2.0 via swtpm)
 └─ OVMF UEFI PXE ─(QEMU built-in TFTP)→ pxe/ipxe.efi   (our build; embeds the chain URL)
      └─ iPXE ─HTTP→ boot.ipxe ─HTTP→ wimboot + bootmgfw.efi + BCD + boot.sdi + boot.wim
           └─ WinPE boots; startnet.cmd (injected into boot.wim by 03) runs
                setup.exe /unattend:X:\autounattend.xml from the attached ISO
                     └─ Windows 11 installs unattended onto the AHCI system disk
```

`ipxe.efi` is required because OVMF's PXE stack can only execute a UEFI binary,
not an iPXE script. Inside a VM the host is `10.0.2.2` (QEMU user-net); on a LAN
`07-setup-physical.sh` rebuilds `ipxe.efi` for the host's real IP and runs
dnsmasq as proxy-DHCP/TFTP.

## Repository map

| Path | What it is |
|---|---|
| `config.sh.example` | template; `00-bootstrap.sh` copies it to `config.sh` (host-specific; this directory is not a git repo) |
| `scripts/00-bootstrap.sh` | creates `pxe/ http/winpe answer/ vms/` and `config.sh` |
| `scripts/01-install-deps.sh` | apt packages (wimtools, nginx, aria2, cabextract, chntpw, genisoimage, iPXE build deps) and downloads `pxe/wimboot` |
| `scripts/00b-download-iso.sh` | optional: builds a Win11 ISO from UUP dump into `tools/uupdump-work/`, sets `ISO_PATH` |
| `scripts/00c-build-ipxe.sh` | clones iPXE into `build/ipxe/ipxe`, builds `pxe/ipxe.efi` with `build/ipxe/chain.ipxe` embedded (host + `HTTP_PORT` baked in) |
| `scripts/02-extract-winpe.sh` | `sudo mount` the ISO, copy `bootmgfw.efi BCD boot.sdi boot.wim` to `http/winpe/` (the only step needing sudo) |
| `scripts/03-inject-autounattend.sh` | `wimlib-imagex update`: `answer/autounattend.xml` + a generated `startnet.cmd` into **every** image of `http/winpe/boot.wim` |
| `scripts/04-setup-http.sh` | writes `pxe/boot.ipxe` (+ copy in `http/`), generates `run/nginx.conf`, starts a **rootless** nginx on `HTTP_PORT` |
| `scripts/05-create-vm.sh` | qcow2 disk, swtpm state dir, OVMF NVRAM copy under `vms/` |
| `scripts/06-boot-vm.sh` | starts swtpm and QEMU (`HEADLESS=1` for no window; serial log at `/tmp/qemu-serial.log`) |
| `scripts/07-setup-physical.sh` | rebuilds `ipxe.efi`/`boot.ipxe` for the LAN IP, writes `pxe/dnsmasq.conf` (proxy-DHCP + TFTP), prints how to start it |
| `scripts/99-teardown.sh` | stops QEMU/swtpm/our nginx/our dnsmasq, unmounts the ISO; `--purge` also deletes VM state and generated configs |
| `answer/autounattend.xml` | answer file: wipe disk 0 (GPT: 512 MB EFI, 16 MB MSR, rest NTFS), local admin **`deploy` with a blank password**, autologon once, OOBE hidden, `WIN11-VM`, UTC |
| `pxe/` | TFTP root: `ipxe.efi`, `wimboot`; `boot.ipxe` and `dnsmasq.conf` are generated here |
| `http/` | nginx document root: `winpe/` (boot files; `wimboot` is a symlink to `pxe/wimboot`), `boot.ipxe` |
| `build/ipxe/` | iPXE source checkout and build output (cache; safe to delete) |
| `tools/uupdump-work/` | UUP dump working directory (downloaded packages, ~4 GB; cache) |
| `win11.iso` | the ISO built by `00b` on this host: build 26100.1 (24H2), Professional, en-US, `sources/install.wim` 3.5 GB (single image), `sources/boot.wim` 498 MB |
| `run/` | created by `04`: nginx config, pid, logs (deleted by `99 --purge`) |
| `vms/` | VM disk, TPM state, NVRAM (deleted by `99 --purge`) |
| `spikes/` | dated experiments with their scripts and screenshots (see `PLAN.md`) |
| `docs/history/` | superseded plan reviews |

## Prerequisites (Ubuntu 24.04)

Expected on the host already: `qemu-system-x86_64` with KVM, OVMF (`/usr/share/OVMF/OVMF_CODE_4M.secboot.fd`,
`OVMF_VARS_4M.fd`), `swtpm`, the iPXE option ROMs in `/usr/lib/ipxe/qemu/`,
`python3`, `curl`. `01-install-deps.sh` installs the rest. You need a Windows 11
ISO: set `ISO_PATH` in `config.sh` or build one with `00b-download-iso.sh`.

## Run order

The prefixes are historical; the real dependency order is:

| Step | Script | Notes |
|---|---|---|
| 1 | `00-bootstrap.sh` | dirs + `config.sh` |
| 2 | `01-install-deps.sh` | must run before `00b`/`00c` (they need its packages) |
| 3 | `00b-download-iso.sh` | optional, ~4–6 GB download |
| 4 | `00c-build-ipxe.sh` | bakes `HTTP_PORT` into `ipxe.efi`; re-run after changing the port |
| 5 | `02-extract-winpe.sh` | sudo (loop mount) |
| 6 | `03-inject-autounattend.sh` | edits `http/winpe/boot.wim` in place |
| 7 | `04-setup-http.sh` | errors (does not kill anything) if `HTTP_PORT` is taken |
| 8 | `05-create-vm.sh` | asks before recreating an existing disk; wipes TPM state + NVRAM only when you say yes |
| 9 | `06-boot-vm.sh` | installs Windows; with an already-installed disk it boots Windows instead |

Physical machines: steps 1–7, then `07-setup-physical.sh` and start dnsmasq as it
prints. **That wipes disk 0 of any UEFI machine that PXE-boots on that LAN.**

## Key design decisions (v1)

- **Inject into every boot.wim image.** A stock boot.wim has two images
  (1 = Windows PE, 2 = Windows Setup); the WIM "Boot Index" is 2. An earlier
  version injected only into index 1, so Setup ran interactively. `03` writes into
  all images.
- **Custom `startnet.cmd`.** Neither image ships `winpeshl.ini`, so WinPE runs
  `startnet.cmd`; ours calls `wpeinit` then `setup.exe /unattend:X:\autounattend.xml`
  from the first drive that has `\sources\setup.exe` (the attached ISO). Setup only
  auto-discovers `autounattend.xml` on removable media, not on `X:`.
- **AHCI system disk, not virtio.** Stock WinPE has `storahci` but no virtio
  drivers, so a virtio-blk disk is invisible to Setup. The NIC is virtio only
  because the iPXE ROM drives PXE and v1 never uses the network inside WinPE.
- **Boot order disk → PXE → CD.** An empty disk falls through to PXE; once Windows
  is installed the disk boots it. `06` resets NVRAM only while the disk is
  effectively empty (< 100 MiB allocated) and preserves it afterwards.
- **Secure Boot capable, Setup Mode.** Windows 11 Setup requires Secure-Boot-
  capable firmware, so the secboot OVMF build is used with the *empty* vars
  template: capable but not enforcing, so the unsigned self-built `ipxe.efi` loads.
  `config.sh` documents how to sign and enrol for enforcing mode.

## Verification status

- **2026-06-02, v1 end to end [verified]:** full watched install in the VM. Setup
  ran unattended, passed the Secure Boot/TPM checks, partitioned the AHCI disk,
  rebooted through specialize/OOBE, autologon worked, and the installed disk then
  booted directly (no PXE loop).
- **2026-09-22, v2 spikes [verified]:** see `PLAN.md` §2 and `spikes/`. Summary:
  pristine boot.wim + wimboot-injected task sequence + `curl.exe` → diskpart →
  `install.wim` over HTTP → `dism /apply-image` → virtio driver pack via
  `dism /add-driver` → `bcdboot` → Panther `unattend.xml` → first logon, in
  ~2.5 minutes wall clock on this host. Negative control (injection disabled)
  behaved as expected.

## State of this host (2026-09-22)

The v1 pipeline is currently **torn down** (`99-teardown.sh --purge` was run):
`vms/` is empty, there is no `run/` and no `pxe/boot.ipxe`. `http/winpe/` still
holds the extracted, injected boot.wim, and `pxe/ipxe.efi` is built for port
**8088** (`config.sh`). **Port 8088 is now occupied on 127.0.0.1 by another
process** (as is 8080), so `04` will refuse to start until `HTTP_PORT` is
changed in `config.sh` and `00c` is re-run. 8090 was free and was used by the
spikes. Re-running v1 from here:

```bash
# in config.sh: HTTP_PORT="8090"   (or another free port)
bash scripts/00c-build-ipxe.sh
bash scripts/04-setup-http.sh
bash scripts/05-create-vm.sh
bash scripts/06-boot-vm.sh
```

## Troubleshooting

- **Setup complains about Secure Boot / TPM.** Uncomment the three `LabConfig`
  lines in `03`'s `startnet.cmd` and re-run `03`.
- **`04` says the port is in use.** It never kills other services. Pick a free
  port in `config.sh`, re-run `00c` (port is baked into `ipxe.efi`) and `04`.
- **`boot.wim` is root-owned / permission denied.** `02` normalises ownership when
  run via sudo; `03` takes ownership if needed.
- **Re-running `06` reinstalls Windows.** Only if the disk was wiped. Otherwise
  disk-first boot order boots the installed OS.
- **Watching a headless run.** `HEADLESS=1 bash scripts/06-boot-vm.sh`; serial
  output lands in `/tmp/qemu-serial.log` (firmware/iPXE only; WinPE does not
  write to serial). The spikes show how to screenshot via the QEMU monitor.

## Document status

- `README.md` (this file): what the code in `scripts/` does today.
- `PLAN.md`: the current design and roadmap (v2), with verified/unknown tags.
- `spikes/`: evidence for the plan; each spike has a README with results.
- `TODO.md`: ordered next steps.
- `docs/history/`: superseded reviews of the original plan.
