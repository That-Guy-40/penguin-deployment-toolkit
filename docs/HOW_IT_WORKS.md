# How this repo works, from the ground up

A guided tour for someone new to the project: the one idea it is built on, the
pieces you set up on the Linux host, what happens second by second when a
machine boots, and where the design is heading. Everything here describes what
the code and the spike evidence show as of 2026-09-22. `README.md` is the
reference for the scripts, `PLAN.md` for the direction; this file is the
narrative that connects them.

## 1. The one idea

A PC that PXE-boots asks the network for something to run. This repo answers
with a chain of three things, each fetched over the network, each handing off
to the next:

1. **iPXE** (`ipxe.efi`), a small open-source network bootloader. The
   firmware's own PXE stack can only run a UEFI binary, so this is the first
   hop. It is the only binary the repo compiles, and the only thing baked into
   it is one URL.
2. **wimboot**, another small binary from the iPXE project. It takes
   Microsoft's boot manager, its BCD store, `boot.sdi` and a `boot.wim`, and
   boots Windows PE from RAM as if they had come from a DVD.
3. **Windows PE** (`boot.wim`, lifted straight from a Windows 11 ISO). A
   minimal Windows that runs from RAM. Once it is up, it does the actual
   install using Microsoft's own tools.

The Linux host never runs anything Windows. It serves files. Windows does the
installing, from inside WinPE, following instructions the Linux host wrote.
That is the README's tagline: the penguin does the deploying, Windows does the
installing.

Everything on the host is one of four services:

| service | job | where it comes from |
|---|---|---|
| TFTP | serve `ipxe.efi` for the first hop | QEMU's built-in TFTP (VM) or dnsmasq (LAN) |
| HTTP | serve everything after that | a rootless nginx started by `04` |
| a VM | a cheap target to test against | QEMU + OVMF + swtpm, from `05`/`06` |
| proxy-DHCP | tell real machines on the LAN where TFTP is | dnsmasq, from `07` |

## 2. Setting up the underpinnings (`scripts/`, what exists today)

The numbered scripts are the v1 pipeline. The prefixes are historical; the
real order is below. Each is short bash you can read in a minute.

**Step 1, `00-bootstrap.sh`.** Creates `pxe/`, `http/winpe/`, `answer/`,
`vms/` and copies `config.sh.example` to `config.sh`. Everything host-specific
lives in that one file: ISO path, VM size, HTTP port, OVMF firmware paths.
Read `config.sh.example` once and you know every knob.

**Step 2, `01-install-deps.sh`.** Installs the apt packages: wimtools (wimlib,
for reading and writing WIM images on Linux), nginx, aria2, cabextract,
chntpw, and the build tools iPXE needs. Then downloads the latest `wimboot`
release into `pxe/` and checks that it is a PE binary of plausible size.

**Step 3, `00b-download-iso.sh` (optional).** If you have no Windows 11 ISO,
this queries UUP dump for the latest 24H2 amd64 build, downloads the
conversion package, and runs its Linux converter to build an ISO from
Microsoft's own update servers. It is a 4 to 6 GB download. One limit: the
Linux converter cannot integrate cumulative updates, so you get the RTM build.

**Step 4, `00c-build-ipxe.sh`.** Clones iPXE, writes a six-line script into
`build/ipxe/chain.ipxe`, and compiles `ipxe.efi` with that script embedded.
The script does DHCP, retries until it succeeds, then chains to one URL:

```
chain http://10.0.2.2:8080/boot.ipxe
```

`10.0.2.2` is how a QEMU user-mode-network guest reaches its host. For real
hardware, `07` rebuilds this with your LAN IP. The port is baked in too, which
is why the README says to re-run this after changing `HTTP_PORT`.

**Step 5, `02-extract-winpe.sh`.** Loop-mounts the ISO with sudo and copies
four files into `http/winpe/`: `bootx64.efi` (renamed `bootmgfw.efi`), the
`BCD` store, `boot.sdi`, and `sources/boot.wim`. It also symlinks `wimboot`
in. The plan notes this sudo is unnecessary and 7z can do the same extraction
unprivileged; that is on the Phase 1 list.

**Step 6, `03-inject-autounattend.sh`.** The v1-specific step, and the one the
new plan removes. It uses `wimlib-imagex update` to write two files into every
image inside `boot.wim`: `answer/autounattend.xml` and a generated
`startnet.cmd`. WinPE runs `startnet.cmd` automatically at boot. The generated
one calls `wpeinit` (brings up networking), then searches drive letters for
`\sources\setup.exe` (the ISO is attached to the VM as a CD-ROM) and runs
Windows Setup with the answer file. The answer file wipes disk 0, lays out GPT
partitions, creates a local admin named `deploy`, enables autologon and hides
OOBE.

**Step 7, `04-setup-http.sh`.** Writes `pxe/boot.ipxe`, the second-stage iPXE
script. It is the whole boot chain in nine lines:

```
set base http://10.0.2.2:8080/winpe
kernel ${base}/wimboot || shell
initrd --name bootmgfw.efi ${base}/bootmgfw.efi
initrd --name BCD          ${base}/BCD
initrd --name boot.sdi     ${base}/boot.sdi
initrd --name boot.wim     ${base}/boot.wim
boot
```

Then it generates an nginx config under `run/` and starts nginx as your own
user on `HTTP_PORT`, document root `http/`. No system nginx, no sudo. It
refuses to start if the port is taken and never kills anything else.

**Step 8, `05-create-vm.sh`.** Makes a qcow2 disk, a swtpm state directory
(software TPM 2.0, because Windows 11 Setup demands one) and a copy of the
OVMF UEFI variable store. It asks before recreating an existing disk.

**Step 9, `06-boot-vm.sh`.** Starts swtpm, then QEMU with: the
Secure-Boot-capable OVMF build paired with the *empty* variables template (so
the firmware is "capable" but not enforcing, which lets the unsigned
self-built `ipxe.efi` load), the disk on AHCI, the ISO as a CD, and a
user-mode NIC whose built-in TFTP server serves `pxe/` with `ipxe.efi` as the
boot file. Boot order is disk, then network, then CD. An empty disk falls
through to PXE; once Windows is installed the disk boots first and there is no
reinstall loop. The script resets NVRAM only while the disk is effectively
empty, for the same reason.

**Physical machines, `07-setup-physical.sh`.** Detects your LAN interface and
IP, rebuilds `ipxe.efi` and `boot.ipxe` for that IP, and writes a dnsmasq
config in proxy-DHCP mode. Proxy-DHCP does not hand out addresses, so it
coexists with your router. It only answers UEFI x64 PXE clients with "your
boot file is `ipxe.efi`" and serves it over TFTP. The script prints the
command to start dnsmasq and a warning: any UEFI machine that PXE-boots on
that LAN will have disk 0 wiped.

**`99-teardown.sh`** stops QEMU, swtpm, this repo's nginx and dnsmasq, and
with `--purge` deletes VM state and generated configs.

## 3. What happens at boot, in order

1. Firmware PXE gets a DHCP lease and a boot file name. In the VM that comes
   from QEMU's built-in DHCP/TFTP. On a LAN it comes from dnsmasq proxy-DHCP.
2. Firmware fetches `ipxe.efi` over TFTP and runs it.
3. iPXE does its own DHCP, then fetches `boot.ipxe` over HTTP. This is the
   first request you see in `run/access.log`.
4. iPXE fetches wimboot and the four WinPE files over HTTP (about 500 MB,
   mostly `boot.wim`), then hands control to wimboot.
5. wimboot boots WinPE from RAM. WinPE runs `startnet.cmd`.
6. In v1, `startnet.cmd` runs Windows Setup from the attached ISO with the
   answer file. Setup partitions the disk, applies the image, reboots into the
   installed OS, and the answer file's OOBE settings take you to a desktop.

Verified end to end on 2026-06-02, including the disk booting on its own
afterwards.

## 4. Where it is going (`PLAN.md`)

The v2 spikes of 2026-09-22 (`spikes/2026-09-22-wimboot-task-sequence/`)
changed two things, and both follow from one discovery: wimboot injects any
extra `initrd` file into `X:\Windows\System32` of the booted WinPE. That means:

- **`boot.wim` stays pristine.** Step 6 goes away. The task sequence becomes
  text files on the HTTP server (`winpeshl.ini`, `deploy.cmd`, steps), and
  editing the install is editing a text file. No WIM rewrite.
- **Setup.exe goes away too.** The task sequence does what MDT does:
  `diskpart` from a script, download `install.wim` over HTTP with an injected
  `curl.exe`, `dism /apply-image`, `dism /add-driver` from a driver pack built
  on Linux with wimlib, `bcdboot`, drop an `unattend.xml` into Panther,
  reboot. That gives a place to do things between apply and first boot, such
  as drivers, which Setup.exe never offered. The spike ran the whole thing in
  about two and a half minutes on a VM.

The rest of the plan is layering: per-machine config keyed on the SMBIOS UUID
that iPXE sends in the `boot.ipxe` query string, role images captured from a
sysprepped reference VM, winget at first logon, then real hardware, then
making it installable by someone else. `PLAN.md` §3.2 is the observability
layer under all of it: beacons with identity, logs pushed back over HTTP,
steps you can stop before and re-run by hand.

## 5. Trying it

The README's "State of this host" note matters: port 8088 in `config.sh` was
taken on the original host, and the v1 pipeline is torn down there. On a
fresh Ubuntu 24.04 box with KVM, OVMF and swtpm installed, the nine steps in
§2, in that order, should get you to a Windows desktop in a VM:

```bash
bash scripts/00-bootstrap.sh        # dirs + config.sh (set ISO_PATH, or run 00b)
bash scripts/01-install-deps.sh
bash scripts/00b-download-iso.sh    # optional
bash scripts/00c-build-ipxe.sh
bash scripts/02-extract-winpe.sh    # sudo (loop mount)
bash scripts/03-inject-autounattend.sh
bash scripts/04-setup-http.sh
bash scripts/05-create-vm.sh
bash scripts/06-boot-vm.sh          # HEADLESS=1 for no window
```
