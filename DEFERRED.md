# DEFERRED

Ideas that were considered and deliberately parked, with the reason. They are
not gaps and not next steps (`TODO.md` has those); they are here so nobody
rediscovers them as surprises. Each says what would make it worth picking up.

## Design changes, after Phase 6 (PLAN.md §4 "Later / optional")

- **Streaming apply without the temp file.** A pipable WIM made on Linux,
  `curl … | wimlib-imagex.exe apply - 1 W:\` in WinPE. Saves the 3.5 GB write
  and read on the target and the space for it. Spike first: time it against
  download-then-`dism` on the same VM. Pick up if it is faster or a target has
  too small a disk.
- **A small dispatcher.** A Python service that renders `boot.ipxe` and
  `deploy.cmd` per machine instead of static `machines/` and `models/`
  directories. Pick up when hand-editing those directories is the main pain.

## Parked with a reason

- ~~**Remote shell over HTTP**~~ **Done 2026-10-12** as `bin/shell` +
  `ts/shell-loop.cmd` (`docs/REMOTE_VISIBILITY.md`): the first physical
  machine has a damaged screen. The 2 s poll is fine (2.2 s round trip); the
  kill switch is `bin/shell --off`.
- **Updating the recovery image.** The Safe OS dynamic update in every UUP set
  belongs in `images/<name>.winre.wim`; today WinRE stays at the base build
  while `35-updates` updates the OS. Would need `dism /mount-image` +
  `/add-package` on the recovery image inside WinPE, or Windows-side tooling.
  Parked until an updated WinRE matters (Reset this PC, repair). The input is
  on the host since 2026-10-11: `bin/fetch-iso --keep` left the 24H2 UUP set
  (8.2 GB) under `build/uupdump/4d7d34d3-…/UUPs/`, with the Safe OS dynamic
  update `Windows11.0-KB5125758-x64.cab` in it.
- **`bin/fetch-updates`.** Keep just the update packages of a UUP set; today
  it is `fetch-iso --keep` and picking files out of `build/uupdump/*/UUPs/`.
  Pick up when update packs are made monthly.
- **BIOS/MBR and multi-disk layouts.** One `ts/diskpart/uefi-gpt.txt` exists.
  UEFI-only is a deliberate scope choice; add a layout file when a machine
  needs one.
- **`bin/timeline`.** Folded into `bin/status <id>`, which already prints a
  boot's events with durations. Revive only if per-run comparison is wanted.
- **`${next-server}` as the server address** in the embedded iPXE script, to
  avoid rebuilding `ipxe.efi` per network. Verified not to work behind
  proxy-DHCP (it is the router). Closed, not parked.
- ~~**Disabling fast startup on deployed machines**~~ **Done 2026-10-02 as a role
  setting:** `FASTSTARTUP=off` in `roles/<name>/role.cfg` runs `powercfg /h off`
  at first logon (`http/roles/README.md` says why it is a property of the role,
  not of the toolkit). Machines without a role keep Windows' default.
- **`capture.ini` as a per-role exclusion list.** One list serves every capture
  today. Pick up when a role needs different exclusions.
- **A shim instead of signing `ipxe.efi` with our own key.** Verified
  unnecessary: `wimboot` and Windows' boot files are Microsoft-signed; only
  `ipxe.efi` needs our signature. A shim would only matter where enrolling a
  certificate in firmware is impossible.

## Spikes written up, not started

Each of these is designed far enough to start the day it is needed. Written
2026-10-19; nothing below has run. Tags as in `docs/REMOTE_VISIBILITY.md`:
**[read]** from documentation or source, **[unknown]** nobody has checked.

### A text frame log of the WinPE console: `pdt-console` (spike)

**The gap.** `bin/screen` is a picture of the machine, 3 MB of BMP every
5 s. It answers "what is on the screen" but not "what did it say ten
minutes ago", is not diffable, not greppable, and nothing can wait on it.
And `bin/shell` runs a *new* `cmd`: it cannot answer a prompt the deploy
window is sitting at (`diskpart` waiting, a `pause`, "Press any key", a
console tool's y/n). The screenwrap tool (sibling repo) keeps exactly the
thing missing here for programs under tmux: a frame log, one text snapshot
whenever the screen changes, plus `send-keys`. tmux's `capture-pane` and
`send-keys` are the tmux faces of two Win32 console calls Windows has had
since NT: `ReadConsoleOutput` and `WriteConsoleInput`. Windows never grew a
tmux around them; WinPE has them all the same.

**The tool.** `tools-src/pdt-console.c`, a sibling of `pdt-screen.c`: plain
Win32 (`kernel32` + `user32`), built by `bin/build-tools` with mingw-w64,
hash recorded in `tools/built.json`, served from `tools/`, fetched by
`shell-loop.cmd` as `[optional]`, so `lint` reports it the same way as
`pdt-screen.exe`. `boot.wim` stays pristine. Two verbs:

- `pdt-console dump <title> <out.txt>`: `FreeConsole()`, then for every
  process in a `CreateToolhelp32Snapshot` list try `AttachConsole(pid)`,
  `GetConsoleTitleW`, compare with `<title>`, `FreeConsole()` on a miss
  **[read: the documented way to reach another process's console; the
  console window itself belongs to conhost, whose pid `AttachConsole`
  refuses, so it is found by title, not by window]**. `deploy.cmd` sets
  `title pdt-deploy` once at start. Attached: open `CONOUT$`,
  `GetConsoleScreenBufferInfo` (size, cursor, viewport), `ReadConsoleOutputW`
  the viewport in row chunks (one call is capped at 64 KB on older builds
  **[read]**), write the rows as UTF-8 with trailing blanks trimmed, a first
  line `# cols=120 rows=50 cursor=3,12 title=pdt-deploy`. Temp name and
  rename, as `pdt-screen` does. Exit 0 written and different from the file
  already there, 4 identical (nothing to upload), 2 no such console, 3 I/O.
  `--all` dumps the whole buffer, not just the viewport (scrollback, until a
  `cls`).
- `pdt-console keys <title> <text>`: same attach, open `CONIN$`,
  `WriteConsoleInputW` a key-down and key-up `KEY_EVENT_RECORD` per
  character, `{enter}`, `{esc}`, `{ctrl-c}` tokens **[read]**. The
  `send-keys` half; `bin/vm-type` is the QEMU equivalent for lab VMs and the
  parity test for the spike (both must produce the same next frame).

**The loop.** `shell-loop.cmd` runs `dump` every `PDT_CONSOLE_EVERY` seconds
(default 1: a 120×50 frame is about 6 KB, a 80×25 one 2 KB, against 3 MB
per BMP) and uploads only on exit 0, as `uploads/<id>/<run>/console-<n>.txt`
plus `console.txt` (latest). Server side: `bin/console <machine>` prints
the latest frame, `--watch` redraws it, `--frames` lists them with times,
`--diff` shows consecutive frames as a diff; `bin/keys <machine> '<text>'`
writes `cmd/<id>/<run>/<n>.keys`, which the loop hands to `keys`. `bin/await
<machine> --screen 'text'` becomes possible: wait until a frame contains a
string, screenwrap's "check what the screen shows". Frames are timestamped
by upload time, which is enough; a timed recording (asciicast) could be
synthesised from them later, not now.

**Why it needs nothing WinPE lacks.** No Windows Terminal in WinPE: the
deploy window is a classic conhost console, so `ReadConsoleOutput` reads the
real buffer, not a ConPTY shadow **[read]**. `dism`'s progress line (`\r`
updates) lands in the frame as the current percentage, which is what one
wants to see during `30-apply`. The attaching process must have no console
of its own and must `SetConsoleCtrlHandler(NULL, TRUE)` first, or a Ctrl+C in
the deploy window reaches it too **[read]**. Everything runs as SYSTEM in
one session, so no access check stands in the way **[unknown: AttachConsole
across processes in WinPE specifically; expected to work, never tried]**.

**The spike** (`spikes/<date>-console-frames/`): build it; `MODE=shell` VM;
`bin/console` of the prompt equals what `bin/vm-shot` shows; a deploy with
`STOP_BEFORE=20-disk` on a second VM, `bin/keys` answers the stopped prompt
with `deploy 20` and the frames show the sequence continuing; frames during
`30-apply` show the percentage moving; frame size and upload rate measured;
`bin/shell --off` ends the frames (negative control); a `dump` against a
title that does not exist exits 2 and uploads nothing (second control);
`lint` reports the optional tool like `pdt-screen.exe`. About 150 lines of
C, 20 of cmd, two small `bin/` scripts.

**Pick up when** a physical machine sits at a prompt `bin/shell` cannot
answer, when watching `bin/screen` over a slow link becomes the bottleneck,
or when `bin/await` on screen text would save a manual check. Not before:
`bin/screen` already shows the one thing text cannot, a firmware screen or
a BSOD, and the beacons already say where a sequence is.

### libguestfs / hivex: offline registry and BCD edits on Linux (feasibility done)

`spikes/2026-10-20-libguestfs-hivex/`: hivex reads and writes the hives
pulled out of a WIM with wimlib, no root, no appliance (verified on
`SYSTEM`, `SOFTWARE`, the Default profile's `NTUSER.DAT` with a role's
`skel.reg` merged in, and the served WinPE `BCD`). In order of value: the
EMS/serial-console elements in the `BCD` from Linux; `ImageState` of a
captured image read on Linux in `stage-image`; the registry half of a role
baked into a role image at capture time; `virt-inspector` for an installed
-applications list in the sidecar (needs the appliance, i.e. a readable
`/boot/vmlinuz`). Pick up the first with the serial-console spike, the
second whenever `stage-image` is next touched.

### Remote access as role settings: `RDP=on`, and `SSH=on` from the same template

*(2026-10-20: `RDP=on` is built and verified up to the credential check,
`spikes/2026-10-12-ssh-rdp/`; what follows still applies to `SSH=on`.)*

`docs/REMOTE_VISIBILITY.md` proposes `RDP=on` and calls it small. SSH is
the same shape with one more file, and it is the access that works from
this Linux host with no display: `ssh` for a shell, `Enter-PSSession
-HostName` for PowerShell remoting over SSH, which Microsoft supports and
which needs none of WinRM's NTLM or Kerberos plumbing **[read]**. Both are
settings of the role, not of the toolkit, by the `FASTSTARTUP` argument in
`http/roles/README.md`: whether a machine accepts remote logons is a
property of what it is for. Both apply to the installed OS only: WinPE gets
neither (RDP: no Remote Desktop Services subsystem, see REMOTE_VISIBILITY;
SSH: Microsoft's `sshd` authenticates by minting a Windows logon token for
a local account, and WinPE has no accounts to log on to **[read]**; the
collector is the SSH-into-a-booted-machine answer, with no Windows on it).

**The template, `RDP=on`.** One key, one block in `firstlogon.cmd` after
`faststartup` and before `boot-tasks`, one beacon, one `lint` rule, one
host-side probe:

| key | file | meaning |
|---|---|---|
| `RDP` | `on` (or absent) | Remote Desktop with NLA at first logon: `fDenyTSConnections=0`, `WinStations\RDP-Tcp\UserAuthentication=1`, `Enable-NetFirewallRule -Name RemoteDesktop-UserMode-In-TCP,RemoteDesktop-UserMode-In-UDP` (rule ids, so not language-dependent). Administrators may connect; a `USERS` account in group `Users` needs `Remote Desktop Users`, a later `\|rdp` flag in `users.txt`. Beacon `rdp ok nla=on`; `rdp fail reason=edition=Core` on an edition without the server (Home) |

Host-side probe for the spike: `xfreerdp /v:<ip> /u:deploy /p:<pw>
/cert:ignore +auth-only` exits 0 without a display **[read]**; the lab role
gets `RDP=on` so it stays verified.

**`SSH=on`, the same block with a key file.**

| key | file | meaning |
|---|---|---|
| `SSH` | `on` (or absent) | OpenSSH Server at first logon, key-only, with PowerShell as the login shell and the `powershell` subsystem for remoting. Beacon `ssh ok port=22 shell=pwsh keys=N` |
| `SSHKEYS` | an `authorized_keys` file | required when `SSH=on` (`lint`: passwords are off, so a role with no keys would lock everyone out). Public keys, so serving them in clear is fine. Installed as `C:\ProgramData\ssh\administrators_authorized_keys` with the ACL `sshd` insists on: `icacls … /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"`. Any `USERS` administrator can then log in; per-user keys for `Users` accounts come later with `users.ps1` |

What the block does, in order **[read: Microsoft's OpenSSH server pages and
the Win32-OpenSSH wiki]**:

1. Install `sshd`. Two sources; the spike measures both and picks one:
   `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`, which
   wants Windows Update or a Features-on-Demand source and is then serviced
   by Windows; or the Win32-OpenSSH release from GitHub, fetched once by
   `bin/fetch-tools openssh`, pinned by hash, served from `http/post/openssh/`
   and installed with its `install-sshd.ps1`, which is the toolkit's usual
   shape (pinned, offline, no dependency on WU from inside the lab netns).
   winget has it too (`Microsoft.OpenSSH.Preview`) but unpinned at first logon.
2. `sshd_config`: `PasswordAuthentication no`, `PubkeyAuthentication yes`,
   `Subsystem powershell c:/progra~1/powershell/7/pwsh.exe -sshs -nologo`
   when PowerShell 7 is among the role's `APPS` (`Microsoft.PowerShell`;
   Windows PowerShell 5.1 has no `-sshs`, so without pwsh there is a shell
   but no remoting), and `HKLM\SOFTWARE\OpenSSH\DefaultShell` pointing at the
   same `pwsh.exe`, else at `powershell.exe`.
3. The keys file and its ACL (above).
4. `Set-Service sshd -StartupType Automatic`, `Start-Service sshd` (the
   first start writes the default config and host keys if missing); the
   firewall rule `OpenSSH-Server-In-TCP`, created by the installer, enabled
   or created.
5. Beacon. Host-side probe for the spike: `ssh -i <key> -o BatchMode=yes
   deploy@<ip> hostname` prints the name; `pwsh -c 'Invoke-Command -HostName
   <ip> -UserName deploy { $PSVersionTable }'` from this host is the
   remoting proof (this host needs `pwsh` for that one line, nothing else).
   Negative control: the same `ssh` with no key is refused, and a password
   is never asked for.

**The reference-image trap**, the one part that is not just a template
copy: a `REFERENCE=yes` machine with `SSH=on` has host keys under
`C:\ProgramData\ssh\ssh_host_*`, and sysprep does not touch them, so every
machine from the image would share them. `prepare-capture.cmd` deletes them
before sysprep, the service makes new ones at the next start **[read]**, and
the spike checks that two machines from one image show different host keys
(`ssh-keyscan`). `DEPLOY=remove` is unaffected: the keys are the
administrators' file, not the `deploy` account's.

**Where it goes.** `firstlogon.cmd`: `… → faststartup ok → rdp ok → ssh ok →
boot-tasks ok → …`; `CONTROL_POINTS.md` row 8 and `HOW_IT_WORKS.md` get the
two keys; the lab role turns both on so `bin/test-deploy` keeps them honest.

**Pick up when** the first physical machine is deployed (Phase 5): that is
the first machine one cannot `vm-shot`, and `ssh` from this host is the
cheapest way in. `RDP=on` first, as the template; `SSH=on` the same day.
