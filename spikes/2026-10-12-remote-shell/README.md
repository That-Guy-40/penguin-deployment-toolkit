# 2026-10-12: remote shell over HTTP (spike → feature)

For machines with no usable screen or keyboard, and for every physical
machine (no QEMU monitor to type into). Design in
`docs/REMOTE_VISIBILITY.md`; this is the evidence.

## What was built

- `http/ts/shell-loop.cmd`: started by `deploy.cmd` once per boot, in its own
  window, right after `ts-start`; alive as long as WinPE is. Every 2 s it
  GETs `cmd/<id>/<run>/<n>.cmd`; if present, `cmd /c` it, append
  `[pdt] exit code N`, PUT the output as `uploads/<id>/<run>/cmd-<n>.out`,
  `n+1`. `n` starts at 1 per run (the run token is per boot), so nothing runs
  twice and nothing from an earlier boot runs at all. `exit /b 42` ends the
  loop (the kill switch).
- `bin/shell <machine> '<command>'`: writes the next numbered file for the
  machine's current run (atomically: `.part` + rename), waits for the
  output, prints it, exits with the command's exit code; 2 on timeout.
  `--off` sends the kill switch.
- Server side: `http/cmd/` is just static files (git-ignored). No nginx
  change, no new binary, no listening port on the target.

## Verified, VM `rs` in `MODE=shell` **[verified]**

| test | result |
|---|---|
| `bin/shell rs 'dir X:\pdt'` | the listing, 2.2 s round trip (`cmd-1.out`) |
| `bin/shell rs 'nosuchprogram --x'` | "not recognized", **exit 1** (`cmd-2.out`): exit codes come back |
| `bin/shell rs 'echo id=%ID% run=%RUN% mode=%MODE% & ver'` | the WinPE environment (`env.cmd`) is loaded in the loop (`cmd-3.out`) |
| `bin/shell rs --off` | `cmd-4.out`, loop ends |
| `bin/shell rs 'echo still here' --timeout 8` after `--off` | **timeout, exit 2**: the negative control that the loop is really gone |

`bin/lint`: `deploy.cmd` fetches `shell-loop.cmd`; every program the loop
runs is in WinPE; the optional `tools/pdt-screen.exe` reference is marked
`[optional]` and reported as such while it is not built.

## The screen pusher, later the same night **[verified]**

`gcc-mingw-w64-x86-64` installed; `bin/build-tools` built
`tools/pdt-screen.exe` (43,520 bytes, no warnings, hash recorded in
`tools/built.json`). VM `rs` rebooted (a new run, so the loop restarted and
fetched the binary):

| test | result |
|---|---|
| `bin/screen rs` vs `bin/vm-shot rs` taken a second apart | both 1280×800, **100.00 % identical pixels** (`rs-screen-pushed.png`, `rs-screen-vm-shot.png`) |
| cadence and cost | a 3,072,054-byte BMP every ~6 s, each PUT 0.07 s on this host |
| `bin/shell rs --off`, then `bin/screen rs` twice | "26s old", "36s old": the pushes stopped with the loop (negative control) |
| during a deploy (VM `rt`, `MODE=deploy`) | `bin/shell rt 'dir W:\ & tasklist \| find …'` while `30-apply` ran: the half-applied `W:\` listed (`rt-cmd-1-during-apply.out`); `tasklist` is not in WinPE and the pipe cut the command short, reported as exit 255 (the shell is honest about what WinPE lacks, exactly like a step). `bin/screen rt` 4 s old: the WinPE console with the step banners up to `25-download …` (`rt-screen-during-apply.png`; DISM's own output goes to `ts.log`, not the screen, so the picture is for what the log cannot show: a dialog, a BSOD, a firmware prompt). The deploy went on to `deployed ok`; `30-apply` took 74 s against the usual ~47 (the 3 MB pushes and the `dir` share the disk; acceptable, and the cadence is a one-line setting, `PDT_SCREEN_EVERY`) |

## Not in the installed OS

The loop does not run after first logon (no agent, by design);
`docs/REMOTE_VISIBILITY.md` says what to use there (RDP via a role).
