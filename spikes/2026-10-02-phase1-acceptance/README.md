# 2026-10-02: Phase 1 acceptance (the `bin/` + `http/` layout, end to end)

Not a spike but the acceptance run for Phase 1 of `PLAN.md`, kept here with the
other evidence. Everything ran on this host through the scripts in `bin/`, as
an unprivileged user, against lab VMs on QEMU user-mode networking. Windows 11
Pro 24H2 build 26100.1 (`win11.iso` → `http/images/base.wim`).

## What ran

| VM | set-up | expected | observed |
|---|---|---|---|
| lab06 | `vm-create lab06 --drivers virtio-w11` (final code) | full deploy incl. preflight + driver pack | `firstlogon ok` 140.4 s after the iPXE request; desktop as user `deploy` (`lab06-desktop.png`, taken ~2 min later: the beacon fires during the first-sign-in animation, before the desktop is drawn) |
| lab01 | `vm-create lab01` (no driver pack) | full deploy | `firstlogon ok` at 141.6 s |
| lab02 | `vm-create lab02 --mode none` (no `machines/` entry) | WinPE, report, prompt, disk untouched | `ts-start mode=shell`, `shell ok`; qcow2 still 324 KiB; console in `lab02-unlisted-machine-shell.png` |
| lab04 | cfg `IMAGE=missing.wim`, *before* the preflight step existed | fail loudly | `download fail rc=22`, `ts.log` uploaded with curl's 404, `await` exit 1. **But the disk had already been wiped** (92 MiB written). This is what the preflight step was added for |
| lab05 | same broken cfg, *with* preflight | fail before any write | `preflight fail rc=1 msg=missing: images/missing.wim`, qcow2 still 324 KiB, `await` exit 1 |

Timelines are in `timelines.txt` (output of `bin/status <vm>`), the fleet view
in `status.txt`, uploaded logs in `logs.txt`.

## Driver pack: outcome and control

`fetch-tools virtio` built `http/drivers/virtio-w11.wim` (3 `.inf`). After
deployment both VMs were **cold-booted** with the NIC changed to
`virtio-net-pci` (`vm-boot <vm> --nic virtio-net-pci`), and the QEMU user-net
connection table was read (`info usernet`):

| VM | driver pack | connections over the virtio NIC |
|---|---|---|
| lab03 | virtio-w11 | 20 to 29 TCP sessions within 10 s |
| lab01 | none | 0 for 90 s; Windows at the desktop with the "no network" tray icon (`lab01-virtio-no-driver-pack.png`) |

Trap found on the way: `bin/vm-stop` presses the ACPI power button, and Windows
answers with fast startup (hibernation). Booting lab01 with a different NIC
then *resumed* a kernel that had never seen it and hung before drawing
anything. A full shutdown (`shutdown /s /t 0`, typed with `bin/vm-type`) fixed
the experiment. Change VM hardware only after a full shutdown.

## Checks that were made to fail on purpose

- `bin/lint` self-test: 11 defects injected into a scratch copy of `http/`, 11
  reported. Its first run reported 10/11: the "LF line endings" mutation
  truncated the file instead of converting it, so the self-test caught a bug
  in the self-test.
- `bin/lint` on the real tree with lab04's broken cfg: 1 FAIL naming the
  missing image (`lint-with-broken-cfg.txt`), exit 1.
- `bin/serve` self-test on every start: `/ts/id.cmd` must reject a malformed
  id (HTTP 400) and a GET of an uploaded file must be refused (HTTP 403).
- `bin/fetch-tools`: the locally cached `wimboot` "v2.9.0" from April
  (66,560 bytes) does not match today's release asset of the same version
  (76,064 bytes, re-uploaded 2026-05-18); the pin is the SHA-256 GitHub
  publishes for the current asset, and the whole acceptance ran on it.
- `bin/stage-winpe`'s "boot.wim has no winpeshl.ini" check was run against a
  scratch WIM with one added: detected; and against the pristine WIM: silent.

## Bugs found and fixed while doing this

- `set -o pipefail` + a reader that exits early (`awk … exit`, `grep -q`) kills
  the writer with SIGPIPE and turns a successful lookup into exit 141. In an
  `if` it would have made "found" read as "not found". All such pipelines now
  capture first, then match.
- `trap … EXIT` referring to a function-`local` variable (unbound at exit).
- `vm-type` returned before the guest had received the keystrokes.

## Not verified

`bin/pxe-lan start` (needs sudo and a LAN; only `dnsmasq --test` on the
generated config), `vm-create --net bridge:…`, anything on physical hardware,
and whether `HTTP_HOST='${next-server}'` would remove the need to rebuild
`ipxe.efi` per network.
