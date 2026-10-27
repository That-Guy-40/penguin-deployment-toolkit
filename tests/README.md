# Tests: what is checked where

Four tiers, cheapest first. Each one answers a different question; none stands
in for another.

| tier | command | time | question it answers |
|---|---|---|---|
| host unit | `bin/tests [-v] [name...]` | ~1 min | do the `bin/` scripts that drive the lab, the Python helpers and the reboot-hang spike's tools do what their comments say, against a sandbox repo and a fake QEMU? |
| static | `bin/lint [--selftest]` | seconds | is `http/` (what WinPE and Windows fetch) consistent: every referenced file exists, CRLF where Windows reads it, roles and machine cfgs well-formed? The self-test injects known defects and expects every one reported |
| lab | `bin/smoke [--out dir]` | 25-35 min | does the whole toolkit deploy Windows end to end on two VMs at once, with every layer (iPXE, WinPE steps, DISM, roles, SSH, RDP, removal) checked and its refusals fired as controls? |
| by hand | `docs/MANUAL_TESTING.md` | hours | the same on the operator's screen, plus what needs hardware |

Rows everywhere are `PASS`, `FAIL`, `CONTROL` (a check that had to refuse or fail,
and did: the assertion is known to bite) or `UNKNOWN` (could not be checked here;
never a pass). A test file that fires no CONTROL fails the run, because an all-PASS
file is indistinguishable from one that checks nothing.

## `bin/tests`: the host tier

Every `tests/*.t.sh` (bash, `source tests/lib.sh`) and `tests/*.t.py` (`python3 -I`,
`tests/pylib.py`) runs on its own in a sandbox: `tests/lib.sh`'s `sandbox` copies
`bin/` to a fresh `/tmp/pdt-tests.XXXXXX/`, writes a `config.sh`, creates the
directories a checkout has (`vms/ run/ http/ pxe/ fw/ roms/`) and puts
`tests/fakes/` first on `PATH`, so `qemu-system-x86_64`, `qemu-img`, `socat` and
`vm-shot` are fakes that record what they were asked (`$FAKE_QEMU_ARGV`,
`$FAKE_MONITOR_LOG`) and answer from a file (`$FAKE_MONITOR_REPLY`). Nothing boots,
nothing touches this checkout's `vms/`, `run/` or `http/`. The fake QEMU daemonizes
a child whose `comm` stays `qemu-system-x86` so `vm_pid`'s check is the real one.

| file | covers | checks the suite depends on |
|---|---|---|
| `vm-create.t.sh` | `bin/vm-create`: vm.conf, UUID/MAC, machine cfg, modes, extra disks, refusals | a second create of the same name is refused; bad modes and sizes are refused |
| `vm-boot.t.sh` | `bin/vm-boot`: the QEMU argv (pflash pair, q35/smm, smp, bootindex order, netdev, forwards, NIC/ROM, extra disks, trace), the vars.fd reset rule, `--firmware` vs `VM_BOOT_FIRMWARE`, `--smm off`, the status line | a running VM is not booted twice; `--fwd` on a bridge, a bad `--smm`, a missing firmware file, a failing QEMU are refused/die |
| `vm-stop.t.sh` | `bin/vm-stop`: ACPI `system_powerdown` over the monitor, `--force`, the pidfile; `--full` | stopping a stopped VM is a refusal; UNKNOWN for the 60 s ACPI-ignored path (takes 60 s by design) |
| `await.t.sh` | `bin/await`: step reached, `--run latest`/ID, `--from-start`, timeouts, a `fail` event ends the wait with rc 1 | an unknown VM and a wait that times out return non-zero |
| `shell.t.sh` | `bin/shell`: the cmd file for WinPE (CRLF) and for the collector (sh, LF), numbering, the upload wait, `--off`, the "may no longer be in WinPE" note after `ts-done` | no command and no `--off` is refused; an unknown machine is refused |
| `status.t.sh` | `bin/status`: the table, FAIL/STUCK?/busy flags, names from vms/, the per-machine detail with relative times | an unknown ID; `--stale` |
| `hang-record.t.sh` | the reboot-hang spike's `hang-record.sh` (which memory it dumps for which RIP, the trace copy) and `smoke-hang-hook.sh` (records, then waits only for the PEI variant's RIP range) | a Windows RIP gets no dump; a DXE RIP gets no wait; the wait helper sees a recovery only on the monitor's real 16-digit format |
| `repo-rules.t.sh` | rules over the repo's own shell: no `date +%<digits>N` (see Host notes) | a planted `%3N` in a `bin/` script and in a test is caught |
| `pdt-module.t.py` | `bin/_pdt.py`: `parse_beacon`, `read_access_events`, `all_events` order, `resolve_id` (UUID, prefix, name), `vm_names`, `age` | malformed lines are dropped; an ambiguous prefix is refused |
| `find-module.t.py` | the spike's `find-module.py`: placing a RIP in a dumped firmware image by its PE header, `--extract-fv` on the installed OVMF, reading the PCD database (CPU count tokens) | a corrupt PE header is reported, not placed; a RIP outside every image |

Not here, lab tier only: everything that runs inside WinPE or Windows (`http/ts/`
steps, `25-download`, roles, `post/`), `bin/serve`'s nginx, iPXE, and the reboot
loops (`spikes/2026-10-25-reboot-hang/reboot-loop.sh`). `bin/lint` checks their
text; `bin/smoke` runs them.

## Writing a test

```bash
#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox; B="$T/bin"
"$B/vm-create" lab1 --mode none >/dev/null 2>&1
chk      "what it should be"  "<ERE>"  "$(cat "$T/vms/lab1/vm.conf")"
refuses  "what must be refused" "<ERE the error must match>" -- "$B/vm-create" lab1
finish
```

`pass`/`fail <what> <why>`/`control`/`unknown <what> <why>` print rows; `chk`,
`chk_rc`, `chk_grep` wrap the common shapes; `refuses` is a CONTROL that the
command exits non-zero with a message matching the pattern. Run the negative
control for every assertion that matters: break the thing and watch the row go
red before trusting the green one. Keep dangerous verbs out of test data (an
inert placeholder, never the real command: global CLAUDE.md).

## Host notes

**`date +%3N` is wrong on this host.** Ubuntu 26.04's `/usr/bin/date` is uutils
coreutils 0.10.0, which builds a truncated `%N` from the nanosecond integer
without zero-padding it to nine digits: in the first tenth of every second
`%3N` prints the first three significant digits, 10x or 100x the real value
(one reading, both formats: `date +%N_%3N` → `012765933_127`; `%N` alone is
right). Consecutive `date +%s.%3N` timestamps therefore run backwards about
once a second, which once put a test's `ts-done` beacon 0.4 s before the
`collect` beacon written earlier and failed `shell.t.sh` in one run of ten
(2026-10-27). `repo-rules.t.sh` bans the format in the repo's shell and reports
what the host's `date` does; the real beacon log is stamped by nginx (`$msec`),
not by `date`, so deployments were never affected. Upstream: GNU honours the
width; uutils issue #11658 ("strftime ignores flags and widths on %N", closed
2026-10-12 via PR #15111) covers the width being ignored, not this unpadded
truncation, which 0.10.0 still has [verified on this host]; whether a later
release fixes it is [unknown].
