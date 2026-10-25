# Remote sites: running this toolkit as a service, over Tailscale or a VPN

> **Status (2026-10-25):** a design, nothing built. It answers two questions
> asked after the demo of 2026-10-24: can this toolkit be offered the way a
> SaaS product is, reached over Tailscale or a conventional VPN, and could it
> use multicast or BITS. The short answers are *yes, as a managed service with
> a small Linux box on every site*, *no, as a cloud service with nothing on
> site*, and *no* to both transports, for one shared reason given in §8 and
> §9. Every claim is tagged **[verified]** (run in this repo's lab, with the
> spike named), **[verified: LAB_CREATE_V2]** (run in the sibling repository
> `mklab`, whose lab the collector already borrows from), **[read]** (from
> documentation or source, not executed) or **[unknown]** (nobody has checked).
> Nothing in this file was run on 2026-10-25. `PLAN.md` is the design of the
> toolkit itself; this file is about putting that design on more than one LAN.

## 1. The question, and the shape of the answer

"SaaS" can mean two things here, and they get different answers:

| meaning | answer |
|---|---|
| **a managed service:** the customer has a LAN and machines, we run the deployment server for them and never visit | yes, with one Linux box per site that we reach over a tailnet. Zero code (§4). |
| **a cloud service:** nothing of ours on the customer's premises, machines PXE-boot and talk to our server over the internet or a VPN | no. The first two hops of a network boot cannot leave the LAN (§2), and the bytes should not (§2). |
| **several sites, one view:** the first meaning, plus one status view and one place to edit the control plane for every site | yes, with a moderate amount of code (§5). |

The toolkit is already shaped for the first and third because of three
decisions made for other reasons (§3). The work is mostly deciding where each
file lives.

## 2. What cannot leave the LAN

Three facts fix the shape of any answer.

**The firmware hop is broadcast.** A machine's firmware PXE client does DHCP
on its own segment and fetches the boot file over TFTP from an address the
DHCP answer names **[read: UEFI spec; this is what `bin/pxe-lan` answers]**.
Firmware speaks neither Tailscale nor WireGuard; neither does iPXE
**[read: iPXE has no VPN client]**. So something on the customer's segment must
answer the PXE part of DHCP and serve `ipxe.efi` over TFTP, exactly as
`bin/pxe-lan` does today. The USB-stick variant (an `ipxe.efi` booted from
removable media, which then only needs an address from DHCP and chains to its
embedded URL) removes the TFTP hop but not the next fact.

**The bytes are large and read every time.** Nothing is cached on a target;
each boot and each deploy pulls the lot:

| file | size | read by | measured |
|---|---|---|---|
| `winpe/boot.wim` + boot files | about 500 MB | every boot into WinPE | `docs/HOW_IT_WORKS.md` §3 **[verified]** |
| `images/base.wim` | 3.5 GB | every deploy | 12 s in the lab VM, host to guest **[verified: `README.md` Verification]** |
| an update pack | up to 5 GB | every deploy that names it | **[verified: `spikes/2026-10-02-phase2-acceptance/`]** |
| a 30-seat lab, one deploy each | about 100 GB | one server NIC | arithmetic; `docs/REVIEW-2026-10-12.md` item 14 |

Physical-LAN throughput is open question 4 of `PLAN.md` §5, still unmeasured
**[unknown]**. Over a VPN it is not a question: a consumer uplink moves a
3.5 GB image in tens of minutes per machine, and it moves it again for the
next machine. The image has to sit one switch-hop from the targets.

**The trust model is LAN-shaped.** Whoever writes to `http/` runs code as
SYSTEM on every booting machine (`docs/REMOTE_VISIBILITY.md`, and the comment
at the top of `ts/shell-loop.cmd`). `GET /beacon` and `PUT /uploads/` take no
credentials and `client_max_body_size` is `0` (`bin/serve`). `machines/<uuid>.cfg`
gates a wipe on an SMBIOS UUID, which is an identifier, not a secret. All of
this is right for a lab LAN or the inside of a tailnet, and none of it may
face the internet as it stands. A public origin would need, at least, client
certificates in iPXE (`CERT=`/`PRIVKEY=` at build time **[read: iPXE
documentation]**) and in `curl.exe`, per-site keys, and authentication on the
upload and beacon endpoints: a different toolkit, with a different §6 of
`PLAN.md`.

So the smallest footprint per site is one Linux box: a NUC, a Raspberry Pi 5,
or a VM on whatever hypervisor the customer already runs. It runs `bin/serve`
and `bin/pxe-lan`, holds the images, and is the only thing of ours that joins
a tunnel.

## 3. Why the split is cheap: three properties the code already has

1. **A target talks to whoever booted it.** `http/boot.ipxe` is static and every
   URL in it is relative to its own, so it names no host **[verified]**. The
   identity hand-off (`GET /ts/id.cmd` in `bin/serve`) answers with
   `SRV=http://<the Host header the target itself used>`, so WinPE's `SRV` is
   the address the firmware chained to, with no detection **[verified: Phase 1]**.
   The collector gets the same from `${cwduri}` on its kernel command line
   (`docs/COLLECTOR.md`). A machine booted from a site box therefore reports
   to, uploads to and polls that site box, with no change anywhere.
2. **Everything a target does is HTTP to that one address.** Static `GET`s,
   `GET /beacon`, `PUT /uploads/`, and `GET cmd/<id>/<run>/<n>.cmd` for the
   remote shell. One endpoint to mirror or split, and `bin/serve` already
   writes the nginx configuration from a template, so a second mode of it is
   a second template.
3. **The control plane is files and the database is logs.** `machines/`,
   `models/`, `roles/`, `ts/`, `post/`, `unattend/`, `boot/` are text;
   `run/beacons.log`, `run/access.log` and `http/uploads/` are what `status`,
   `await` and `logs` read. Files sync. `config.sh` already lets `STATE_DIR`
   be pointed anywhere (`bin/lib.sh`), so a central copy of a site's logs is
   readable by the unchanged tools.

What is **not** free: `HTTP_HOST` is baked into `ipxe.efi` (`bin/build-ipxe`),
and `${next-server}` was verified not to work behind proxy-DHCP
(`DEFERRED.md`). Every site box has its own LAN address, so every site gets
its own `ipxe.efi`. A build is about a minute and `lint` checks the binary
against `config.sh`, so this is a per-site step, not a problem. A site with
working internal DNS can instead bake a name and keep one binary for several
sites **[read: iPXE resolves names; not tried here]**.

## 4. Tier A: a site appliance you reach over a tailnet (zero code)

The appliance runs the toolkit exactly as `README.md` describes it, on the
customer's LAN, and joins your tailnet. You never visit.

**Per site, once:**

| step | what | why |
|---|---|---|
| 1 | install the toolkit and its packages on the box; `config.sh` with `HTTP_HOST` = the box's LAN address, `LAN_IF` set | `README.md` Quick start, minus the VM lines |
| 2 | `bin/build-ipxe`, `bin/serve`, `bin/pxe-lan start` | the address is baked into the binary (§3) |
| 3 | sign `ipxe.efi` with your key (`SB_KEY`/`SB_CERT`) and enrol the certificate in each machine's firmware | Secure Boot; the one manual, per-vendor step (`PLAN.md` §5 item 3) **[unknown on real firmware]** |
| 4 | `tailscale up` with SSH enabled, or `sshd` keyed to your operator account and the tailnet ACL allowing only you | the way in |
| 5 | optionally advertise the site's subnet | the `RDP=on` and `SSH=on` role keys then reach deployed machines through the same tunnel |

**Day to day,** from anywhere on the tailnet: `ssh <site> bin/status`,
`bin/shell`, `bin/logs`, `bin/enroll`, `bin/netboot`, all on the appliance
where the files are. Publishing a new image is `rsync` of `http/images/` to
the appliance, followed by `bin/lint` **there**, since lint checks the sidecar
against the bytes it can read. The collector's `sshd` and the deployed
machines' RDP and SSH are reached through the subnet route.

**Why Tailscale rather than a conventional VPN here** **[read: Tailscale
documentation]:**

| property | Tailscale | WireGuard or IPsec site-to-site |
|---|---|---|
| the appliance dials out; nothing to open on the customer's router | yes | needs a reachable endpoint on one side, usually ours |
| per-site access rules | ACLs in one policy file | per-tunnel routing and firewall rules by hand |
| stable names | MagicDNS | your own DNS |
| who runs the coordinator | Tailscale, or Headscale on your own host | you |
| what else is on the tunnel | only the appliance and you; targets cannot join (§2) | the same |

Either works; the first row is what makes the managed-service model cheap for
a customer with a consumer router. The last row is the same for both: WinPE,
iPXE and the firmware are never on the tunnel, which is also why a tunnel
changes nothing about the toolkit.

**What a customer sees:** nothing. What you see: one terminal per site. This
is a managed service in every way that matters, and it needs no code.

## 5. Tier B: one origin, site mirrors, one status view (moderate code)

Tier A's pain is proportional to the number of sites: an edit to a step or a
role is an `rsync` per site, and `status` is a terminal per site. Tier B moves
the text control plane to one origin and keeps the bytes on the sites.

**Which path lives where.** The split follows §2: small and edited often goes
to the origin, large and published rarely stays on the site.

| path | served by the appliance from | why |
|---|---|---|
| `boot.ipxe`, `boot/`, `ts/`, `machines/`, `models/`, `roles/`, `post/`, `unattend/`, `cmd/` | a proxy to the origin over the tunnel, no cache or a short one | small text, the control plane; an edit at the origin takes effect at the next boot or the next `deploy NN`, as today |
| `ts/id.cmd` | the appliance itself (an nginx `return`, as today) | its `Host` header must be the appliance's (§3) |
| `winpe/`, `images/`, `drivers/`, `updates/`, `tools/`, `collector/` | a local mirror | the bytes (§2) |
| `/beacon` | logged locally **and** mirrored to the origin | the site keeps its timeline when the tunnel is down; the origin's `status` sees every site |
| `/uploads/` | proxied to the origin, or stored locally and pulled | logs and captured images; `users.txt` with generated passwords is in here, so per-site storage and ownership matter |

**The changes:**

| change | where | size |
|---|---|---|
| an `UPSTREAM=` mode: proxy locations for the text paths, local root for the mirrored trees, beacon logged then mirrored | `bin/serve` | moderate |
| one-way image sync that re-verifies every `.json` sidecar's `sha256` against the bytes **after** transfer, and refuses to publish a mismatch | new `bin/sync-site` | small |
| a `site=` field on every beacon, a site column in `status` | `ts/beacon.cmd`, `bin/status` | small |
| one tree per site at the origin (`sites/<name>/machines/` and so on), or a site layer inside `machines/` | `http/` layout, `bin/lint`, `bin/enroll` | small |
| a `boot/default.ipxe` the appliance serves **itself** when the origin is unreachable, saying so and stopping | `bin/serve`, `http/boot.ipxe` | small, and the most important row (below) |

**Three rules from the sibling repository's bare-metal lab**, each paid for
there (`examples/metal-as-a-service/DEFERRED.md` in LAB_CREATE_V2, sixteen
defects a green suite did not see **[verified: LAB_CREATE_V2]**):

- **A record must not outlive its subject.** A mirrored `base.wim` is a cached
  fact about a file at the origin. The sidecar is already the identity
  (`25-download` refuses a mismatch on the machine since 2026-10-24
  **[verified: `spikes/2026-10-24-sha256-and-dism/`]**), so the mirror must be
  checked the same way after every sync, and `lint` must run where the bytes
  are. Never trust the transfer tool's exit status alone.
- **The default must be a dead end that explains itself.** When the appliance
  cannot reach the origin it must not serve a plausible fallback; a machine
  quietly booting the wrong thing looks exactly like a successful deploy. The
  existing shape helps: a machine with no cfg gets `MODE=shell` and is left
  alone, and `boot/default.ipxe` is already the hook `bin/netboot` writes.
- **Grade how it falls, not whether it stands.** The lab's chaos matrix
  (`chaos-run.sh`, one fault per layer, graded ABSORBED / DEGRADED / HALTED
  against the criticals STRANDED and LIED) is the instrument for Tier B's new
  layers: origin unreachable, tunnel dropped mid-deploy, mirror stale against a
  re-published image, beacon mirror down. Each needs an injection point and a
  no-fault control row before Tier B is called done.

**Multi-tenancy, stated plainly.** In Tier B the operator is SYSTEM on every
customer's machines, from one place. One tree per site, one appliance per site
and per-site ownership of `uploads/` keep the blast radius of a mistake to one
customer; nothing keeps it smaller than that. This is the same trust statement
the toolkit makes today, with more machines behind it.

## 6. Proving it without a customer

The bridged lab already runs a whole site in a private network namespace
without root (`bin/lab-netns`, **[verified: `spikes/2026-10-02-bridged-lab-netns/`]**).
Two of them are two sites. The spike, `spikes/<date>-two-sites/`:

1. Two namespaces, `site-a` and `site-b`, each with its own bridge, its own
   `bin/serve` on its own `config.sh` and `STATE_DIR`, and `bin/pxe-lan --bridge`.
2. A WireGuard tunnel from each namespace to the root namespace, which plays
   the origin. `wg` needs no coordination server, so the lab needs no account
   with anyone **[read: WireGuard in a netns is ordinary; not tried here]**.
   Tailscale itself is then a deployment detail, exercised once on a real box.
3. Tier A first: `rsync` an image into each site over the tunnel, `lint` in
   each, deploy one VM per site, `status` in each namespace shows its own
   machine and not the other's.
4. Tier B: the origin serves the text paths, each appliance proxies them and
   mirrors the images; one `status` at the origin shows both machines with a
   site column.
5. Controls: take the tunnel down during `25-download` at one site (the other
   site's deploy must finish; the first must fail by name, not hang); publish
   a changed `base.wim` at the origin without syncing (the stale site's lint
   must fail, and a deploy there must refuse at `25-download`); make the
   origin unreachable before a boot (the machine must land at the dead-end
   default, reported in the site's beacon log).

The whole thing needs the host this repo already runs on, and `wireguard-tools`.

## 7. What LAB_CREATE_V2 contributes

The sibling repository has already built several of the pieces, and the
collector already borrows its chroot-to-initrd recipe (`docs/COLLECTOR.md`).

| piece | what it gives this design | status there |
|---|---|---|
| `examples/lab-ca/` | a root CA with `issue-server-cert.sh` (TLS leaves with IP SANs) and `issue-codesign-cert.sh` (for iPXE `imgverify`); public anchor in git, key out of it | **[verified: LAB_CREATE_V2]** |
| `examples/libvirt-ipxe-http-pxe/https/` | the iPXE build recipe for HTTPS with a private CA baked in (`TRUST=`), including the two build-time traps (BIOS builds drop HTTPS; only baked CAs are trusted), with positive and negative controls | **[verified: LAB_CREATE_V2, in QEMU]** |
| `examples/metal-as-a-service/` | a fleet registry, per-node iPXE scripts chained `hostname → mac → a dead-end default`, and the chaos harness of §5 | **[verified: LAB_CREATE_V2, headless; live runs author-run]** |
| `tools/control-pane` | a fleet progress view (TUI and web) that the review's "read-only status page" (`docs/REVIEW-2026-10-12.md` item 8) could grow into, one row per machine across sites | **[verified: LAB_CREATE_V2]** |
| `examples/podman-netboot-server.toml` | rootless nginx in a container as a packaging shape for the appliance (a quadlet unit, so it survives reboots: `PLAN.md` §3.1) | **[verified: LAB_CREATE_V2]** |
| `examples/pxe-boot-mechanics/` | Secure Boot enforced in OVMF with a signed iPXE, and `curl`-based probes of what a PXE client actually fetches | **[verified: LAB_CREATE_V2]** |

TLS between appliance and origin is optional inside a tunnel and listed for
when the tunnel is not trusted or a public origin is ever reconsidered (§2).

## 8. Multicast: no

`docs/REVIEW-2026-10-12.md` lists multicast under *what not to add* for the
sake of a control plane readable with `cat`. The transport facts agree.

- **The receiver is missing.** Stock `boot.wim` has no multicast client
  (inventory of build 26100, `PLAN.md` §2.5 **[verified]**). WDS and MDT
  multicast rely on WDS's own multicast provider on a Windows server and a
  client that the ADK puts into their WinPE **[read]**. `curl.exe` cannot join
  a group. A receiver would have to be built and served the way
  `tools/pdt-sha256.exe` is (plain C, mingw-w64, pinned, injected), or
  udpcast's Windows build used, whose maintenance state is **[unknown]**. The
  server would need a session: wait for N receivers or a timeout, cope with a
  slow one, re-send what was lost. All of that to replace one `curl -o`.
- **It does not cross a tunnel.** Tailscale and WireGuard carry unicast
  **[read]**, so multicast is irrelevant to the question this file answers.
  On the LAN it also needs IGMP snooping to behave on the customer's switch.
- **It only pays at a scale this repo has not measured.** It helps when
  dozens of machines start inside one window on one segment. Open question 4
  of `PLAN.md` §5 is still open **[unknown]**; the arithmetic in §2 says a
  30-seat lab saturates a 1 GbE appliance port for about a quarter of an hour,
  which a staggered gate (the watcher that the local-boot handoff already
  wants, `docs/REVIEW-2026-10-12.md` item 14) or a 10 GbE port on the
  appliance removes without a new transport.

**Pick up when** a measured physical lab shows the appliance NIC, not the
targets' disks, is the bottleneck, and staggering is not acceptable to the
customer. Not before the measurement.

## 9. BITS, and the peer-caching family: no

- **BITS is a Windows service of the installed OS.** `bitsadmin` is absent from
  `boot.wim` 26100 (`PLAN.md` §2.5 **[verified]**) and so is the service it
  drives **[read]**. Nothing in the task sequence, where every large transfer
  happens, can use it.
- **After first logon it buys nothing.** `firstlogon.cmd` fetches role files,
  winget's packages and the OpenSSH installer from the appliance a switch-hop
  away. `Start-BitsTransfer` would give resume and throttling for transfers
  that need neither.
- **What people want from BITS belongs on the appliance.** Resume and a
  bandwidth cap over the WAN are properties of the pull from the origin to the
  site, which is Linux: `rsync --partial --bwlimit`, or `curl -C -`. §5's
  `bin/sync-site` is where they go.
- **The neighbours need Windows on both ends.** BranchCache wants an
  Enterprise or Education client and a BranchCache-enabled IIS or SMB server;
  Delivery Optimization serves Windows Update, Store and Intune content;
  Configuration Manager's Peer Cache is its own client in its own WinPE
  **[read]**. None is reachable from a Linux-hosted toolkit without
  reimplementing the client, and none runs in a stock WinPE.

## 10. Recommended order

1. **Tier A, now, in the lab:** steps 1 to 3 of §6 on this host. It is
   configuration and one `rsync`; the deliverable is the spike directory and a
   `docs/SITE_APPLIANCE.md` runbook written from it (the Phase 6 install guide
   with one more section, not a second guide).
2. **Tier A, on a real box,** once Phase 5 has deployed the Latitude: the first
   physical site is this host's own LAN, with the appliance a second machine
   and the operator on the tailnet.
3. **Tier B after the second site,** when hand-syncing is the main pain. That
   is the criterion `DEFERRED.md` already applies to the small dispatcher, and
   the two would likely be built together: a dispatcher that renders per-machine
   files is also the thing that knows which site a machine is at.
4. **Not multicast, not BITS.** Re-read §8 when there is a measurement.

What goes where: item 1 is a `TODO.md` entry after the Samba AD service; items
3 and 4 are `DEFERRED.md` entries pointing here.
