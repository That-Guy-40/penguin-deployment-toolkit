# tools-src/collector/ — what goes into the collector image

Built by `bin/build-collector` (mmdebstrap, rootless) into
`http/collector/{vmlinuz,initrd.img}`. `usr/` and `etc/` are copied into
the image as they are; `customize.sh` and `pack.sh` are the mmdebstrap
hooks.

- `usr/local/bin/pdt-collect`: runs at boot once the network is up (systemd
  unit in `etc/`): identity, NICs, firmware attributes, AMT, boot entries,
  disks → `inventory.json` uploaded, `collect ok` beacon, then the shell loop.
- `usr/local/bin/pdt-shell-loop`: the remote shell (`bin/shell`), same
  protocol as WinPE's `ts/shell-loop.cmd`.
- `usr/local/bin/pdt-pxe-next [--reboot]`: `efibootmgr -n` on the firmware's
  network boot entry.
- `customize-inside.sh`: the in-chroot hook (inline, see the script); `tar2initrd.py`: tar → kernel + zstd cpio, no extraction on the host.
- `mei-amt-check.c`: Intel/Google, dual BSD/GPLv2, vendored from
  https://github.com/mjg59/mei-amt-check (master, 2026-10-12, SHA-256
  3e25e9f62580607a0309ecc1775ac8e6172bf37316571ae184e0fe8321398fb7). Not
  packaged by Debian; built statically on the host.
