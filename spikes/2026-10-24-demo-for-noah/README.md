# 2026-10-24: the demo for Noah, as it ran

Raw outputs of the live demo written up as the shared document "Penguin
Deployment Toolkit: a demo for Noah" (a Claude doc; the narrative, timings
and hardware notes are there). Three lab VMs started within one minute on
this host (Ubuntu 26.04, QEMU 10.2, nginx on 8090), all purged afterwards.

| file | what |
|---|---|
| `lint.out`, `lint-control.out` | lint 182 PASS / self-test 45/45; the `MODE=wipe` control: 1 FAIL, exit 1 |
| `demo1-create.out`, `demo1-timeline.out` | `--role lab-apps`, PXE to `deployed` in 306.6 s (passwords masked) |
| `demo1-rdp-ssh.out`, `rdp-*.out` | `xfreerdp /auth-only`: admin rc 0; wrong password and deleted `deploy` rc 134; ssh as admin, fingerprint = `ssh.txt`, no-key and `alice` refused, `Invoke-Command` over SSH |
| `demo0-shell.out`, `demo0-043430.png` | the unlisted VM: `MODE=shell`, no C:, disk 0 blank, control command rc 1 |
| `demo0-collector-chain.out` | collector → inventory → `enroll` (refuses a second time) → `pdt-pxe-next --reboot` → `deployed` in 3 min 40 s |
| `demo2-refusal.out`, `demo2-disk1.out` | two blank 64 GB disks: `17-diskguard fail`, both still blank; `DISK=1` → disk 1 partitioned, disk 0 untouched |
| `demo2-redeploy-loop.out`, `demo2-await.out`, `demo2-reboot-local.out`, `demo2-serial-full.log`, `demo2-045347.png` | **finding**: after `90-reboot` the firmware tried blank disk 0, then the network, and re-imaged disk 1; `netboot demo2 local` stopped it and Windows on disk 1 then came up (`firstlogon`, `winre … harddisk1`, a desktop after a power cycle), after the firmware's network timeouts. `TODO.md` has the item. |

Not verified today: anything on physical hardware (the doc's hardware
section is [read] throughout); `boot ok` after the power cycle of demo2 was
not seen (the VM had been force-stopped 2 s after `deployed`, before the boot
task's registration was necessarily on disk; a desktop was).

## Addendum: the screen pusher was built and in use (correction)

The first draft of the demo doc said `pdt-screen.exe` had not been built on
this host. Wrong: `http/tools/pdt-screen.exe` (built 2026-10-12, recorded in
`http/tools/built.json`, `bin/build-tools check` ok) was fetched 20 times on
2026-10-24 and every VM pushed `screen.bmp`;
`demo1-screen-pushed-during-30-apply.png` is `bin/screen` on demo1's last
frame. Reproducibility (`screen-build-repro-*.out`): two builds with the same
flags on this host differ in two bytes (the PE header timestamp); a Debian
trixie container (GCC 14) differs more (different toolchain); with
`-Wl,--no-insert-timestamp` or `SOURCE_DATE_EPOCH=0` two builds are
bit-identical (`257745e4…`). `bin/build-tools` passes neither flag yet.

Then done (`build-tools-repro.out`, `screen-canonical-vm-test.out`,
`sc-live-canonical-pusher.png`): `bin/build-tools` now passes
`-Wl,--no-insert-timestamp`, compiles twice and refuses a result that differs
from itself (control: with the flag emptied it refuses, "2 byte(s)"), and the
default build runs in a pinned container (`debian@sha256:38a76d01…`,
`gcc-mingw-w64-x86-64=14.2.0-17+27`): 40960 bytes, sha256 `31f25d28…`,
builder and compiler recorded in `built.json` and shown by `check`. A fresh
`--mode none` VM fetched that binary (40960 bytes in the access log) and
`bin/screen` showed its WinPE console 2 s old. The host build (GCC 13) is
`257745e4…`, also self-identical, a different binary.
