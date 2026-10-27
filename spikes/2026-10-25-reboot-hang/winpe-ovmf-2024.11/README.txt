WinPE reboot loop on OVMF 2024.11 (edk2-stable202411, no fw_cfg cache), 2026-10-25 04:35.
  reboot-loop.sh rh-base 5 . --firmware <scratchpad>/ovmf-2024.11-dl/x/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
  HANG_AFTER=150 COLD_AFTER=150 QEMU_TRACE='fw_cfg_select,fw_cfg_read,cpuhp_acpi_*'
Firmware in use verified from /proc/<qemu pid>/cmdline (pflash unit 0 = the scratchpad file,
sha256 129253b3..., not /usr/share/OVMF's 33c413a0...): vm-boot's status line printed only the
basename, which is the same for both files; it now prints the full path for --firmware.
result.txt: 5 of 5 reboots fine, 0 hung (each back in WinPE in 20-21 s).
qemu-trace.log: 6 firmware runs (1 cold + 5 warm); key 0x25 (etc/e820) selected 48 times = 8 per
run, key 0x19 (file_dir) 228 = 38 per run: the pre-cache read pattern (2025.11: 1 and 9 per run,
fw-cfg-items.out). The earlier single traced warm reboot on this firmware (ovmf-2024.11.txt) that
gave no beacon within 300 s was a lab hiccup, not a hang: this loop's 5 warm reboots all beaconed.
Five reboots is no rate measurement: the 2025.11 harness loops were 147 clean too; the
discriminating test is bin/smoke (3 hangs in 6 runs on 2025.11), run with VM_BOOT_FIRMWARE.
