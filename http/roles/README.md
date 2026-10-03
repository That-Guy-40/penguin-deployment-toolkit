# http/roles/ — what a machine becomes after Windows is on it

A **role** is a directory here, `roles/<name>/`, and a machine (or a model)
takes one with `ROLE=<name>` in its cfg. Everything in it is served as static
files; `role.cfg` names the rest:

| key | file | meaning |
|---|---|---|
| `APPS` | one winget package id per line, `#` comments | installed at first logon with `winget install --id <id> -e --silent` (`post/winget.cmd`). winget itself is bootstrapped first from `post/winget/`, the release pinned by `bin/fetch-tools winget`: an image built from install media has no App Installer at first logon |
| `POST` | a batch file | runs at first logon after the apps, elevated, from `C:\pdt\role\`; `..\id.cmd` and `..\beacon.cmd` are next to it |
| `UNATTEND` | an unattend.xml | replaces the cfg's `UNATTEND=` from `http/unattend/` for this role |
| `USERS` | `name\|group\|policy` per line | local accounts, created (or, if they exist, re-passworded) at first logon by `post/users.ps1`. Group `Administrators` or `Users`; policy `random` (a 32-character password from the OS generator) or `plain:<password>`. See "Accounts and passwords" |
| `SKEL` | a manifest: one relative path per line | the files, kept under `skel/` in the role directory, are copied into `C:\Users\Default`: Windows' `/etc/skel`, copied into every profile created from then on. `lint` insists the manifest and the directory agree |
| `FILES` | file names, space-separated | companions of the post script, fetched next to it |
| `FASTSTARTUP` | `off` (or absent) | `off`: `powercfg /h off` at first logon, so every shutdown is a real shutdown and every power-on a real boot. Absent: Windows' default (fast startup on). See below |

Keys are checked by `bin/lint` (unknown key, missing file, `APPS` without the
winget packages fetched). WinPE's preflight checks the same before touching
the disk; `60-unattend` puts `role.cfg` and the files it names in `C:\pdt\role\`
and `firstlogon.cmd` works through them in this order:

```
firstlogon ok  →  winre ok  →  skel ok files=N  →  users ok created=… set=… failed=
  →  users-upload ok  →  winget ok version=…  →  apps ok installed=… failed=
  →  faststartup ok state=off  →  boot-tasks ok  →  role-post …  →  (POST script)
  →  deployed ok role=<name>   →  (REFERENCE=yes: prepare-capture)
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
directory is served to every machine that asks. Not done: domain join,
removing `deploy` altogether (it has to exist until first logon ends), and
templating the Default profile's registry hive (`NTUSER.DAT`): `SKEL` copies
files only.

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
off, a skel with two files, `deploy` re-passworded and an `alice` account, and
a post script that probes all of it (logs on as each account with the
generated password, checks alice's new profile has the skel files) and
beacons `role-post ok sevenzip=yes alice_logon=yes alice_skel=yes deploy_logon=yes`.
