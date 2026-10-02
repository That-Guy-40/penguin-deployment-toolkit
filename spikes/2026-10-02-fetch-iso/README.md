# 2026-10-02: `bin/fetch-iso`, the v1 ISO builder ported

`docs/history/v1-setup-exe/scripts/00b-download-iso.sh` rebuilt as
`bin/fetch-iso` in the new conventions, then used for real.

## Result **[verified]**

- `bin/fetch-iso --release 24H2`: UUP dump's newest public 24H2 build was
  26100.9550 (picked by build number; the API's own order is "date added").
  Kit downloaded, packages fetched from Microsoft, ISO assembled: 4,335,187,968
  bytes, about two minutes on this host's connection (`fetch-iso-run1.txt`).
- The sidecar (`built-iso-sidecar.json`) records what is really inside:
  **build 26100.1**, not 26100.9550. The Linux kit cannot integrate cumulative
  updates; the script reads the build from the image and says so.
- The ISO is a new build, not a copy of the April one: `install.wim` and
  `boot.wim` hash differently (new WIM GUIDs and timestamps) while being the
  same sizes, because the content is the same base build.
- Proof it is usable: `ISO_PATH` pointed at it, `bin/stage-winpe` (re-extracted
  `boot.wim`, the other three boot files were byte-identical), `bin/stage-image
  --force`, `bin/lint` all PASS, then a lab VM deployed from it reached
  `firstlogon` 156 s after its iPXE request (`deploy-from-built-iso.txt`). A
  second ISO build was running on the host during that deploy.

## Checks seen to fail

- `--release 99H9`: rejected. `--release 21H1`: "UUP dump lists no public amd64
  build".
- `--check build/dl/virtio-win.iso` (an ISO that is not Windows media):
  "lacks efi/boot/bootx64.efi: not a usable Windows install ISO", exit 1.
  `--check` on both Windows ISOs: exit 0.
- `--out` naming an existing file: refused before the download starts.
- Default name already taken: the second run (`fetch-iso-run2.txt`) produced
  `win11-24h2-26100.1-1.iso` instead of overwriting or failing after the build.

## Bug found while writing it

`python3 - args <<'PY' <<<"$DATA"` gives Python two stdins; the last one wins,
so the JSON would have been executed as the script. Source now goes in with
`-c`, data on stdin.

## Limits

Only 24H2 / professional / en-us was run. The conversion kit is third-party
code generated per build by uupdump.net and cannot be pinned by hash; the
Windows packages come from Microsoft and are checksum-verified by aria2.
