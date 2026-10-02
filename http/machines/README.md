# machines/ - which machines may be touched, and how

One file per machine, named by its SMBIOS UUID in lowercase: `<uuid>.cfg`.
The WinPE task sequence fetches it at start (`ts/deploy.cmd`, applied by
`ts/env.cmd`). **A machine with no file here is never touched**: it boots
WinPE, reports itself (`bin/status` shows it as `shell`) and stops at a prompt.

```
# a line starting with # is a comment
MODE=deploy
IMAGE=base.wim
UNATTEND=default.xml
DRIVERS=virtio-w11
UPDATES=lcu-2026-09
DISKPART=uefi-gpt.txt
POST=install-apps.cmd
STOP_BEFORE=40-drivers
```

| key | meaning | default |
|---|---|---|
| `MODE` | `deploy` = WIPE disk 0 and install (`ts/deploy.seq`); `capture` = capture the installed Windows, wipe nothing (`ts/capture.seq`); `shell` = do nothing | `shell` |
| `IMAGE` | file under `http/images/` | `base.wim` |
| `UNATTEND` | file under `http/unattend/` | `default.xml` |
| `DRIVERS` | `http/drivers/<name>.wim` (`bin/pack-drivers`) | none |
| `UPDATES` | `http/updates/<name>.wim` (`bin/pack-updates`) | none |
| `DISKPART` | file under `http/ts/diskpart/` | `uefi-gpt.txt` |
| `POST` | a script under `http/post/` that the installed system runs, elevated, at first logon | none |
| `REFERENCE` | `yes`: a reference machine. After first logon (and `POST`) it generalizes itself with sysprep and shuts down, ready to be captured with `bin/capture-image` (a VM) or `MODE=capture` (any machine) | no |
| `STOP_BEFORE`, `STOP_AFTER` | a step name (`45-winre`) or its number (`45`): stop there and leave a prompt with the environment loaded. Continue by typing `deploy <number>` | none |

Write `KEY=VALUE` and nothing else on the line: **no spaces around `=`, no
comment after the value**. The WinPE parser takes everything after `=` as the
value. `bin/lint` rejects files that break this, misspelt keys, a `MODE`
without a sequence and a `STOP_*` that names no step.

`MODE`, `STOP_*` and `REFERENCE` can only be set here. Everything else can also come from
a per-model file, `http/models/<slug>.cfg`, which this file overrides.

`bin/vm-create <name>` writes the file for a lab VM. For a real machine, take
the UUID from `bin/status` after it has PXE-booted once, then create the file.
The `.cfg` files are host-specific and not tracked by git.
