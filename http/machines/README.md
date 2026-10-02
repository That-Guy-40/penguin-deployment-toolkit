# machines/ - which machines may be deployed, and how

One file per machine, named by its SMBIOS UUID in lowercase:
`<uuid>.cfg`. The WinPE task sequence (`ts/deploy.cmd`) fetches it at start.
**A machine with no file here is never touched**: it boots WinPE, reports
itself (`bin/status` shows it as `shell`) and stops at a prompt.

```
# comment
MODE=deploy          # deploy = wipe disk 0 and install | shell = do nothing (default)
IMAGE=base.wim       # file under http/images/
UNATTEND=default.xml # file under http/unattend/
DRIVERS=virtio-w11   # optional: http/drivers/<name>.wim
DISKPART=uefi-gpt.txt
```

`bin/vm-create <name>` writes the file for a lab VM. For a real machine, take
the UUID from `bin/status` after it has PXE-booted once, then create the file.
The `.cfg` files are host-specific and not tracked by git.
