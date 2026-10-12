# models/ - defaults per hardware model

One file per model, `<slug>.cfg`, where the slug is the machine's SMBIOS
product name lowercased with every run of other characters replaced by one
dash (`ts/slug.js`):

| product name | file |
|---|---|
| `Latitude 5440` | `latitude-5440.cfg` |
| `Standard PC (Q35 + ICH9, 2009)` | `standard-pc-q35-ich9-2009.cfg` |
| `lab-vm` (the lab VMs of `bin/vm-create`) | `lab-vm.cfg` |

`bin/status` shows each machine's product name; `bin/status <id>` shows the
slug it asked for (`model=` on its `ts-start` event).

```
# every Latitude E5570 gets this driver pack
DRIVERS=latitude-e5570
```

The pack comes from the vendor: `bin/fetch-drivers <url> <name>` downloads
a Dell/Lenovo/HP driver CAB or zip, pins it by SHA-256 (printed on the first
run, `--sha256` on the next), unpacks it and makes `http/drivers/<name>.wim`
with a sidecar that records where it came from. Dell lists its packs per
model at https://www.dell.com/support/kbdoc/en-us/000109893.

Allowed keys: `IMAGE`, `UNATTEND`, `DISKPART`, `DRIVERS`, `UPDATES`, `POST` (see
`../machines/README.md`). A machine's own `machines/<uuid>.cfg` overrides them.

**A model file cannot set `MODE`** (or `STOP_*`, `REFERENCE`): `ts/env.cmd` ignores those
keys here and `bin/lint` rejects them. Whether a disk is wiped is decided per
machine, never per model, so listing a model can never get a machine installed
that nobody listed.

The `.cfg` files are site-specific and not tracked by git.
