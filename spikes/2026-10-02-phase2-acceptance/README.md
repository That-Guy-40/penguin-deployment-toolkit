# 2026-10-02: Phase 2 acceptance (step-based task sequence)

Acceptance run for Phase 2 of `PLAN.md`. Everything ran through `bin/` on QEMU
user-mode networking, Windows 11 Pro 24H2 build 26100.1. Timelines are in
`timelines.txt` (`bin/status <vm>`), uploaded logs in `logs.txt`.

## What ran

| VM | set-up | expected | observed |
|---|---|---|---|
| t1, t7 | plain `vm-create`; `models/lab-vm.cfg` says `DRIVERS=virtio-w11` | full deploy; the driver pack arrives through the model file; WinRE on the recovery partition | all ten steps `ok`, `40-drivers` ran (not skipped), `firstlogon ok`, `winre ok status=Enabled location=…partition4… windows_partition=3` |
| t3 | no machine cfg; the model file additionally says `MODE=deploy` | a model file must not be able to authorise a wipe | `ts-start mode=shell`, `shell ok`, disk still 324 KiB |
| t4 | `STOP_AFTER=15` | stop after preflight, nothing touched | `stop ok after=15-preflight`, disk still 324 KiB; the prompt has `MODE`, `RUN`, `MODEL` set (`t4-prompt-env-loaded.png`) |
| t2 | `STOP_BEFORE=45-winre`, then `deploy 50` typed at the prompt | stop; resume from 50, skipping 45 | `stop ok before=45-winre` (`t2-stop-before.png`), then `50-boot` … `ts-done`, `firstlogon ok` |
| t4 again | cfg changed on the server to a layout **without** a recovery partition + `STOP_BEFORE=45-winre`; `deploy` typed (no reboot), then `step.cmd 45-winre`, then `deploy 50` | the re-run picks up the new cfg; the step fails by name; the first-logon check fails | ran to the stop; `45-winre fail rc=1 msg=no recovery partition R:`; after first boot `winre fail status=Enabled location=…partition3… windows_partition=3` |
| t1 again | fully shut down, cfg `MODE=capture`, `vm-boot --pxe` | capture the volume, wipe nothing | `70-capture ok msg=uploaded capture.wim 4666567334 bytes from C:` in 95 s |
| t6 | `IMAGE=` the captured WIM | does a captured image deploy? | `45-winre fail: the image has no Windows\System32\Recovery\Winre.wim`; after `deploy 50` it booted to a desktop with network (`t6-captured-image-desktop.png`) |
| t5 | `UPDATES=` a pack of KB5043080 + KB5124010 (5 GB), first version of the step (DISM's exit code as the verdict) | the installed system reports the updated build | `35-updates fail rc=552` after 9 min, with a 444 MB `dism.log`. Resumed with `deploy 40`: `firstlogon ok build=26100.9550`. **The update was installed; the exit code lied** |
| u1 | the same two packages, `--target` the cumulative update, `--expect 26100.9550` | clean install of the update | `35-updates ok` (DISM: "Processing 1 of 1 - The operation completed successfully"), `firstlogon build=26100.9550`, `winre ok` |
| u2 | targeted, `--expect 26100.99999` | a wrong expectation must fail the step | `35-updates fail rc=1 msg=expected package 26100.99999 is not installed in the image (dism exit 0)` |
| u3 | no `--target` (whole folder), `--expect 26100.9550` | DISM exits 552 but the outcome is right | `35-updates ok msg=dism exit 552, but package 26100.9550 is installed in the image`, `firstlogon build=26100.9550`, `winre ok` |
| u4 | a temporary step `16-abort-test`: `nosuchprog x \| find "y"` | an aborted step must be reported | `16-abort-test fail rc=255 msg=the step was cut short…`, disk untouched |

## What was learned (and was not what I expected)

- **Windows puts WinRE on the recovery partition by itself.** On t2 the
  `45-winre` step was skipped, and the first-logon check still reported WinRE
  enabled on partition 4. What matters is that a recovery partition of the
  right GPT type exists; the step makes the outcome explicit at deploy time
  rather than leaving it to first boot. The control that makes the check bite
  is a layout with no recovery partition (t4): WinRE stays on the Windows
  partition and `winre fail` is reported.
- **A captured Windows volume has no `Winre.wim`.** Once WinRE is enabled the
  file lives on the recovery partition, not under `C:\Windows\System32\Recovery`.
  `45-winre` therefore refuses a captured image. Phase 4 has to decide where
  the captured image's `Winre.wim` comes from.
- **An un-sysprepped captured image applied to another VM boots** to the
  existing user's desktop. It is a clone, not a deployable role image (same
  machine identity, no specialize pass, no beacons), but the capture, upload,
  apply and boot mechanics work.

## The silent failure, and what it changed

The first rerun of the update test produced nothing at all: three VMs sat at
the WinPE prompt with `35-updates start` as their last event and no `fail`.
Cause, reproduced with a ten-line batch file on the VM:

1. The step used `findstr`. The Setup `boot.wim` has `find`, not `findstr`.
2. In WinPE's `cmd`, a **pipe** to a program that does not exist ends batch
   processing altogether: the step, `step.cmd` that called it, and `deploy.cmd`
   above that, all gone without a message. (Outside a pipe, a missing program
   is just an error line.)

So the runner lost the ability to report the very failure it was built to
report. Fixes: every step now runs in a child `cmd /c`, where the same abort
costs only the step and returns exit code 255 (u4); `35-updates` uses `find` and
temp files, no pipes; and `bin/lint` reads the list of programs out of
`boot.wim` and fails any `ts/` script that runs one WinPE does not have. Put
back into the real tree, the `findstr` line makes `lint` exit 1.

## Checks seen to fail

- `bin/lint` self-test: 22 injected defects, 22 reported (eleven new for
  Phase 2: missing step, orphan step, LF step, bad `STOP_BEFORE`, `MODE` in a
  model file, bad model file name, inline comment in a cfg, misspelt key,
  missing update pack, helper not fetched, a program WinPE does not have).
- `35-updates` with a wrong expectation (u2); a step aborted by `cmd` (u4).
- `45-winre` with no recovery partition; `winre` first-logon check with WinRE on
  the Windows partition; `await … winre --ev fail` used as the assertion.
- A flawed check of my own, caught: `step.cmd & echo %errorlevel%` on one line
  prints the *previous* exit code, because cmd expands the line before running
  it. The standalone-step test was redone as separate commands.

## Added after the first run

- Logs are pushed every 20 s *while* a step runs (`pushloop.cmd`), not only
  when it ends. On t7 the uploaded `ts.log` grew 1978 → 4554 → 7306 bytes
  during `30-apply` and `dism.log` appeared mid-step. Prompted by t5, whose
  update step ran for many minutes with nothing visible on the server.
  `bin/status` shows such a machine as `busy` instead of `STUCK?`.
- DISM's log goes to `W:\Scratch` once the Windows partition exists and
  `35-updates` runs DISM at `/loglevel:2`: the largest `dism.log` of the
  final runs was 2.2 MB, against 444 MB on the RAM disk in t5.

## Captured image (`captured-wim.txt`)

One image, XPRESS, integrity table present, 96,397 files, `wimlib-imagex
verify` clean. Present: `\Windows`, `\Users\deploy`. Absent: `\pdt`,
`pagefile.sys`, `hiberfil.sys`, `System Volume Information`.
