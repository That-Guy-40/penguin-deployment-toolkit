# 2026-10-24: a hash on the machine, a verified download, and what DISM does with a corrupt WIM

Three questions, answered in the lab on this host (Ubuntu 26.04, QEMU 10.2,
nginx on 8090; three VMs started within a minute, all purged afterwards):

1. **Can the machine hash what it downloaded?** WinPE (the Setup `boot.wim`)
   has no `certutil`, no PowerShell, no .NET. Now it can: `tools/pdt-sha256.exe`,
   from `tools-src/pdt-sha256.c` (plain C99, FIPS 180-4), built by
   `bin/build-tools` like the screen pusher. `25-download` runs it on every
   image against the sidecar before anything is applied.
2. **Does DISM catch a corrupt WIM at apply time?** For the corruption tried
   here, yes: `0x80070570` (`ERROR_FILE_CORRUPT`, exit 1392), 39 s into the
   apply, after writing a partial `W:\Windows`. The download check catches the
   same file before the apply starts, with nothing written.
3. **Can we build our own pinned OpenSSL for Windows the same way?** Yes:
   `bin/build-tools openssl` cross-builds OpenSSL 3.5.9 (LTS) from the tarball
   pinned by SHA-256, static, twice, in the pinned container; the two
   `openssl.exe` are identical (7,268,352 bytes, `53842107…`), and a third
   build in a fresh container run gave the same hash. It runs in WinPE and its
   `dgst -sha256` agrees with `pdt-sha256` on every file tried, the 3.5 GB
   image included. Nothing in the task sequence runs it; it is there as the
   second opinion that is not our code.

| file | what |
|---|---|
| `native-tests.sh`, `native-tests.out` | the C compiled natively on Linux with `-Wall -Wextra -Wconversion -Wshadow -Werror`: FIPS vectors, 23 random files at block and buffer boundaries vs `sha256sum`, a 4.4 GB file vs `sha256sum`, both served images vs their sidecars (Python hashlib), `base.wim` vs `sha256sum`; the sidecar rule and every exit code (0/1/2/3/4) with inputs built to provoke each. 28/28 |
| `build-tools.out` | the guard's negative control (no `--no-insert-timestamp`: "differ (2 byte(s))", nothing recorded); the canonical container build of both tools (`pdt-screen.exe` unchanged at `31f25d28…`, `pdt-sha256.exe` 45,056 bytes `ddd0fd06…`, then `cd096583…` after the review's one-line change to the C); `build-tools openssl`; `check`; `built.json`; the third OpenSSL build; the rebuild after the change (`check` first said STALE) |
| `hd-apply-guard.out`, `hd-final-hasher.out`, `hv-final-deploy.out`, `cleanup.out` | after the review: the `30-apply` guard refusing an unverified image and proceeding with a token; the final hasher on the machine (no-args exit 2, hashes itself to the recorded `cd096583…`, `--check` match); a fresh VM `hv` deployed with the final files (`25-download ok` in 25.3 s, `deployed` at +234 s); all four VMs purged, the corrupt images removed |
| `lint.out` | lint 208 PASS (195 once the lab cfgs were purged), self-test 50/50 (three new defects: the hasher not built; an image sidecar without `sha256`; an `IMAGE` that is not a `.wim`); live controls: one byte of `tools/pdt-sha256.exe` flipped → `bin/build-tools check` and `bin/lint` both FAIL "not the binary that was recorded", restored; an unrecorded `tools/pdt-foreign.exe` → FAIL "present but not recorded" |
| `corrupt-image-prep.out` | `corrupt.wim` = `base.wim` with the byte at offset 1,781,643,326 (the midpoint) flipped `0xf9 → 0x06`; `corrupt.json` carries base's hash (a lying sidecar), `corrupt-true.json` the true one |
| `vms-create.out` | `hp` (plain deploy, `STOP_AFTER=25-download`), `hc` (`IMAGE=corrupt.wim`), `hd` (`IMAGE=corrupt-true.wim`), booted at 14:04:52 |
| `hp-on-machine.out` | on `hp` after the verified download: `pdt-sha256.exe` hashes itself and the pusher to exactly what `built.json` records; `openssl.exe` fetched, `version -a` (static, mingw64, "built on" epoch 1), its hash is the recorded one; `openssl dgst -sha256` of the two tools and `W:\image.wim` equals `pdt-sha256`'s; `--check` by hand: match |
| `hc-mismatch-control.out` | **the control**: `25-download fail rc=1 msg=image.wim does not match the sha256 in images/corrupt.json: download deleted, nothing applied`; the log shows both hashes and `MISMATCH`; `dir W:\` afterwards: `Scratch` only, 0 files |
| `hd-dism-corrupt.out` | **the DISM question**: `25-download ok` (true hash), `30-apply fail rc=1392`; `dism.log`: `GetImageErrorCode:(8174): The file or directory is corrupted and unreadable` on a WinSxS `resutils.dll`; `W:\Windows` partially populated |
| `hp-resume-deployed.out`, `timelines.out` | `hp` resumed with `deploy 30` from the prompt (`30-apply ok` in 89 s, `deployed ok` at +464.8 s, 225 s of which were the pause at the prompt); all three timelines |
| `hash-timing.out` | the 3.5 GB image hashed inside the VM: 9.4 s (`pdt-sha256.exe`), 6.5 s (`openssl.exe`) |

## What the download check costs

`hash-timing.out`, measured on `hd` with delayed expansion (a first attempt
used `%time%`, which cmd expands once per line and so printed the same value
three times): the 3.5 GB image hashes in 9.4 s with `pdt-sha256.exe` (plain C,
about 380 MB/s) and 6.5 s with `openssl.exe` (SHA-NI assembly). `25-download`
on `hp` took 24.8 s for download plus hash, three VMs downloading at once; the
demo run earlier today took 15.6 s for the download alone, also with three VMs
up. So the check costs roughly ten seconds per machine on this host.

## Honest limits

- One corruption was tried against DISM: a single flipped byte in the middle
  of the file, which landed in a compressed resource. Whether DISM notices a
  byte in a region it never reads (padding, the integrity table, an unused
  resource) is [unknown]; the download check does not care where the byte is.
- The hasher is fetched from the same server as the image, so the check proves
  transit integrity and that the server's file is the one its sidecar
  describes; it does not defend against a hostile server. That is the trust
  boundary the toolkit already has (whoever writes `http/` runs code as SYSTEM
  on every booting machine).
- Driver packs, update packs and the separate `winre.wim` are not yet verified
  on the machine (`TODO.md`).
- `openssl.exe` was run in WinPE only for `version` and `dgst`; nothing else
  about it is claimed.

## The security review, and what it changed

An independent review of the hasher, the two steps, `build-tools` and the lint
changes (read-only; the C also built with ASan/UBSan and run on sidecars of
exactly 1 MiB, keys cut at every byte, NULs, mixed case; no sanitizer report,
no overread) returned twelve findings. Fixed before the commit:

| finding | fix | evidence |
|---|---|---|
| a failed download (`curl` exit 18, connection dropped) left a partial `W:\image.wim` that a resumed `deploy 30` would apply, bypassing the gate | `25-download` deletes the download on any `curl` failure; a match writes `X:\pdt\image.verified` (the RAM disk: per boot), and `30-apply` refuses without it | `hd-apply-guard.out`: on the VM whose old `25-download` wrote no token, the new `30-apply` stops with "W:\image.wim was not verified by 25-download in this boot"; with a token it proceeds (and DISM fails at 51 % on the corruption, as before) |
| `build-tools check` iterated the record, so an unrecorded binary in `tools/`, or a required tool never built, passed silently | the tool list is the authority: a required tool without an entry and any `pdt-*.exe`/`openssl.exe` without an entry FAIL | `lint.out`: an empty `tools/pdt-foreign.exe` → `FAIL … present but not recorded` |
| the toolchain pins were recorded but never compared | a binary whose `builder` is not the pinned container is reported as PASS "but NOT the canonical build" | `check` output |
| `%IMAGE:.wim=.json%` is a no-op for an `IMAGE` that does not end in `.wim`: preflight passed, and `25-download` would have curled the image into the RAM disk as the "sidecar" | `15-preflight` and `25-download` refuse such an `IMAGE`; lint FAILs the cfg (new self-test defect, 50/50) | `lint.out` |
| the hasher was kept from an interrupted fetch and a non-running binary read as "mismatch" | fetched to `.part` then moved; smoke test: no arguments must exit 2, anything else is its own message | `25-download.cmd` |
| `--deep` compared the sidecar hash case-sensitively, `pdt-sha256` not | lint lowercases | `bin/lint` |
| stdout failure (full disk) was not detected | `fflush`/`ferror` → exit 3 | `native-tests.out` (the `/dev/full` probe) |
| `cleanup` under `set -e`; `head` in a pipeline under `pipefail`; a bumped OpenSSL pin gave a misleading message | `\|\| true`, parameter expansion, a `.tar.gz` branch | `bin/build-tools` |

Not changed, on purpose: the sidecar scanner is byte-wise, not JSON-aware (the
first `"sha256"` key wins; `bin/stage-image` writes it at the top level, before
`source` and `provenance`; a nested one first would fail closed). And the
review's scope note stands: this is integrity, not authentication; hasher,
sidecar and image come from the same server as `boot.wim` itself.

After the fixes: the C re-tested natively, the tools rebuilt in the container
(`check` first called the served `pdt-sha256.exe` stale, as it must), lint and
its controls re-run (`lint.out`), and a fresh VM deployed end to end with the
final step files (`hv-final-deploy.out`).

## Lint's own defect, found on the way

The new step's `%PDT%\image.json` was reported as "uses `X:\pdt\image.js`,
`ts/deploy.cmd` does not fetch it": the helper regex matched `.js` as a prefix
of `.json`. Fixed with a lookahead (`(?![\w.])`); the self-test's unbroken
reference copy then passed again.
