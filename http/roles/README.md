# http/roles/ — what a machine becomes after Windows is on it

A **role** is a directory here, `roles/<name>/`, and a machine (or a model)
takes one with `ROLE=<name>` in its cfg. Everything in it is served as static
files; `role.cfg` names the rest:

| key | file | meaning |
|---|---|---|
| `APPS` | one winget package id per line, optionally followed by winget options (`Microsoft.PowerShell --installer-type wix`: the MSI; the manifest's type names are winget's, `wix` for a WiX-built MSI), `#` comments | installed at first logon with `winget install --id <id> -e --silent --scope machine` (`post/winget.cmd`; a package with no machine-wide installer is installed for the deploy account instead, and the transcript says so: a per-user install vanishes with that profile under `DEPLOY=remove`). winget itself is bootstrapped first from `post/winget/`, the release pinned by `bin/fetch-tools winget`: an image built from install media has no App Installer at first logon |
| `POST` | a batch file | runs at first logon after the apps, elevated, from `C:\pdt\role\`; `..\id.cmd` and `..\beacon.cmd` are next to it |
| `UNATTEND` | an unattend.xml | replaces the cfg's `UNATTEND=` from `http/unattend/` for this role |
| `USERS` | `name\|group\|policy` per line | local accounts, created (or, if they exist, re-passworded) at first logon by `post/users.ps1`. Group `Administrators` or `Users`; policy `random` (a 32-character password from the OS generator) or `plain:<password>`. See "Accounts and passwords" |
| `SKEL` | a manifest: one relative path per line | the files, kept under `skel/` in the role directory, are copied into `C:\Users\Default`: Windows' `/etc/skel`, copied into every profile created from then on. `lint` insists the manifest and the directory agree |
| `SKELREG` | a `.reg` file (`reg export` format) of `HKEY_CURRENT_USER` keys | merged into the Default profile's hive (`C:\Users\Default\NTUSER.DAT`), so every profile created afterwards starts with those values: Explorer, locale and taskbar defaults are the usual use. `lint` refuses any other root |
| `DEPLOY` | `remove` (or absent) | delete the toolkit's own `deploy` account. `post/remove-deploy.cmd` deletes the account at the end of first logon (Windows allows deleting the logged-on account; the session lives until the restart that follows), registers a one-shot SYSTEM task for the next boot that removes the profile directory, and restarts (`deploy-remove ok account=deleted`, then `deploy-removed ok` from the next boot). `lint` requires `USERS` to create another `Administrators` account first. Skipped on a reference machine (sysprep needs `deploy`; the captured image's unattend makes it again) |
| `RDP` | `on` (or absent) | Windows' own Remote Desktop: enabled with NLA, the "Remote Desktop" firewall group opened, and every account of `USERS` added to Remote Desktop Users (Administrators may connect anyway). Beacon `rdp ok listening=yes`. From Linux: `xfreerdp /v:<machine> /u:<user> /p:<password>` (`/auth-only` to just check the credentials); in the lab, `bin/vm-boot <vm> --fwd 3390:3389` then `/v:127.0.0.1:3390` |
| `SSH` | `on` (or absent) | OpenSSH Server (Win32-OpenSSH, the MSI served from `post/openssh/`, pinned by `bin/fetch-tools openssh`), installed at first logon by `post/ssh.ps1`: key-only (no passwords), the role's `SSHKEYS` for every Administrators account, PowerShell as the login shell, and when PowerShell 7 is among `APPS` (`Microsoft.PowerShell`) the `powershell` subsystem that PowerShell remoting over SSH needs. Beacon `ssh ok port=22 shell=pwsh keys=N listening=yes`; host key fingerprints in the uploads as `ssh.txt`. From Linux: `ssh -i <key> admin@<machine>`, `Enter-PSSession -HostName <machine> -UserName admin`; in the lab, `bin/vm-boot <vm> --fwd 2223:22`. A reference machine loses its host keys before sysprep, so machines from the image get their own |
| `SSHKEYS` | an `authorized_keys` file | required with `SSH=on` (`lint`: a key-only server with no keys would lock everyone out). Public keys, served in clear like the rest of the role. Installed as `C:\ProgramData\ssh\administrators_authorized_keys` with the ACL sshd insists on; it serves every member of Administrators, so accounts in `Users` cannot log in over SSH. The lab role's file is written by `bin/fetch-tools openssh` from `~/.ssh/id_*.pub` (the same key the collector takes) and is not in git |
| `FILES` | file names, space-separated | companions of the post script, fetched next to it |
| `FASTSTARTUP` | `off` (or absent) | `off`: `powercfg /h off` at first logon, so every shutdown is a real shutdown and every power-on a real boot. Absent: Windows' default (fast startup on). See below |

Keys are checked by `bin/lint` (unknown key, missing file, `APPS` without the
winget packages fetched). WinPE's preflight checks the same before touching
the disk; `60-unattend` puts `role.cfg` and the files it names in `C:\pdt\role\`
and `firstlogon.cmd` works through them in this order:

```
firstlogon ok  →  winre ok  →  skel ok files=N  →  skelreg ok  →  users ok created=… set=… failed=
  →  users-upload ok  →  winget ok version=…  →  apps ok installed=… failed=
  →  faststartup ok state=off  →  rdp ok listening=yes  →  ssh ok port=22 shell=pwsh keys=1 listening=yes
  →  boot-tasks ok  →  role-post …  →  (POST script)
  →  deployed ok role=<name>   →  (REFERENCE=yes: prepare-capture)
  →  (DEPLOY=remove: deploy-remove ok account=deleted, restart, then deploy-removed ok from the next boot)
```

`deployed` is the verdict a fleet waits for: `bin/await <machine> deployed`.
It is sent whether or not every app installed; `apps fail installed=… failed=…`
before it says which did not, and `winget.txt` in the uploads says why.

**A reference machine with a role** (`REFERENCE=yes` + `ROLE=`) bakes the role
into the image it becomes: the stamp in `%WINDIR%\pdt-image.txt` records the
role and the SHA-256 of its apps list, and `bin/stage-image` copies it into
the published image's `.json`. A machine deployed from that image runs its own
role at first logon again (idempotent: winget reports what is already there,
verified). One trap, handled: sysprep refuses to generalize while an Appx
package is installed for a user but not provisioned for all users. winget
itself is provisioned by `post/winget.cmd`; its source index
(`Microsoft.Winget.Source`) is not and is removed by `prepare-capture.cmd`.
An app from `apps.txt` that is itself an Appx/MSIX installed per user will
stop sysprep the same way, and `sysprep-setuperr.log` in the uploads names it.

## Accounts and passwords

The unattend file creates the toolkit's own account, `deploy` (lab default: a
blank password, one autologon, member of Administrators), because something
has to run `firstlogon.cmd`. Everything else about accounts is the role's:

```
# users.txt
deploy|Administrators|random      # the unattend's account: keep it, but with a real password
alice|Users|random
kiosk|Users|plain:letmein         # only if you mean it: served in clear over HTTP
```

`random` passwords are generated on the machine, written to
`C:\pdt\users-out.txt` (readable by SYSTEM and the deploy account only),
uploaded to the server as `uploads/<id>/<run>/users.txt` (`bin/logs <m> --cat
users.txt`: the endpoint is write-only for machines and the directory is the
server owner's), and the file is deleted at the end of first logon;
`prepare-capture.cmd` deletes it again before sysprep, so no generated
password is ever captured into an image. If the upload fails, the file is
kept and `users-upload fail` says so; the passwords are then nowhere else.

`plain:` is for accounts whose password is not a secret (a kiosk); the role
directory is served to every machine that asks. `DEPLOY=remove` gets rid of
the toolkit's account once the role's own administrator exists; `SKELREG`
templates the registry side of a new profile. Not done: domain join (no
directory to test against yet).

## Why fast startup is a role setting

Windows 11 shuts down into hibernation by default ("fast startup"). The next
power-on *resumes*: no "at startup" tasks run, a disk or NIC changed in the
meantime confuses the resumed kernel, and `bin/vm-stop` (ACPI power button)
leaves exactly this state behind. For a lab machine or a kiosk `off` is the
right policy; for a laptop the owner may want hibernation. So it is a property
of what the machine is for, i.e. of the role, not of the toolkit.

`post/boot-probe.cmd` is registered on every deployed machine regardless and
sends `boot ok trigger=onstart|event` after each boot: the `event` task
(Kernel-Boot 27) fires on a resume too, so a machine that only ever reports
`trigger=event` is one that fast-starts.

## Example

`lab-apps/` is the role the lab tests with: 7-Zip and Notepad++, fast startup
off, Remote Desktop on, a skel with two files and a `skel.reg`, accounts `admin` and `alice`
(and `deploy` re-passworded, then removed at the next boot), and a post
script that probes all of it (logs on as each account with the generated
password, checks alice's new profile has the skel files and the registry
value) and beacons `role-post ok sevenzip=yes alice_logon=yes alice_skel=yes
deploy_logon=yes alice_skelreg=lab-apps`.
