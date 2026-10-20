# Seeing and driving a machine you cannot sit at

Written 2026-10-12 for a laptop with a damaged screen, but it applies to
every physical machine: there is no QEMU monitor to type into or screenshot
from. What is here is tagged **[verified]** (run in the lab), **[read]**
(from documentation or source, not run) or **[unknown]**.

## The two that matter, both over the HTTP channel we already have

### 1. Remote shell over HTTP **[verified, built]** — `bin/shell`

```
bin/shell latitude 'dir W:\'                 # output in ~2 s, exit code passed through
bin/shell latitude 'X:\pdt\steps\45-winre.cmd'
bin/shell latitude --off                     # kill switch
```

How: `deploy.cmd` starts `ts/shell-loop.cmd` once per boot, in its own
window, right after `ts-start`. The loop polls `cmd/<id>/<run>/<n>.cmd` on
the server every 2 s, runs what it finds with `cmd /c` (the WinPE
environment loaded), uploads the output as `cmd-<n>.out`, counts `n` up.
`bin/shell` writes the next numbered file and waits for the output.

Why this shape: no new binary, no listening port on the target, no
credentials; the trust boundary is unchanged, because whoever can write to
`http/` already runs code as SYSTEM on every booting machine (that is what
`deploy.cmd` is). The run token scopes commands to one boot; the counter
means nothing runs twice. It is alive at the WinPE prompt, after a stopped
step and after a failed one, which is exactly when you need it.

Evidence: `spikes/2026-10-12-remote-shell/` (round trip 2.2 s, exit codes,
environment, kill switch with a timeout control).

Not in the installed OS: the toolkit leaves no agent behind after first
logon, by design. There, use RDP (below).

### 2. Screen pusher over HTTP **[verified, built]** — `bin/screen`

`tools-src/pdt-screen.c` (62 lines of plain Win32: BitBlt the virtual
screen into a DIB, write a BMP, temp-name-and-rename so no half file is ever
uploaded) is built on the host by `bin/build-tools` with mingw-w64, hashed and
recorded in `tools/built.json`, and served from `tools/`. The shell loop
fetches it if it exists and then uploads `screen.bmp` every 5 s;
`bin/screen <machine>` converts the latest to PNG (`run/shots/<name>-live.png`)
and `--watch` keeps doing so, which with an auto-reloading viewer is a live
view of the machine's screen on the server.

Verified: on a WinPE VM, `bin/screen` and `bin/vm-shot` taken at the same
moment are pixel-identical (1280×800, 100.00%); a push is a 3 MB BMP every
~6 s (0.07 s to upload on this host; about 0.3 s on 100 Mbit); `bin/shell
--off` stops the pushes and `bin/screen` then reports the growing age. It
also runs beside a deploy: a shell command and a screen during `30-apply`,
and the deploy still finishes (`spikes/2026-10-12-remote-shell/`).

Why not something cleverer: the installed OS could do this in PowerShell,
but WinPE (the Setup `boot.wim`) has no PowerShell and no .NET, so a tiny
native program is the honest minimum; it has no network code of its own
(curl uploads it), and it is optional (`[optional]` in the loop; `lint`
reports it as such until built). It needs `gcc-mingw-w64-x86-64` on the host
(`bin/build-tools` says so if it is missing; `bin/build-tools check` tells a
stale binary from a current one by the source hash).

### What you get with both

PXE → WinPE → every step → first logon, as beacons and logs (today), plus a
shell into WinPE and a picture of the screen every 5 s, on the server, with
nothing attached to the machine. For the laptop, that covers everything
after the firmware.

## The firmware is the one part that is not remote

Enabling UEFI PXE needs the firmware setup once. Options, best first:

1. **An external display, once** (the E5570 has HDMI and VGA; Dell firmware
   shows on it). Ten minutes.
2. **From the Linux already on it** (Kali): read `dmidecode -s system-uuid`,
   `system-product-name`, the NIC's MAC → write its `machines/<uuid>.cfg`
   before it ever boots PXE. Firmware settings from Linux: `fwupdmgr
   get-bios-setting` / `set-bios-setting` through the `dell-wmi-sysman` driver
   **[read: supported on many Latitudes, unknown for a 2016 model]**, or
   Dell Command | Configure for Linux (`cctk --embnic1=enabledpxe`,
   `--forcepxeonnextboot=enable`) **[read]**. `efibootmgr -n <id>` can pick a
   UEFI network boot entry for the next boot once the network stack is on.
3. **Intel AMT** (below), if the unit has vPro and gets provisioned once.

Once PXE is on, the **collector** (`docs/COLLECTOR.md`, built after this
page was written) is how such a machine is driven: it boots into RAM,
reports everything, takes `bin/shell` and SSH, and `pdt-pxe-next` sends it
into Windows PE.

## Intel AMT as out-of-band management from Linux

The E5570's i7 options: i7-6600U and i7-6820HQ are vPro parts, i7-6500U is
not; the service tag's configuration on Dell's support site says which, and
on Kali `lspci | grep -i MEI` plus `mei-amt-check` (package `amtterm`) says
whether AMT is present and provisioned **[read]**. If it is a vPro unit:

- **KVM over VNC** (the firmware screen included: BIOS setup, PXE, WinPE),
  **Serial-over-LAN**, power on/off/reset, **boot to PXE / to BIOS setup**
  on demand, all from Linux (`amtterm`, `amttool`, `wsmancli`, MeshCommander)
  **[read]**. That is a complete answer to a screenless machine, for ever.
- The catch: provisioning. MEBx (Ctrl+P at POST) needs a screen once, and
  gives "Admin Control Mode" where KVM needs no on-screen consent. Host-based
  provisioning from the OS (Intel ACUConfig/EMA) needs no screen but lands in
  "Client Control Mode", where **KVM asks for a consent code shown on the
  machine's screen**, which is the one thing we cannot read. So: provision via
  MEBx during the same external-display session as the PXE setting.
- Lab hygiene: AMT listens on 16992/16993 (web/WS-Man) and 5900 (KVM); keep it
  on the lab LAN and set a real MEBx password.

## Answers to the other questions

**An RDP server in WinPE, copied from an install or from ReactOS?** No.
Windows' RDP *server* is not a program but a subsystem: `termsrv.dll` under
the Remote Desktop Services service, the RDP-Tcp listener, session creation
through Winlogon/LSASS, licensing. WinPE has none of that machinery (one
session, no interactive logon), so the files alone do nothing. ReactOS has
an `mstsc` port, a *client*: it would let the target connect out, the wrong
direction. Microsoft's sanctioned "see the WinPE screen" is DaRT's Remote
Connection (MDOP, Software Assurance licensing). Third-party VNC servers
(UltraVNC, TightVNC) do run in WinPE and are the community answer; they are
a listening service with their own auth on every booting machine, which the
screen pusher avoids. Plan B if a live interactive session is ever needed.

**RDP into the installed Windows.** Yes, and built in: the role key `RDP=on`
(`fDenyTSConnections=0`, NLA on, the firewall group, the role's accounts in
Remote Desktop Users) gives a full desktop from Linux (`xfreerdp`, Remmina)
after first logon; `bin/vm-boot --fwd 3390:3389` reaches a lab VM's.
Verification: `spikes/2026-10-12-ssh-rdp/`. `SSH=on` (Windows' OpenSSH
server, PowerShell remoting over SSH) is written up from the same template
in `DEFERRED.md`, "Remote access as role settings", not built.

**A serial console, like Linux's?** Windows has one: EMS/SAC. `bcdedit
/ems on` plus `/emssettings` on the BCD gives a text console over a COM port
from the boot manager through the kernel, with a Special Administration
Console (`cmd` channels, process list, reboot) **[read]**; WinPE supports it
too. What it needs is a real UART at a legacy I/O address: a USB-serial
adapter does not qualify, this laptop has no serial port, and its E-Port dock's
RS-232 **[unknown]** whether the firmware exposes it as a 16550. The
"virtual serial port" that does work is **AMT Serial-over-LAN**: EMS over SOL
is the classic combination, and it would show boot-time text with no screen
at all. In QEMU, `-serial` would make it testable; our `BCD` is Microsoft's
from the ISO and is served as is, so a lab spike would first need a way to
set the EMS elements in it (`bcdedit` from inside WinPE on a served copy, or
`hivex` on Linux). Feasible, not started; it only pays off with AMT or a
dock serial port.

**"Is the baseline tested? Is tailing `ts.log` all I need?"** Yes, tested
since Phase 2 (`spikes/2026-10-02-phase2-acceptance/`): `pushloop.cmd` uploads
`ts.log` every 20 s while a step runs, and `bin/logs <machine> --tail 5
ts.log` follows it; `bin/status --watch` shows every machine's last event
and flags `busy`/`STUCK?`/`FAIL`; `bin/await <machine> <step>` blocks on a
step. For "what is it doing", that is enough. What it cannot show is a
screen (a firmware prompt, a BSOD, a dialog), which is why the screen pusher
exists, and it cannot act, which is why the shell does.
