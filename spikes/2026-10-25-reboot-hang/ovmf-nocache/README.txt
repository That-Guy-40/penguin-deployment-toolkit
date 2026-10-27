The decisive bisection for the warm-reset hang: Ubuntu's own OVMF 2025.11-3ubuntu7.3
built twice from its source package, stock and with the fw_cfg cache compiled out, then
bin/smoke on each (VM_BOOT_FIRMWARE). Prepared 2026-10-27; the build itself was not run
by the agent (its sandbox refuses to execute build tools from a downloaded tree), so the
builds and the runs are the next thing to do by hand:

  export OVMF_WORK=<dir>; mkdir -p $OVMF_WORK/edk2-ubuntu-src && cd $OVMF_WORK/edk2-ubuntu-src
  V=2025.11-3ubuntu7.3; for f in edk2_$V.dsc edk2_2025.11.orig.tar.xz edk2_$V.debian.tar.xz; do
      curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/edk2/$V/$f; done
  # orig.tar.xz sha256 926f148812c119a8d89b763ffd343ca99dd37c7b7e61e335ea51ef7db07d8c24
  # debian.tar.xz sha256 b1d0afc82e395caeae72ea10c2809131d261587106b51ae93a67f79ac94c1a9c (both from the .dsc)
  dpkg-source -x --no-check edk2_$V.dsc edk2
  cp -a edk2 edk2-nocache && patch -d edk2-nocache -p1 < <repo>/spikes/2026-10-25-reboot-hang/ovmf-nocache/QemuFwCfgCache-nocache.patch
  <repo>/spikes/2026-10-25-reboot-hang/ovmf-nocache/build-ovmf.sh $OVMF_WORK/edk2-ubuntu-src/edk2 stock
  <repo>/spikes/2026-10-25-reboot-hang/ovmf-nocache/build-ovmf.sh $OVMF_WORK/edk2-ubuntu-src/edk2-nocache nocache
  # -> $OVMF_WORK/ovmf-builds/OVMF_CODE_4M.secboot.{stock,nocache}.fd; the guest's SMBIOS BIOS
  #    version reads 2025.11-3ubuntu7.3~pdt-stock / ~pdt-nocache (strings -el <fd> | grep pdt-)
  cd <repo>; for i in 1 2 3 4; do for v in nocache stock; do
      VM_BOOT_FIRMWARE=$OVMF_WORK/ovmf-builds/OVMF_CODE_4M.secboot.$v.fd \
      SMOKE_HANG_HOOK=$PWD/spikes/2026-10-25-reboot-hang/smoke-hang-hook.sh \
      bin/smoke --out spikes/2026-10-25-reboot-hang/smoke-$v-$i; done; done

On 2026-10-27 the agent got as far as: source package downloaded and verified against the
.dsc, unpacked with Ubuntu's patches applied, the nocache tree patched (scratchpad
edk2-ubuntu-src/, not kept). Prerequisites on this host, checked present: nasm,
acpica-tools (iasl), gcc 15.2, uuid-dev, python3 3.14, dpkg-dev. The flags are debian/rules'
OVMF_4M_SECBOOT_FLAGS (RELEASE, GCC5, FD_SIZE_4MB, SECURE_BOOT_ENABLE, SMM_REQUIRE, TPM2,
HTTP boot, IPv6, TLS, CC measurement, BUILD_SHELL=FALSE), so the stock build is the positive
control: it must hang like the package does (3 in 8 runs), otherwise the comparison says
nothing about the cache. Alternate the two builds so time-of-day effects fall on both.

QemuFwCfgCache-nocache.patch (5 lines, OvmfPkg/Library/QemuFwCfgLib/QemuFwCfgCache.c): early
"return FALSE" in InternalQemuFwCfgCacheSelectItem and InternalQemuFwCfgCacheReading, so every
QemuFwCfgSelectItem writes the selector port and every read is a DMA or data-port read, as in
edk2-stable202502 and earlier; the cache HOBs are still built by PlatformPei (harmless, unread).
Read in the source: QemuFwCfgSelectItem (QemuFwCfgLib.c) consults the cache first and resets
the work area otherwise; InternalQemuFwCfgReadBytes serves from the cache whenever the work
area's Reading flag is set and ignores the cached read's status (buffer untouched on error).
The work area lives in the PlatformInfo HOB (QemuFwCfgPei.c InternalQemuFwCfgCacheGetWorkArea).
