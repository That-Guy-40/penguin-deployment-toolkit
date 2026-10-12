# 2026-10-11: vm-stop --full, DEPLOY=remove, SKELREG (and a host upgrade)

Three small features from the housekeeping list, each with a negative
control, in lab VMs on this host. The host had been upgraded to Ubuntu
26.04 / QEMU 10.2 since the last session; the first thing found was that
`ipxe-qemu` now puts its ROMs in `/usr/share/qemu`, so `bin/vm-boot` looks
in both places. `beacons.txt` has every event of the VMs below.

## 1. `vm-stop --full` **[verified]**

VM `rx`: `vm-create rx` (no role, so Windows' default fast startup), deployed.

| stop | next power-on reported |
|---|---|
| `bin/vm-stop rx` (ACPI button) | `boot ok trigger=event` only: a resume from hibernation |
| `bin/vm-stop rx --full` (types `shutdown /s /t 0 /f` through Win+R, waits for QEMU to exit) | `boot ok trigger=onstart`: a real boot |

The A/B is on the same VM, 90 s apart, and the two triggers are the probe
from `spikes/2026-10-02-phase3-roles/` §2 (each case fires a different one).
`--full` refuses to fall back to ACPI and dies if the guest does not go down
in 90 s (there is no desktop to type into on WinPE or a sign-in screen).

## 2. `SKELREG=skel.reg` **[verified]**

VM `rw`, role `lab-apps` with `skel.reg` (`HKCU\Software\PDT\SkelFrom =
"lab-apps"`, Explorer `HideFileExt=0`). `firstlogon.cmd`: `reg load` of
`C:\Users\Default\NTUSER.DAT` under `HKU\pdtskel`, the file rewritten to that
root, `reg import`, `reg unload` → `skelreg ok`. The role's probe creates
alice's profile (a process as alice with the generated password) and reads
the value back from her hive: `role-post ok … alice_skelreg=lab-apps`.
`bin/lint` refuses a `.reg` whose keys are not under `HKEY_CURRENT_USER`
(self-test defect).

## 3. `DEPLOY=remove` **[verified, in five rounds]**

Same VM. `users.txt` creates `admin|Administrators` (lint refuses
`DEPLOY=remove` without one; self-test defect). After `deployed`,
`remove-deploy.cmd` registers a one-shot SYSTEM task and the machine
restarts; the task deletes the profile (`Win32_UserProfile`) and the account:

```
23:51:43  deployed ok role=lab-apps
23:51:43  deploy-remove ok    scheduled for the next boot; restarting
23:52:13  boot ok trigger=onstart
23:52:18  deploy-removed ok   profile_gone=ok
```

The account was gone each time (`net user deploy` fails, `C:\Users\deploy`
absent). What the screen showed is the part that took three rounds:

| round | sign-in screen | cause | fix |
|---|---|---|---|
| 1 (`rw1-autologon-error.png`, `rw1-cached-deploy-tile.png`) | "The user name or password is incorrect" for `deploy`, then a picker with `deploy` twice | Winlogon still held the unattend's autologon (`AutoAdminLogon`, `DefaultPassword`); LogonUI's `LastLoggedOn*` values | `firstlogon.cmd` clears the autologon values once the one logon has happened (every role); the task deletes `LastLoggedOn*` and `DefaultUserName` |
| 2 (`rw2-sign-in.png`) | no error; picker with `deploy` once, `admin`, `alice` | guessed: LogonUI's `SessionData\<n>` | the task deletes `SessionData\*` too, and logs `reg query LogonUI /s` before and after (`rw3-remove-deploy.txt`) |
| 3 (`rw3-sign-in.png`) | same tile | `SelectedUserSID` still named deploy's SID | deleted too |
| 4 (`rw4-sign-in-same-session.png`, `rw4-remove-deploy.txt`) | same tile, although SAM, `ProfileList`, LogonUI were all clean | **the sign-in UI had enumerated the accounts at boot, seconds before the task ran, and keeps that list in memory.** Rebooting the same VM (`rw4-sign-in-after-reboot.png`): `admin`, `alice`, no `deploy`. Rounds 2 and 3 were chasing a stale screen | delete the *account* at the end of first logon, while `deploy` is still logged on (Windows allows it; the session lasts until the restart), and leave only the profile directory to the next-boot task |
| 5 (`rw5-first-sign-in.png`, `rw5-remove-deploy.txt`) | `admin`, `alice`: the first screen after the restart | | `deploy-remove ok account=deleted` → restart → `boot ok` → `deploy-removed ok profile_gone=ok` 5 s later |

What stays from the detours: clearing Winlogon's autologon values (round 1
was a real error, not a stale screen) and LogonUI's "last user" values,
which would otherwise point at an account that no longer exists.

## 4. Not done

Domain join (no directory service to test against; a Samba AD lab service
is queued in `TODO.md`). The Latitude E5570 preparation of the same day is
`spikes/2026-10-11-latitude-e5570-prep/`.
