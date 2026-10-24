# 2026-10-21/22: RDP credentials, the local-boot handoff, the disk guard, `SSH=on`

Four things, all in lab VMs on this host, base image 26100.1. `bin/status`
has every beacon of every VM named here; the files in this directory are the
raw outputs quoted below.

## 1. RDP credentials over NLA **[verified]**

The one row the 2026-10-12 spike left open (no FreeRDP client on the host).
VM `r7`, role `lab-apps` (`RDP=on`, `DEPLOY=remove`), booted with `--fwd
3390:3389`, after `deploy-removed ok`:

| `xfreerdp /v:127.0.0.1:3390 /u:<u> /p:<p> /cert:ignore /auth-only` | exit | FreeRDP's own words |
|---|---|---|
| `admin`, its generated password (`bin/logs r7 --cat users.txt`) | 0 | "Authentication only, exit status 1" (its phrase for *authenticated, stopping here*) |
| `alice` (group `Users`, put in Remote Desktop Users by the role) | 0 | same |
| `admin`, a wrong password | 134 | `ERRCONNECT_LOGON_FAILURE [0x00020014]` |
| `nobody` (no such account) | 134 | `ERRCONNECT_LOGON_FAILURE` |
| `deploy` (deleted by `DEPLOY=remove`) with its old password | 134 | `ERRCONNECT_LOGON_FAILURE` |

The Kerberos lines in every output (`krb5_parse_name … default realm`) are
FreeRDP trying Kerberos first on a host with no `krb5.conf`; NTLM inside
CredSSP is what then authenticates. Files: `r7-rdp-*.out`.

## 2. Local-boot handoff: `bin/netboot <m> local` **[verified, with two defects found on the way]**

The idea (TODO, review finding 1): a third `pdt_boot` value. The one-liner
`set pdt_boot local` makes `boot.ipxe` run
`iseq ${pdt_boot} local && echo … && exit ||`, iPXE returns to the firmware,
the firmware boots its next entry, the disk.

**First run, VM `r8`** (`vm-create r8`, `vm-boot r8 --pxe`, `netboot r8
local` during the deploy): WinPE deployed the disk (`ts-done ok`), rebooted,
and the VM **hung in the firmware**: no serial output at all after the reset,
the display never initialised, the vCPUs spinning at one address
(`RIP=7bfe35d3`, sampled twice), and a `system_reset` from the QEMU monitor
did not bring it back. `r8-serial-hang-after-wpe-reboot.log` is that log
(ends in wimboot's output: WinPE itself writes nothing to the serial port).
`vm-stop --force` + `vm-boot --pxe` got it going. The two disk-first VMs of
the same hour (`r7`, `g1`) rebooted from WinPE normally, and the earlier
Phase 3 spike had PXE-first VMs reboot normally on the previous QEMU. It
happened once more the same night, to disk-first `s3` at Setup's specialize
reboot (`s3-hang-after-specialize-reboot.txt`; the same `vm-stop --force` +
`vm-boot` recovered it and Setup carried on from where it was). Two in about
ten guest-initiated reboots; not understood; in TODO.

**Second run:** iPXE printed `boot/a3a1….ipxe... ok` and `PDT: local boot
requested - back to the firmware`, then *"Could not chain to
http://…/boot.ipxe - dropping to the iPXE shell"*. Defect 1, in the
**embedded chainloader** (`bin/build-ipxe`), not in `boot.ipxe`: iPXE's
`exit` ends the chained script with status 0 (`core/exec.c`, `exit_exec`),
so `chain … || goto failed` *succeeds*, and the next line of the embedded
script is the `:failed` label. Nothing had ever returned from `boot.ipxe`
before (wimboot and the collector's kernel replace iPXE), so the
fall-through was never seen. Fix: an `exit` after the chain line; when the
embedded image's script ends, `main()` calls `shutdown_exit()` and the EFI
application returns to the firmware (`core/main.c`, `usr/autoboot.c`).

**Third run** (rebuilt `ipxe.efi`): `PDT: local boot requested`, then
`BdsDxe: loading Boot0000 "BootManagerMenuApp"`: the **firmware's boot
menu**, with the disk listed and not tried. Defect 2: edk2's boot manager
treats a boot option that returns `EFI_SUCCESS` as *booted and returned* and
stops there (its menu); it goes on to the next entry only when the option
fails. The chainloader now ends with `exit 1`.

**Fourth run** (rebuilt again): `PDT: local boot requested`, `BdsDxe: failed
to start Boot0003 "UEFI PXEv4 …": 0000007F`, then the firmware's remaining
network entries (`>>Start PXE over IPv6..`, HTTP), each timing out, then
the disk: `BdsDxe: starting Boot0002 "UEFI QEMU HARDDISK QM00001"`, and four
minutes after the `ipxe ok` beacon, `firstlogon ok host=WIN-M34GL8KVM8A` from
the installed Windows, with **no** `ts-start` in between (the deploy had been
stopped before first logon by the hang, so this was its first). Control:
`netboot r8 winpe` (plus `STOP_BEFORE=20-disk` in its cfg to keep the
install), `vm-boot r8 --pxe` again: `ts-start ok`, `15-preflight ok`, WinPE
back. The fresh NVRAM that `vm-boot --pxe` gives a VM lists
every network flavour before the disk; a real machine's order is whatever
its setup says.

`bin/lint` now reads `pxe/ipxe.efi` for the `exit 1` line (an old-style
binary fails the row: checked by re-running the regex against the binary
with the line removed), `bin/netboot` takes `local`, and `boot/*.ipxe`
one-liners may say it.

## 3. Disk guard: `17-diskguard`, `DISK=`, `select disk @DISK@` **[verified]**

A step before `20-disk` lists the disks (WMI through `cscript`, `ts/disks.js`;
WinPE has no PowerShell, checked: `'powershell' is not recognized`), keeps
the fixed, non-USB ones of at least 32 GiB, and chooses: `DISK=<n>` from the
machine or model cfg if that disk qualifies, else the only candidate, else
fail. The choice goes to `X:\pdt\disk.txt`; `20-disk` refuses to run
without it and fills `@DISK@` into the diskpart script. The lab VMs got
`vm-create --second-disk <size>` and `--usb-disk <size>` for the controls.

| VM | disks | cfg | `17-diskguard` | then |
|---|---|---|---|---|
| `r8`, `r7`, `s1` | one 64 GiB | none | `ok msg=disk 0:QEMU HARDDISK 64GiB of 1 (the only fixed disk)` | normal deploys |
| `g1` | 64 GiB + 32 G (WMI: 31 GiB) + 8 G USB stick | none | `ok … disk 0 … of 3`: the stick "not eligible: removable media", the small disk "31 GiB, smaller than 32 GiB" (`g1-diskguard.txt`) | deployed to disk 0, `deployed ok` |
| `g2` | two 64 GiB | none | **`fail rc=1`**: "2 fixed disks (0:QEMU HARDDISK 64GiB, 1:QEMU HARDDISK 64GiB): set DISK=<n> in the machine or model cfg" (`g2-diskguard.txt`) | `20-disk` never started; `list disk` through `bin/shell`: both disks 64 GB free |
| `g2`, live in the same WinPE (`bin/shell`, `step.cmd 17-diskguard`) | | `DISK=9` | `fail`: "DISK=9 is not a disk this machine has (disks: …)" | disks untouched |
| `g2`, same | | `DISK=1` | `ok msg=disk 1:QEMU HARDDISK 64GiB of 2 (DISK=1)` | |
| `g2`, full sequence with `DISK=1`, `STOP_BEFORE=90-reboot` | | | `ok` | `20-disk ok` … `60-unattend ok`; `list disk`: disk 0 **64 GB free**, disk 1 `Gpt`, 0 B free, volumes W: S: R: on it |

Two mistakes of mine on the way, for the record: the first `g1` was meant to
be the "two fixed disks" control, but QEMU's `32G` is 31 GiB to WMI (its
`Size` comes from the geometry) and fell under the minimum, so the guard was
right and the control was not one (`disks.js` now rounds; `g2` is the
control). And `echo DISK=9>>file` in cmd redirects handle 9, not stdout: the
first live check appended `DISK= ` and the guard said "disks.js failed with
rc=2"; `(echo DISK=9)>>file` is the form.

`bin/lint`: `DISK` is a model-and-machine key and must be a number; every
`ts/diskpart/*.txt` must say `select disk @DISK@` and never `select disk <n>`
(nor contain `!` or `%`, which the cmd substitution would eat); `20-disk`
in a sequence must have `17-diskguard` before it. Self-test: 44 injected
defects (40 before), four of them these.

## 4. `SSH=on` **[verified; PowerShell remoting: see the end]**

Role keys `SSH=on` and `SSHKEYS=<authorized_keys>`, built as `DEFERRED.md`
designed them. Source chosen: the Win32-OpenSSH MSI (10.4.0.0p1, released
2026-10-20), fetched once and pinned by `bin/fetch-tools openssh`, served
from `post/openssh/`, installed at first logon by `post/ssh.ps1` with
`msiexec /qn`; the same `fetch-tools` call writes the lab role's
`authorized_keys` from `~/.ssh/id_*.pub` (the key the collector takes).
`post/sshd_config`: `PasswordAuthentication no`, `KbdInteractiveAuthentication
no`, the `Match Group administrators` block for
`administrators_authorized_keys` (ACL: Administrators and SYSTEM only, by
SID), a `powershell` subsystem line when PowerShell 7 is present.

VM `s1`, role `lab-apps` (now `SSH=on`, `Microsoft.PowerShell` added to its
apps), `--fwd 2223:22`:

```
apps ok  installed=7zip.7zip,Notepad++.Notepad++,Microsoft.PowerShell
rdp  ok  listening=yes
ssh  ok  port=22 shell=powershell keys=1 listening=yes          (9 s)
```

`ssh.txt` (uploaded): `msiexec exit code 0`, four host keys generated (ECDSA,
ED25519, MLDSA44-ED25519, RSA) with fingerprints, `sshd Running`.

| from the host, after `deploy-removed ok` | result |
|---|---|
| `ssh -p 2223 -i ~/.ssh/id_ed25519 admin@127.0.0.1 'hostname; whoami; $PSVersionTable.PSVersion'` | `WIN-LJ01NHCU5B0`, `win-lj01nhcu5b0\admin`, `5.1.26100.1` (`s1-ssh-admin.out`) |
| `ssh-keyscan -p 2223 -t ed25519 127.0.0.1 \| ssh-keygen -lf -` | `SHA256:QOES1Lyw…`, the ED25519 line of `ssh.txt` (`s1-keyscan.out`) |
| control: password methods only (`-o PubkeyAuthentication=no`), batch | `Permission denied (publickey)`, exit 255 |
| control: same, interactive allowed | the same, **no password prompt** (`s1-ssh-nokey-interactive.out`) |
| control: `alice` (group `Users`) with the admin key | `Permission denied (publickey)` |
| control: `deploy` (deleted) with the key | `Permission denied (publickey)` |

**PowerShell 7 was gone.** `shell=powershell`, not `pwsh`: winget had said
"Successfully installed" for `Microsoft.PowerShell`, yet on the machine
afterwards there was no `C:\Program Files\PowerShell`, no Appx package for
any user and no uninstall entry (`s1-pwsh-*.out`). winget, run as the
`deploy` account with no `--scope`, had installed it *per user*, into the
profile `DEPLOY=remove` deletes at the next boot. Fix in `post/winget.cmd`:
`--scope machine` first; only when winget answers 0x8A150011 (no
machine-wide installer) does it install per user, and the transcript says
so.

**Re-run as `s2`:** `--scope machine` rc 0 for all three, and still
`shell=powershell`: the package is now `Microsoft.PowerShell_7.6.7.0_x64__8wekyb3d8bbwe`
for all users (`s2-pwsh-where.out`), an MSIX, which has no
`C:\Program Files\PowerShell\7\pwsh.exe` and which Microsoft says cannot be
sshd's subsystem (a packaged app) **[read]**. winget's default installer for
this package is the MSIX. (winget cannot be driven over SSH to try things:
`ApplicationFailedException`, a packaged app in a non-interactive session;
`s2-winget-msi.out`.) So `apps.txt` lines may now carry winget options after
the id (`winget.cmd` passes them through, `lint` checks the form), and the
lab role says `Microsoft.PowerShell --installer-type wix`.

**`s3`:** `--installer-type msi` → "No applicable installer found", rc
-1978335216: winget's manifest calls the MSI `wix`. The same run showed my
per-user fallback was keyed to the wrong code (0x8A150011 is the hash
mismatch; no-applicable-installer is 0x8A150010 = -1978335216): fixed, from
the evidence. `s3` also hung at its specialize reboot (§2).

**`s4`** (`--installer-type wix`): `apps ok installed=…,Microsoft.PowerShell`,
**`ssh ok port=22 shell=pwsh keys=1 listening=yes`**. From the host:

| | result |
|---|---|
| `ssh -p 2223 -i … admin@127.0.0.1 'hostname; whoami; $PSVersionTable.PSVersion'` | `WIN-SVRNT4JC81C`, `win-svrnt4jc81c\admin`, **`7.6.7`** (pwsh is the login shell); `sshd_config` has `Subsystem powershell c:/progra~1/powershell/7/pwsh.exe -sshs -nologo` (`s4-ssh-admin.out`) |
| `pwsh -c 'Invoke-Command -HostName 127.0.0.1 -Port 2223 -UserName admin -KeyFilePath … -ScriptBlock { … }'` | returns `host=WIN-SVRNT4JC81C user=admin ps=7.6.7 pid=4228`, `PSComputerName 127.0.0.1`: **PowerShell remoting over SSH works** (`s4-remoting.out`) |
| controls: no key; `alice` with the key | `Permission denied (publickey)` both (`s4-ssh-*.out`) |
| `ssh-keyscan` fingerprint vs the uploaded `ssh.txt` | `SHA256:WwX4hkq8…` on both (`s4-keyscan.out`) |

**Not done here:** the reference-image check (two machines from one image
must show different host keys: `prepare-capture.cmd` deletes them before
sysprep and `ssh.ps1` regenerates, but no image was captured in this
session), and per-user keys for `Users` accounts.
