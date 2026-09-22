# Spike 2026-09-22: wimboot-injected task sequence + DISM apply-image, all over HTTP

Two throwaway-VM experiments that back the decisions in `../../PLAN.md` §2.
Everything ran on this host from a scratch directory; nothing in `scripts/` was
used or changed. Large inputs are not stored here (see "Inputs").

## Spike 1: pristine boot.wim, task sequence injected by wimboot

Files: `chain.ipxe` (embedded in a rebuilt `ipxe.efi`, chains to
`http://10.0.2.2:8090/boot.ipxe?<SMBIOS+NIC identity>`), `http/boot1.ipxe`,
`http/ts/winpeshl.ini`, `http/ts/deploy.cmd`, `http/ts/http.js`,
`http/ts/machine.cfg`, `nginx.conf` (rootless, `/beacon` returns 200 and the
access log keeps query strings), `vm/launch.sh` (QEMU: OVMF secboot in Setup
Mode, AHCI disk, **e1000e** NIC, headless, monitor on TCP), `vm/shot.sh`
(screenshot via QEMU monitor `screendump`).

Result **[verified]** (`vm/spike1-winpe-console.png`):

- iPXE request carried `mfr=QEMU`, `product=Standard PC (Q35 + ICH9, 2009)`,
  `uuid`, `mac=52:54:00:12:34:56`, `chip=82574l`, `busid=01:80:86:10:d3`.
- wimboot injected `winpeshl.ini`, `deploy.cmd`, `http.js` into
  `X:\Windows\System32` of the untouched `sources/boot.wim` (build 26100.1).
- In WinPE: `reg query HKLM\HARDWARE\DESCRIPTION\System\BIOS` gave
  manufacturer/product; `wmic csproduct` worked; `diskpart` listed the disk;
  `ipconfig` showed `10.0.2.15` via the inbox e1000e driver; `cscript` + MSXML
  fetched text over HTTP and sent beacons. Time from `boot.wim` download
  complete to first beacon: 9 s.

Negative control **[verified]** (`vm/negative-control-rawwim.png`): same boot
with `wimboot rawwim` (injection disabled) → stock Windows Setup UI ("media
driver missing", no ISO attached), no beacon within 75 s.

## Spike 2: diskpart → HTTP download → DISM apply → drivers → bcdboot → unattend

Files: `http/boot2.ipxe` (also injects the official Windows `curl.exe` +
`libcurl-x64.dll`), `http/ts/deploy2.cmd` (injected as `deploy.cmd`),
`http/ts/diskpart.txt` (GPT: 260 MB ESP `S:`, 16 MB MSR, rest NTFS `W:`; no
recovery partition), `http/ts/unattend.xml` (Panther: specialize + oobeSystem,
beacons in `RunSynchronous`/`FirstLogonCommands`, every-boot beacon registered
with `schtasks`).

Server log (all requests from the VM; wall clock on this host):

| time     | stage beacon   | meaning |
|----------|----------------|---------|
| 03:55:39 |                | VM launched |
| 03:55:54 | ts-start       | WinPE up, network up, `curl.exe` running |
| 03:56:09 | downloaded     | 3.5 GB `install.wim` to `W:\` over HTTP (~15 s via QEMU user-net) |
| 03:56:57 | applied        | `dism /apply-image /index:1 /applydir:W:\` (15.7 GB of files) |
| 03:56:57 | drivers-added  | `virtio-w11.wim` (built with `wimlib-imagex capture`) applied to `W:\Drivers`, `dism /image:W:\ /add-driver /recurse` |
| 03:56:57 | ts-done        | `bcdboot W:\Windows /s S: /f UEFI`, `unattend.xml` → `W:\Windows\Panther`, `wpeutil reboot` |
| 03:57:27 | specialize     | installed Windows booted from disk and ran the Panther unattend |
| 03:58:03 | firstlogon, host=SPIKE2 | autologon as `spike`, computer name applied (`vm/spike2-desktop-after-apply.png`) |

Then the VM was shut down and relaunched with the NIC changed from `e1000e` to
`virtio-net-pci` (`NIC=virtio-net-pci NICROM=virtio vm/launch.sh`). The
every-boot beacon can only arrive if the injected netkvm driver works:

- **Driver injection [verified by outcome]:** Windows booted from disk and,
  with only a `virtio-net-pci` NIC, obtained `10.0.2.15` and opened ~15 TCP
  sessions to Microsoft endpoints (QEMU monitor `info usernet`, 04:01:34, and
  `vm/virtio-nic-boot.png`). Stock Windows has no virtio driver, so this is the
  injected `netkvm` driver working.
- **Every-boot beacon [unknown]:** no `stage=boot` request arrived within 4
  minutes. Either the `schtasks /sc onstart` registration failed at first logon
  or the task ran before the network was up. Do not rely on an `onstart` task
  as a network probe; use a delayed/trigger-on-network task or a first-logon
  probe instead.

## Inputs (not stored here)

- `sources/boot.wim`, `sources/install.wim` extracted from `win11.iso` with
  `7z x` (no mount, no sudo).
- `curl.exe` + `libcurl-x64.dll` from `https://curl.se/windows/` (8.22.0_1 win64-mingw).
- virtio-win drivers from
  `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso`
  (`NetKVM/w11/amd64`, `viostor/w11/amd64`, `vioscsi/w11/amd64`), packed with
  `wimlib-imagex capture <dir> virtio-w11.wim --compress=LZX`.
- `ipxe.efi` rebuilt from `build/ipxe/ipxe` with `EMBED=chain.ipxe`.

## Facts established along the way

- Stock boot.wim (26100.1, Setup image) has: `Dism.exe diskpart.exe bcdboot.exe
  drvload.exe pnputil.exe wpeutil.exe wbem\WMIC.exe cscript.exe wscript.exe
  reg.exe net.exe netsh.exe Robocopy.exe expand.exe mshta.exe msxml3/6.dll
  vbscript/jscript.dll wimgapi.dll`. It has **no** `curl.exe`, `powershell.exe`,
  `bitsadmin.exe`, `certutil.exe`, `tar.exe`, `timeout.exe`, and no `winpeshl.ini`.
- Inbox NIC drivers include Intel e1000/e1000e, Realtek, Broadcom, Mellanox,
  Marvell/Aquantia; storage includes AHCI, NVMe, LSI/MegaRAID/PERC, Hyper-V and
  VMware (`pvscsi`). No virtio.
- wimboot v2.9.0 injects into `\Windows\System32` and appends entries without
  checking for an existing name (source `src/wimpatch.c`).
- The UUP dump Linux converter cannot integrate updates (`files/convert.sh`).
