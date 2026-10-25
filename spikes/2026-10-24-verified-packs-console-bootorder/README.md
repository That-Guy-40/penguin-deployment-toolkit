# 2026-10-24: every download verified, a liar in cmd, the console as text, the second-disk boot order, SSH keys

Working through `TODO.md` (housekeeping) and `DEFERRED.md` (the `pdt-console`
spike) in one lab session on this host (Ubuntu 26.04, QEMU 10.2, nginx on
8090): five VMs within six minutes, two more for the SSH host-key check, one
for per-user SSH keys, all purged afterwards. Six results:

1. **Every large download is verified on the machine.** `ts/verified.cmd`
   is the one place: fetch the sidecar, fetch the file, `pdt-sha256 --check`,
   delete on any failure, one line in `step.msg`. `25-download` (the image),
   `35-updates` (an update pack), `40-drivers` (a driver pack) and `45-winre`
   (the recovery image, when the applied image has none) call it. Every pack
   sidecar carries a `sha256` now (`bin/pack-drivers --rehash`,
   `bin/pack-updates --rehash` for old packs), recovery images have sidecars
   (`bin/stage-image --sidecars` for old ones), `15-preflight` checks they are
   served, lint demands them (five new self-test defects).
2. **A liar, found by the controls.** With a lying `images/lab-apps.winre.json`
   the step `45-winre` reported **`ok`**, with the mismatch as its message.
   The helper had failed inside the step's `else (…)` block and the step left
   with `|| exit /b !errorlevel!`; measured on the VM, `cmd /c script` exits 0
   for every `exit /b` reached through `||` or an `if` inside a multi-line
   block, literal code or not, while the same lines at top level or in a
   one-line block, and a bare literal `exit /b 9` in a multi-line block,
   propagate. The
   shell's own errorlevel is right in every case, so `step.cmd` now runs each
   step as `cmd /v:on /c "<step> & exit !errorlevel!"` and lint pins that
   line. Re-run: `45-winre fail rc=1`, nothing on `R:`.
3. **The console as text, and keys into it.** `tools/pdt-console.exe`
   (`tools-src/pdt-console.c`, the design in `DEFERRED.md`) attaches to the
   deploy window by its title, reads the viewport, and `shell-loop.cmd`
   uploads a frame whenever it changed; `bin/console` shows, lists, diffs and
   waits on frames, `bin/keys` types into the window. A sequence stopped
   before `20-disk` was resumed with `bin/keys vd 'deploy 20{enter}'` and
   reached `deployed`.
4. **The two-disk re-image loop was the lab's.** A `DISK=1` deploy with disk
   0 blank now boots Windows from disk 1 straight after `90-reboot`: `vm-boot`
   gave the second disk no QEMU `bootindex`, and OVMF puts a boot entry for a
   device not on that list (Windows Boot Manager on disk 1) after the network;
   it also reset the NVRAM whenever disk 0 alone looked empty. `50-boot` now
   records `bcdedit /enum firmware` and says in its beacon whether Windows Boot
   Manager leads the order (`bcdboot` puts it first by default; `/addlast` is
   the alternative **[read]**, and the log shows it did).
5. **Host keys on a captured image differ per machine.** A reference VM with
   the lab role (`SSH=on`) generalized itself, was captured on Linux and
   deployed to two VMs: three machines, three ED25519 host keys (RSA and
   ECDSA too). `prepare-capture.cmd`'s deletion of the host keys before
   sysprep, designed in `DEFERRED.md`, works.
6. **Per-user SSH keys for `Users` accounts.** The mechanism was tried by hand
   on one of those VMs first: `AuthorizedKeysFile .ssh/authorized_keys
   __PROGRAMDATA__/ssh/users/%u/authorized_keys` in `sshd_config`, a file
   owned by Administrators and readable by the account; `alice` logged in
   with her key, the admins' key as `alice`, her key as `admin` and a `bob`
   that does not exist were refused. Then built in: `users.txt` takes a
   fourth field `keys=<file>`, `users.ps1` installs it, `60-unattend` and
   `15-preflight` fetch and check the file, lint demands it (three more
   defects, 59/59), `bin/fetch-tools openssh` makes the lab role's
   `alice.pub` (private half `build/lab-alice`). A fresh deploy with the lab
   role: `users ok … keys=alice`, the same four logins with the same four
   outcomes.

## Files

| file | what |
|---|---|
| `vms-create.out` | `va` (base + `DRIVERS=virtio-w11` + `UPDATES=lcu`), `vb` (`lab-apps.wim` + both packs, `STOP_AFTER=30-apply`), `vc` (two 64 G disks, `DISK=1`); lint 218 PASS with the lab cfgs; booted 18:23:30 |
| `va-timeline.out` | the positive case: `25-download ok msg=sha256 0c947e48… matches images/base.json`, `35-updates ok` after 790 s (the 5.2 GB pack `lcu.wim`: the 24H2 checkpoint KB5043080 + the September 2026 cumulative update KB5124010, `--target` the latter, `--expect 26100.9550`; the log shows `match` before DISM), `40-drivers ok msg=sha256 0318467b… matches drivers/virtio-w11.json`, `50-boot ok msg=… the firmware boots Windows Boot Manager first`, `firstlogon … build=26100.9550`, `deployed` at +1063 s |
| `vb-controls.out` | **the controls**, on `vb` at the prompt after `30-apply`: each sidecar in turn made to claim 64 zeros, the step run with `X:\pdt\step.cmd`, the download checked for, the sidecar restored. `40-drivers fail rc=1 … download deleted` (no `W:\drivers.wim`, no `W:\Drivers`); `35-updates fail rc=1 … download deleted` (no `W:\updates.wim`, no `W:\Updates`); **`45-winre ok msg=images/lab-apps.winre.wim does not match …`**: the liar. The log shows the hasher's `MISMATCH` and no `Reagentc` output after it |
| `cmd-block-exit.out`, `cmd-block-exit2.out` | the quirk isolated with one-line scripts on `vb` (`t2.cmd` = `exit /b 7`): **A** `call t2 \|\| exit /b !errorlevel!` in a multi-line block → 0; **B** the same at top level → 7; **C** `call` in a block, `if !errorlevel! neq 0 exit /b !errorlevel!` → 0 (the echo before it printed 7); **D** `call t2 \|\| exit /b 1` in a block → **0**; **E** a failing program (`curl -f`) with `\|\| exit /b !errorlevel!` in a block → 0; **F** the exit itself parenthesized → 0; **G** `(echo x& exit /b 5)` one-line → 5; **H** `(call t2 \|\| exit /b 1)` one-line → 1; **K** `if exist X:\ exit /b 6` → 6; **L** a literal `exit /b 9` in a multi-line block → 9; **M** `goto :fail` then `exit /b !errorlevel!` at top level → 7; **N** `cmd /v:on /c "script & exit !errorlevel!"` → 7, 5, 7 for A, G, M: the wrapper. (The first attempt at **ti**, reading the inner shell's errorlevel with `%errorlevel%`, read the outer shell's: discarded.) |
| `vb-winre-control-2.out` | `step.cmd` with the wrapper refetched on `vb`, the winre control again: `45-winre fail rc=1 msg=images/lab-apps.winre.wim does not match the sha256 in images/lab-apps.winre.json: download deleted`, `R:\Recovery\WindowsRE\Winre.wim not there` |
| `vb-resume.out`, `vb-final-rows.out`, `vb-vd-timelines.out` | `vb` resumed with `deploy 35` (`UPDATES` dropped from its cfg to save the 13 minutes): `40-drivers ok msg=sha256 0318467b… matches drivers/virtio-w11.json`, `45-winre ok msg=Winre.wim taken from the server, the image has none; sha256 1f9ee125… matches images/lab-apps.winre.json`, `50-boot ok msg=… Windows Boot Manager first`, `deployed` (a captured role image: `firstlogon … image=reference …`) |
| `vc-firmware.out` | `vc` (`DISK=1`): `17-diskguard ok msg=disk 1:… (DISK=1)`, `50-boot ok msg=… the firmware boots Windows Boot Manager first`; the `bcdedit /enum firmware` block from `ts.log`: `displayorder {bootmgr}` first, then the two disks, PXE entries, the menu; `ts-done` at +131.7 s, **`specialize ok` at +180.3 s, `deployed ok` at +268 s** with `winre … harddisk1\partition4`; no second `ipxe`/`ts-start` (the demo's record of the loop is `spikes/2026-10-24-demo-for-noah/demo2-redeploy-loop.out`) |
| `build-tools*.out` | the three tools built twice each in the pinned container; `pdt-console.exe` three times over as it grew (`67082eb5…` prefix match, `a27cd397…` with `list`, `6255d69e…` substring match, 45,056 bytes), `check` PASS |
| `vd-ve-create.out`, `vd-first-frames.out`, `vd-prompt.png` | `vd` (`STOP_BEFORE=20-disk`) and `ve` (`--reference --role lab-apps`); `vd` stopped at +12.5 s, pushed `screen.bmp` but no frame; the screenshot of its prompt for parity |
| `vd-console-diag.out`, `vd-console-list.out` | why: `dump pdt-deploy` → 2, `dump pdt-shell` → 0 (so attaching works in WinPE); the new `list` verb shows every console title: `1216 cmd.exe  Administrator:  pdt-deploy`, `1748 cmd.exe  pdt-shell`, `winpeshl.exe  winpeshl.exe`, conhost and the services `-`. WinPE prefixes the title; the match became a substring |
| `vd-console-test.out` | **the spike's checks**: the first frame is the prompt (459 B, `cursor=20,8`, equal to the screenshot's text), `bin/keys vd 'dir X:\pdt{enter}'` → the next frame holds the listing, `dump no-such-window` → `rc=2`, no file, `bin/keys vd 'deploy 20{enter}'` → `bin/console vd --await 30-apply` returned at 18:38:27 (34 s), the frame shows `X:\Windows\System32>deploy 20` and the runner's `[pdt] 20-disk ... 25-download ... 30-apply ...` lines |
| `vd-console-off-control.out` | six frames in two minutes, 459–1479 B each (`bin/console --frames`); `bin/shell vd --off` at 18:39:14; 75 s later still six frames while the beacons went on to `ts-done`; `vd` then reached `deployed` (`vb-vd-timelines.out`) |
| `lint.out` | 233 PASS with the lab cfgs, self-test 56/56 |
| `ssh-hostkeys-pipeline.out`, `lint-labssh.out` | see "SSH host keys on a captured image" below |
| `peruser-keys-spike.out` | the mechanism by hand on `vf` (deployed from the captured image): the `users\alice\authorized_keys` file and its ACL, the `AuthorizedKeysFile` line, `Restart-Service sshd`; `alice` with her key → `win-8sirs736369\alice`, running `pwsh.exe`; `alice` with the admins' key, `admin` with alice's key, `bob` with alice's key → `Permission denied (publickey)`; `admin` still in; sshd's event log: `Accepted publickey for alice … ED25519 SHA256:wFxfxf7a…` |
| `vh-peruser-keys.out` | the toolkit's version on a fresh `--role lab-apps` VM: `users ok keys=alice`, `ssh ok … keys=1 listening=yes`, `deployed` at +302 s; `ssh -i build/lab-alice alice@…` → `win-sh2hihmafk2\alice`, the file's ACL as `users.ps1` set it (alice R, SYSTEM F, Administrators F); the three controls refused; `admin` in, the two `AuthorizedKeysFile` lines in the live `sshd_config` |
| `cleanup.out`, `lint-final.out` | the eight VMs purged, the `lab-ssh` image removed again (`lab-apps.wim` already serves as the captured image; the update pack `updates/lcu.wim`, the recovery-image sidecars and the rehashed driver sidecars stay); lint on the purged host; `build-tools check` |

## What was changed

- `http/ts/verified.cmd` (new, fetched by `deploy.cmd`), `25-download`,
  `35-updates`, `40-drivers`, `45-winre` call it; `15-preflight` checks the
  pack sidecars and, when the server has a recovery image for the image, its
  sidecar; `50-boot` records the firmware order; `step.cmd` runs the step
  under `cmd /v:on /c "… & exit !errorlevel!"`; `deploy.cmd` titles its
  window; `shell-loop.cmd` pushes console frames.
- `bin/stage-image` writes `<name>.winre.json` (and `--sidecars`),
  `bin/pack-drivers` / `bin/pack-updates --rehash <name>`, `bin/vm-boot`
  (second disk's boot index, NVRAM reset only when every disk is empty),
  `bin/build-tools` (the third tool), `bin/console` and `bin/keys` (new),
  `bin/lint` (pack hashes, the recovery-image pair, a captured image needs a
  recovery image, the `step.cmd` wrapper, `verified.cmd` call sites resolved
  like `%SRV%/` references; 56 defects).
- `tools-src/pdt-console.c` (new).

## Honest limits

- The frame shows the deploy window: the runner's lines and whatever a person
  types. A step's output goes to `ts.log`, so DISM's percentage is in
  `bin/logs`, not in the frame (the design expected it in the frame).
- `35-updates` with `--expect`: the success message was reworded after the
  one run that took that path; the new wording has not been seen in a
  timeline. `UPDATES` was dropped from `vb` before its resume.
- `bcdboot` putting the firmware entry first is **[read]** from its
  documentation and seen on OVMF only; what a real firmware does with the
  entry, and whether a PXE-first machine still needs `bin/netboot <m> local`
  (it does, by design), is unchanged: real firmware [unknown].
- `bin/shell`'s own command files still run under a plain `cmd /c`
  (`TODO.md`).
- AttachConsole across processes was expected to work in WinPE and does; the
  tool was tried on the Setup `boot.wim` of 24H2 only.
- `%u` in `AuthorizedKeysFile` expanded to the plain account name (`alice`)
  for a local account; a domain account's form is [unknown] (no domain here).

## SSH host keys on a captured image (`TODO.md`, "After that")

`ssh-hostkeys-pipeline.out`: `ve` (`--reference --role lab-apps`, `SSH=on`)
reached `deployed` at +324 s, ran `prepare-capture` (which deletes
`%ProgramData%\ssh\ssh_host_*` before sysprep) and powered off; its own
`ssh.txt` recorded ED25519 `SHA256:ogfMJu3J…`. `bin/capture-image ve lab-ssh`
published `images/lab-ssh.wim` (3.6 GB, provenance `reference … role lab-apps`)
with `lab-ssh.winre.wim` copied from base and, new today, `lab-ssh.winre.json`;
lint 231 PASS with the new image. `vf` and `vg`, deployed from it with sshd
forwarded (`vm-boot --fwd 2231:22`, `2232:22`), both `deployed` at +227 s.
`ssh-keyscan` from this host: `vf` ED25519 `SHA256:LBDf67z5…`, `vg`
`SHA256:UzhIKsZH…`, the reference `ogfMJu3J…`: three machines, three keys
(RSA and ECDSA differ too). The role's key logs in as `admin` on both (the
remote command itself was mangled by the pwsh shell, which is not the point);
the control without a key: `Permission denied (publickey)`. The
reference-image trap `DEFERRED.md` described is closed.
