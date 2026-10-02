# 2026-10-02: bridged lab, rootless, in a network namespace

Question: `vm-create --net bridge:…` and `pxe-lan --bridge` were written but
never run, because a host bridge, dnsmasq on port 67 and QEMU's bridge helper
all need root, and no sudo was available. Can they be tested anyway?

Answer: yes, inside an unprivileged user + network + mount namespace
(`bin/lab-netns`, added for this). Inside it the invoking user is "root" over a
network that exists only there. The host's network was not touched (no `br0`
and no `/etc/qemu` on the host before, during or after).

## What ran

```
config.sh: HTTP_HOST="10.42.0.1"        bin/build-ipxe
bin/lab-netns up                        # br0 = 10.42.0.1/24, /etc/qemu/bridge.conf: allow br0
bin/lab-netns run bin/serve
bin/lab-netns run bin/pxe-lan --bridge br0 10.42.0.100,10.42.0.199 start
bin/vm-create br01 --net bridge:br0 --drivers virtio-w11
bin/lab-netns run bin/vm-boot br01
bin/await br01 firstlogon 900
```

## Result **[verified]**

- QEMU's bridge helper (not setuid) created `tap0` and enslaved it to `br0`.
- dnsmasq, authoritative on the bridge, leased `10.42.0.134` and offered
  `bootfile-name ipxe.efi`; `dnsmasq-tftp: sent …/pxe/ipxe.efi to 10.42.0.134`
  (`dnsmasq-excerpt.txt`). This is the DHCP + TFTP path real hardware takes;
  the user-mode lab never exercised it (QEMU's built-in TFTP stood in).
- The embedded iPXE script chained to `http://10.42.0.1:8090/boot.ipxe?uuid=…`,
  and every later request arrives from the VM's real address
  (`access-excerpt.txt`), not from 127.0.0.1 as under user-mode networking.
- Full deploy with the driver pack: `firstlogon ok` 121.6 s after the iPXE
  request (`timelines.txt`); the 3.5 GB image downloaded in 5.4 s over the tap
  (12 s through QEMU's user-mode stack). Desktop as `deploy` in
  `br01-desktop.png`. No internet inside the namespace, as designed.

Negative control: with dnsmasq stopped, an identical VM (br02) sat at the
firmware's "Start PXE over IPv4" (`br02-no-dnsmasq.png`); `bin/await` timed out
with "no event from this machine at all" and the access log has no request
from it. With dnsmasq started again the same VM reached `shell ok`.

## What had to change to make it work (all found by running it)

- `bin/pxe-lan`: no `sudo` when already root; its own `dhcp-leasefile` under
  `run/` (it was trying to share `/var/lib/misc/dnsmasq.leases` with the system
  dnsmasq, which would also have been wrong on a real host); in a user
  namespace dnsmasq is run with `--no-daemon` and backgrounded, because it
  cannot drop privileges there (no other accounts; `setgroups` denied).
- `bin/pxe-lan --bridge`: every UEFI client is handed `ipxe.efi`, including
  clients that already are iPXE (QEMU's NIC ROM). Our embedded script never
  asks DHCP for a file name, so there is no loop, and every machine arrives at
  `boot.ipxe` with its identity in the URL.
- `bin/serve`: `user root;` in the generated nginx.conf when inside a user
  namespace (nginx otherwise tries to give its temp directories to `nobody`).
- `bin/lab-netns`: `/etc/qemu` does not exist on this host, so the helper's ACL
  is provided by an overlay on `/etc` inside the mount namespace only.

## Not covered

Proxy-DHCP next to another DHCP server, the setuid bit and `/etc/qemu/bridge.conf`
on a real host, a firewall on the bridge, physical NICs and switches. Those are
Phase 5. The namespace needs unprivileged user namespaces:
`kernel.apparmor_restrict_unprivileged_userns` was 0 on this host. Stock Ubuntu
24.04 restricts them **[read, not tested here]**, in which case `lab-netns up`
fails at `unshare` and the sysctl has to be changed by an administrator.
