# How this repo works, from the ground up

A guided tour for someone new to the project: the one idea it is built on, the
pieces you set up on the Linux host, what happens second by second when a
machine boots, and where the design is heading. It describes the code as of
2026-10-02 (Phase 1 of `PLAN.md`). `README.md` is the reference for the
scripts, `PLAN.md` for the direction; this file is the narrative that connects
them.

## 1. The one idea

A PC that PXE-boots asks the network for something to run. This repo answers
with a chain of three things, each fetched over the network, each handing off
to the next:

1. **iPXE** (`pxe/ipxe.efi`), a small open-source network bootloader. The
   firmware's own PXE stack can only run a UEFI binary, so this is the first
   hop. It is the only binary the repo compiles, and the only thing baked into
   it is one URL.
2. **wimboot**, another small binary from the iPXE project. It takes
   Microsoft's boot manager, its BCD store, `boot.sdi` and a `boot.wim`, and
   boots Windows PE from RAM as if they had come from a DVD. It has one more
   trick, and the whole design leans on it: any *extra* file it is handed
   appears inside the booted WinPE, in `X:\Windows\System32`.
3. **Windows PE** (`boot.wim`, lifted unmodified from a Windows 11 ISO). A
   minimal Windows that runs from RAM. Once it is up it does the actual install
   with Microsoft's own tools.

The Linux host never runs anything Windows. It serves files. Windows does the
installing, from inside WinPE, following instructions the Linux host wrote as
plain text. The penguin does the deploying, Windows does the installing.

Everything on the host is one of three services:

| service | job | where it comes from |
|---|---|---|
| TFTP | hand `ipxe.efi` to the firmware | QEMU's built-in TFTP (lab VM) or dnsmasq (`bin/pxe-lan`, real LAN) |
| HTTP | everything after that, in both directions | a rootless nginx (`bin/serve`) |
| a VM | a cheap target to test against | QEMU + OVMF (`bin/vm-create`, `bin/vm-boot`) |

## 2. Setting up the host (`bin/`)

Each script is one verb, short enough to read in a couple of minutes, safe to
re-run, and reads its settings from `config.sh` through `bin/lib.sh`. None of
them needs root (only `bin/pxe-lan start` does, for dnsmasq).

**`config.sh`.** Copy `config.sh.example`. The settings that matter: `ISO_PATH`
(your Windows 11 ISO), and `HTTP_HOST` + `HTTP_PORT`, the address targets use
to reach this server. For the lab VM that is `10.0.2.2`, which is how a QEMU
user-mode-network guest sees its host.

**`bin/fetch-iso`** (optional). No ISO? This asks UUP dump for the newest
public build of a release, downloads its conversion kit and the packages from
Microsoft's update servers, and assembles an ISO under `iso/`. The Linux kit
cannot integrate cumulative updates, so you get the release's base build.

**`bin/fetch-tools`.** Downloads the third-party pieces: `wimboot`, the
official Windows `curl.exe` (stock WinPE has no HTTP client that can fetch a
binary), and wimlib for Windows. Each is pinned by SHA-256 and refused if it
does not match. That is not paranoia: upstream once replaced the `wimboot
v2.9.0` release file with a different binary under the same version.

**`bin/stage-winpe`.** Pulls four files out of the ISO with `7z` into
`http/winpe/`: `bootx64.efi` (renamed `bootmgfw.efi`), the `BCD` store,
`boot.sdi`, and `sources/boot.wim`. Nothing is modified. Re-running it compares
each file with the ISO's copy and extracts only what differs.

**`bin/stage-image`.** Publishes the ISO's `install.wim` as
`http/images/base.wim`, with a `base.json` sidecar recording exactly what it is
(edition, build, size, SHA-256, where it came from). An `install.esd` or a
multi-edition WIM is exported to a single-image WIM with wimlib first.

**`bin/build-ipxe`.** Checks out a pinned iPXE commit, writes a ten-line script
into `build/ipxe/chain.ipxe`, and compiles `pxe/ipxe.efi` with it embedded. The
script does DHCP, retries until it succeeds, then chains to one URL:

```
chain http://10.0.2.2:8090/boot.ipxe?uuid=${uuid}&mac=${netX/mac}&product=${product:uristring}&…
```

The query string does nothing for iPXE. It is there so the server's access log
records who booted.

**`bin/serve`.** Writes `run/nginx.conf` and starts nginx as your own user,
document root `http/`. Besides static files it has three special locations:

- `GET /beacon?…` answers `ok` and logs the query string as one line in
  `run/beacons.log`. This is how targets report progress.
- `GET /ts/id.cmd?id=…&mac=…` answers with a generated three-line batch file:
  `set "SRV=http://<the host:port you called>"`, `set "ID=<uuid>"`,
  `set "MAC=…"`. More on this below.
- `PUT /uploads/<id>/<run>/<file>` stores a file under `http/uploads/`. Upload
  only: a GET of the same path is refused.

It refuses to start if the port is taken (it never kills anything), and it
tests its own endpoints every time it starts.

**`bin/lint`.** Reads `boot.ipxe`, the task sequence and every machine cfg and
checks that each file they refer to exists, that images match their sidecars,
that files Windows runs have CRLF line endings, that `ipxe.efi` still matches
`config.sh`. A typo that would be a 404 three minutes into a boot is a `FAIL`
row before anything boots. Each run also breaks a scratch copy in eleven known
ways and requires all eleven to be reported, so a green result means the
checker is actually checking.

**`bin/vm-create <name>`, `bin/vm-boot <name>`.** A lab VM: empty disk, UEFI
variables, and a fixed SMBIOS UUID and MAC of its own (QEMU's default UUID is
all zeros, which would make every VM the same machine). The hardware is chosen
so stock WinPE needs no extra drivers: an e1000e NIC and an AHCI disk.
`vm-create` also writes `http/machines/<uuid>.cfg` with `MODE=deploy`, which is
what allows this VM, and only this VM, to be installed.

## 3. What happens at boot, in order

1. **Firmware PXE** gets a DHCP lease and a boot file name, fetches
   `ipxe.efi` over TFTP and runs it.
2. **iPXE** does its own DHCP and fetches `boot.ipxe` over HTTP, with its
   identity in the query string. First line in `run/access.log`.
3. **`http/boot.ipxe`** is static, and every URL in it is relative to itself,
   so it names no host or port. It loads wimboot, the four WinPE files (about
   500 MB, mostly `boot.wim`) and five extra files: `winpeshl.ini`,
   `deploy.cmd`, `id.cmd`, `curl.exe`, `libcurl-x64.dll`.
4. **wimboot** boots WinPE from RAM with those five files sitting in
   `X:\Windows\System32`. `winpeshl.ini` is the file WinPE consults to decide
   what to run instead of its default shell; ours says: run `deploy.cmd`.
5. **`deploy.cmd`, the task sequence**, starts by calling `id.cmd`. That is
   the generated file from `bin/serve`: iPXE asked for it with the machine's
   UUID in the URL, the server echoed the UUID back inside a batch file, and
   now WinPE knows who it is and where the server is without detecting
   anything. Then:
   - bring up the network (`wpeinit`), wait for `SRV/health`;
   - fetch `machines/<id>.cfg`. **No file, or `MODE` other than `deploy`: report
     `shell`, push the log, stop at a prompt.** Nothing has been touched;
   - `preflight`: check that the image, unattend, diskpart script and driver
     pack this install needs are all on the server, *before* destroying anything;
   - `disk`: `diskpart` with `ts/diskpart/uefi-gpt.txt` (GPT: ESP, MSR, Windows);
   - `download`: `images/base.wim` to the new Windows partition with `curl`;
   - `apply`: `dism /apply-image`;
   - `drivers` (if the cfg names a pack): apply the pack, `dism /add-driver`;
   - `boot`: `bcdboot` writes the boot files and firmware entry;
   - `unattend`: copy `unattend/default.xml` to `W:\Windows\Panther\`, and
     leave `C:\pdt\` on the new disk with `id.cmd` (now also carrying the run
     token) and two small scripts for later;
   - reboot.
   Every step sends `ev=start` then `ev=ok` or `ev=fail` to `/beacon`, writes
   its output to `X:\pdt\ts.log`, and uploads the logs after it finishes.
6. **The installed Windows** boots from disk. The unattend file runs
   `C:\pdt\beacon.cmd specialize ok`, creates the local account, logs on once,
   and runs `C:\pdt\firstlogon.cmd`, which reports `firstlogon` and uploads
   Setup's own logs. Same id, same run token: one continuous timeline from
   iPXE to desktop.

The lab VM's network is QEMU's user-mode stack by default, with QEMU itself
answering DHCP and TFTP. `bin/lab-netns` runs the same lab on a bridge inside a
private network namespace, with dnsmasq doing DHCP and TFTP exactly as it would
for real hardware, and still without root (README, "The bridged lab").

In the lab VM the whole thing takes about two and a half minutes. Follow it
with `bin/status --watch`, or script it:

```bash
bin/vm-boot lab01 && bin/await lab01 firstlogon 900 && bin/vm-shot lab01
```

## 4. Why it is built this way

- **`boot.wim` stays pristine.** The first version of this repo rewrote
  `boot.wim` with wimlib to add a script and an answer file. Injection at boot
  makes that unnecessary: changing the install is editing a text file under
  `http/ts/` and rebooting the target.
- **`dism`, not `setup.exe`.** The first version ran Windows Setup with an
  `autounattend.xml`. Applying the image ourselves is what MDT does, and it
  gives a place to do things between "image on disk" and "first boot", such as
  injecting drivers, that Setup never offered.
- **One channel, HTTP.** Boot files, images, driver packs, instructions,
  progress and logs all go over the same nginx. No SMB share, no credentials.
- **Static files are the control plane.** Which machine may be wiped is a file
  (`machines/<uuid>.cfg`). What the install does is a file (`ts/deploy.cmd`).
  What happened is two log files. There is no database and no dispatcher.

The retired first version, with its own notes, is in
`docs/history/v1-setup-exe/`.

## 5. Where it is going (`PLAN.md`)

Phase 2 splits `deploy.cmd` into one file per step that can each be re-run by
hand from the WinPE prompt, adds the recovery partition, and per-model driver
selection. Then winget at first logon (Phase 3), role images captured from a
sysprepped reference VM (Phase 4), real hardware on a real LAN (Phase 5), and
an install guide good enough that someone else can stand the server up
(Phase 6). `TODO.md` has the order and the open questions.

## 6. Trying it

The README's quick start is the whole procedure. On a fresh Ubuntu 24.04 box
with KVM and a Windows 11 ISO:

```bash
cp config.sh.example config.sh     # set ISO_PATH
bin/fetch-tools && bin/stage-winpe && bin/stage-image && bin/build-ipxe
bin/serve && bin/lint
bin/vm-create lab01 && bin/vm-boot lab01
bin/await lab01 firstlogon 900 && bin/status lab01
```
