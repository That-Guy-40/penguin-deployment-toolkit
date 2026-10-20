# 2026-10-12: a real SSH login into the collector, and RDP into a deployed Windows

Two claims that had only been checked from the inside (`ss -ltn` through
`bin/shell`): that the collector's sshd takes your key and nothing else, and
that Windows' own Remote Desktop can be switched on by a role and used from
this host. Both need a VM reachable from the host, which a user-mode-network
VM is not; `bin/vm-boot --fwd <host>:<guest>` (QEMU `hostfwd`) is the small
addition that makes it so, with no bridge and no iPXE rebuild.

## SSH **[verified]**

VM `s1`, unlisted, `bin/netboot s1 collector`, `bin/vm-boot s1 --fwd 2222:22`,
`collect ok … ssh=up`. From the host:

| | result |
|---|---|
| `ssh -p 2222 -i ~/.ssh/id_ed25519 root@127.0.0.1 'hostname; id -un; uname -r; efibootmgr \| head -2; cat /run/pdt/id'` | `pdt-collector`, `root`, `6.12.107+deb13-amd64`, `BootCurrent: 0003`, the server/id/run the collector reports with. Exit 0 |
| control: password methods only (`-o PubkeyAuthentication=no`) | `Permission denied (publickey)`, exit 255 |
| control: a freshly generated wrong key | `Permission denied (publickey)`, exit 255 |

The first attempt of the day failed before any of this: iPXE reported
"Connection reset" and the VM sat in the iPXE shell, because `bin/serve` was
not running after the host came back. `bin/lint` had said so (`UNKNOWN
server: nothing answers`), which is the row to read first when a boot goes
nowhere.

## RDP **[verified: the listener and NLA; credentials pending a client]**

Role key `RDP=on` (new): `fDenyTSConnections=0`, `UserAuthentication=1`
(NLA), the "remote desktop" firewall group, the role's `USERS` accounts added
to Remote Desktop Users; beacon `rdp ok listening=yes`. `lint`: the only
value is `on` (self-test defect: `RDP=yes`; 36 defects now).

VM `r5` (`--role lab-apps`, which now has `RDP=on`) and `r6` (no role),
booted with `--fwd 3390:3389` and `--fwd 3391:3389`:

| | result |
|---|---|
| `r5`: `rdp ok listening=yes` at first logon | yes |
| `rdp-probe.py 127.0.0.1 3390` (X.224 Connection Request offering TLS and CredSSP) | **"CredSSP (NLA) selected by the server"**: an RDP listener that insists on NLA, as configured |
| control: `rdp-probe.py 127.0.0.1 3391` (`r6`, no `RDP=on`) | connected (QEMU's hostfwd accepts regardless) but no RDP answer: the guest's port is closed |
| credentials: `xfreerdp /v:127.0.0.1:3390 /u:admin /p:<from uploads/…/users.txt> /auth-only`, and a wrong password as control | **not yet run**: this host has FreeRDP's libraries (Remmina) but no `xfreerdp` binary (`freerdp3-x11`) |
