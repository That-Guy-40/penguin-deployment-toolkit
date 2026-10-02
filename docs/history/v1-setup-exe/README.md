# v1: the `setup.exe` + `autounattend.xml` pipeline (retired 2026-10-02)

The first working version of this repo. It is kept as a documented fallback and
for its design notes; nothing in `bin/` uses it. It was verified end to end on
2026-06-02 (a full watched install in a QEMU VM).

How it differed from the current design (`PLAN.md`, `docs/HOW_IT_WORKS.md`):

| | v1 (here) | current (`bin/`, `http/`) |
|---|---|---|
| WinPE customisation | `03-inject-autounattend.sh` rewrote `boot.wim` with wimlib | `boot.wim` is pristine; wimboot injects files at boot |
| Install engine | Windows Setup (`setup.exe /unattend:`) from an ISO attached as a CD | `diskpart` + `dism /apply-image` + `bcdboot`, image over HTTP |
| ISO access | `sudo mount -o loop` (`02`) | `7z`, no root |
| VM NIC / TPM | virtio NIC, swtpm (Setup demands a TPM) | e1000e NIC (WinPE needs the network), no TPM needed |
| Observability | watch the QEMU window | beacons, pushed logs, `bin/status`, `bin/await` |

Design notes that still hold and are easy to forget:

- A stock `boot.wim` has two images (1 = Windows PE, 2 = Windows Setup) and the
  WIM header's Boot Index is 2. Injecting into image 1 only changed an image
  that never boots.
- Setup auto-discovers `autounattend.xml` only on removable media, not on `X:`,
  hence the explicit `/unattend:`.
- Stock WinPE has no virtio drivers: a virtio-blk disk is invisible to it.
- Windows 11 Setup requires Secure-Boot-*capable* firmware and a TPM. The
  apply-image path performs no such check.
- Once Windows is installed the firmware boots it through an NVRAM entry, so
  NVRAM must be preserved after the install and reset only while the disk is
  empty.

To run it again from the repository root (paths inside the scripts assume the
old layout, so copy the two directories back first):

```bash
cp -r docs/history/v1-setup-exe/scripts docs/history/v1-setup-exe/answer .
# then follow the order in scripts/: 00, 01, 00b (optional), 00c, 02, 03, 04, 05, 06
```

The ISO builder (`scripts/00b-download-iso.sh`, UUP dump) is the one v1 script
with a direct successor: `bin/fetch-iso`.

The old `config.sh` keys (`VM_NAME`, `TPM_STATE_DIR`, `IPXE_ROM`, the
`validate_*` functions) are in git history: `git show 4ceb865:config.sh.example`.
