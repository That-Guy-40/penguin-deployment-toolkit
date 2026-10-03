# 2026-10-02: Phase 3, post-install roles (acceptance)

What was built: `ROLE=<name>` → `http/roles/<name>/` (`role.cfg` with `APPS`,
`POST`, `UNATTEND`, `FASTSTARTUP`), checked by WinPE's preflight and by
`bin/lint`; `post/winget.cmd` (winget bootstrapped from packages this server
serves, then the apps list); `post/boot-probe.cmd` (two scheduled tasks, a
`boot` beacon after every boot); the fast-startup policy from `DEFERRED.md`;
the `deployed` verdict; a reference machine that carries its role into the
image, with the role and the apps list's SHA-256 in the image's sidecar.
All runs on this host, in lab VMs, base image 26100.1. `beacons.txt` has every
event of every VM named below; the uploads are quoted where they matter.

## 1. A role deployed **[verified]**

VM `ra`, `vm-create ra --role lab-apps` (7-Zip, Notepad++, `FASTSTARTUP=off`,
a post script). From PXE to `deployed` in 3 m 20 s:

```
20:02:41  firstlogon ok   host=WIN-V3Q1FGRE6VN build=26100.1
20:02:43  winre ok        Enabled, partition4, windows_partition=3
20:02:51  winget ok       version=v1.29.380           (8 s: provisioned + registered)
20:03:05  apps ok         installed=7zip.7zip,Notepad++.Notepad++ failed=   (14 s)
20:03:05  faststartup ok  state=off
20:03:05  boot-tasks ok   onstart_rc=0 event_rc=0
20:03:05  role-post ok    sevenzip=yes
20:03:05  deployed ok     role=lab-apps
```

`ra-winget.txt` is the uploaded transcript: `Add-AppxProvisionedPackage` +
`Add-AppxPackage` rc 0, both installers "Successfully installed", rc 0 each.

## 2. The fast-startup policy, and which boot trigger fires when **[verified]**

Same VM. `bin/vm-stop ra` (ACPI power button, which on a default Windows is a
fast-startup shutdown) returned within seconds and the next `vm-boot` was a
real boot. In the guest afterwards (`ra-boot-diag.txt`, by `boot-diag.cmd`):
`powercfg /a` says "Fast Startup: Hibernation is not available", `C:\hiberfil.sys`
"File Not Found", and the Kernel-Boot 27 events say "The boot type was 0x0".

| how the machine went down → came up | `boot ok trigger=` seen |
|---|---|
| full shutdown (`vm-stop`, fast startup off) → power on | `onstart` 8 s after power-on; `event` never |
| `shutdown /r` from inside Windows | `onstart`, then `event` 2 s later |
| QEMU killed (`vm-stop --force`) → power on | `onstart` within 20 s |
| fast-startup shutdown → power on (earlier spike, p3) | `event` only |

Why the event task misses a cold boot: Kernel-Boot 27 is written 2 s after
power-on, before the Task Scheduler service subscribes to the log. Why the
startup task misses a fast-startup power-on: the system resumes, it does not
start. Two triggers, each covering what the other cannot: kept. The earlier
spike's "neither fired after a forced power-off" (TODO) was a fast-startup
system; with the policy off, a forced power-off is followed by a plain boot.

## 3. Negative controls **[verified]**

| VM | defect | result |
|---|---|---|
| `re` | `ROLE=ghost` (no such directory) | `15-preflight fail rc=1 msg=missing: roles/ghost/role.cfg`, disk untouched; `bin/lint` had flagged the cfg |
| `rf` | role `lab-bad`: `apps.txt` with `No.Such.Package.Zzz` | `apps fail installed=7zip.7zip failed=No.Such.Package.Zzz(-1978335212)`, then `deployed ok role=lab-bad`: a missing app is a finding, not a dead machine |

`bin/lint --selftest`: 28/28 injected defects reported, four of them new (a
machine naming no such role, a role naming no such apps list, a role wanting
apps with winget never fetched, an unknown `role.cfg` key).

## 4. A reference machine with a role, captured, deployed

VM `rb`, `vm-create rb --reference --role lab-apps`.

**First attempt failed, usefully:** `prepare-capture fail: sysprep did not
succeed`. `rb1-sysprep-setuperr.log`: *"Package Microsoft.Winget.Source_… was
installed for a user, but not provisioned for all users"* (0x80073cf2). App
Installer itself passed, because `winget.cmd` provisions it with its licence;
the offender is winget's *source index*, which winget installs per user the
first time it runs. `prepare-capture.cmd` now removes that package before
sysprep (winget fetches it again on next use) and logs every per-user package
that is not provisioned, so the next such failure names itself.

**Second attempt:** `deployed ok role=lab-apps` at 20:19:51, `prepare-capture
start`, QEMU exited by itself 45 s later (sysprep's full shutdown; the final
beacon cannot be delivered after sysprep removes the NIC, as before).
`bin/capture-image rb lab-apps`: 82 s, 3.36 GB; the sidecar
(`lab-apps.json`) now carries

```
"provenance": { "stamp": "reference 07055ab4-… run 79797842 role lab-apps apps 7516a7ad…",
                "role": "lab-apps", "apps_sha256": "7516a7ad…", "reference_machine": "07055ab4-…" }
```

and `sha256sum http/roles/lab-apps/apps.txt` is `7516a7ad…`: the hash in the
image is the hash of the list that was served.

Deployed from that image (see §5 for the rows):

- `rc`: `IMAGE=lab-apps.wim`, **no role**, `POST=tmp/check-apps.cmd`
  (`check-apps.cmd` here): does the image carry the role's software, and
  nothing of the reference's `C:\pdt\role`?
- `rd`: `IMAGE=lab-apps.wim` **and** `ROLE=lab-apps`: is the role idempotent
  on a machine that already has it?

## 5. Deployed from the role image **[verified]**

Both VMs booted the captured image as new machines (`specialize`, new host
names) and their `firstlogon` beacon carried the image's stamp:
`image=reference 07055ab4-… run 79797842 role lab-apps apps 7516a7ad…`.

| VM | events after `winre ok` |
|---|---|
| `rc` (no role, probe script) | `boot-tasks ok`, `apps-present ok sevenzip=yes npp=yes winget=no stale_role=no`, `deployed ok role=`. No `winget`/`apps`/`role-post` event: `60-unattend` recreating `C:\pdt` kept the reference's role files out |
| `rd` (same role again) | `winget ok` (4 s), `apps ok installed=7zip.7zip,Notepad++.Notepad++ failed=` (`rd-winget.txt`: "Found an existing package already installed … No available upgrade found", rc -1978335189 = 0x8A15002B, counted as installed), `faststartup ok`, `role-post ok sevenzip=yes`, `deployed ok role=lab-apps` |

Also seen: on both, `boot ok trigger=onstart` arrived *before* `firstlogon`,
from the two scheduled tasks baked into the image by the reference machine,
already carrying the new machine's id (`C:\pdt\id.cmd` is rewritten at
deploy). The probe survives sysprep and needs no re-registration, but
`firstlogon.cmd` re-registers it anyway.

`winget=no` on `rc`: the probe looked for `winget.exe` under the deploy
account's `WindowsApps` seconds after logon. App Installer is provisioned in
the image; a provisioned package is registered for a user at logon, and this
one had not been yet. Not a contract of the toolkit: a machine that needs
winget says so with a role, and `winget.cmd` makes it usable then.

## 6. Bugs found and fixed on the way

- `bin/teardown --purge-vm` exited 1 without a word when run without a
  terminal (`read` failed under `set -e`); it now says to pass `--yes`.
- `bin/vm-boot --pxe` on a brand-new VM makes it redeploy itself after
  `90-reboot` (network stays first). Not a bug, a misuse: a new VM falls
  through to PXE by itself. Noted in `vm-boot --help`.
- sysprep versus winget's per-user source package (§4).
