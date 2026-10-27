#!/bin/bash
# build-ovmf.sh <tree> <tag>: build OvmfPkgX64 the way Ubuntu's debian/rules builds
# OVMF_CODE_4M.secboot.fd (OVMF_4M_SECBOOT_FLAGS, RELEASE, GCC5), with the firmware
# version string marked so the guest's SMBIOS says which build it runs. The --pcd string
# values carry no quotes: the shell strips debian/rules' and build.py adds its own. Output in
# $OVMF_WORK/ovmf-builds/. See README.txt here for the whole procedure.
set -u
tree="$1" tag="$2"
S="${OVMF_WORK:?set OVMF_WORK to the directory holding edk2-ubuntu-src/}"
out=$S/ovmf-builds; mkdir -p "$out"
cd "$tree" || exit 1
unset WORKSPACE ECP_SOURCE EDK_SOURCE EFI_SOURCE EDK_TOOLS_PATH CONF_PATH MAKEFLAGS ELF_PACKAGE_METADATA
export PYTHON3_ENABLE=TRUE PYTHON_COMMAND=python3
t0=$(date +%s)
# edksetup.sh is not written for set -u (PYTHON_COMMAND, and more, may be unbound),
# and a sourced script sees this script's positional parameters, so clear them first
# (it printed its usage for "<tree> <tag>" and returned 1).
set +u; set --; . ./edksetup.sh > "$out/$tag-edksetup.log" 2>&1; rc=$?; set -u
[[ $rc -eq 0 ]] || { echo "$tag: edksetup rc=$rc"; cat "$out/$tag-edksetup.log"; exit 1; }
make -C BaseTools ARCH=X64 -j8 > "$out/$tag-basetools.log" 2>&1; rc=$?
echo "$tag: BaseTools rc=$rc after $(( $(date +%s) - t0 )) s"
[[ $rc -eq 0 ]] || exit 1
build -a X64 -t GCC5 -p OvmfPkg/OvmfPkgX64.dsc -b RELEASE -n 14 \
  -DCC_MEASUREMENT_ENABLE=TRUE -DNETWORK_HTTP_BOOT_ENABLE=TRUE -DNETWORK_IP6_ENABLE=TRUE -DNETWORK_TLS_ENABLE \
  --pcd 'PcdFirmwareVendor=LUbuntu distribution of EDK II\0' \
  --pcd "PcdFirmwareVersionString=L2025.11-3ubuntu7.3~pdt-$tag\\0" \
  --pcd 'PcdFirmwareReleaseDateString=L10/27/2026\0' \
  -DTPM2_ENABLE=TRUE -DFD_SIZE_4MB -DBUILD_SHELL=FALSE -DSECURE_BOOT_ENABLE=TRUE -DSMM_REQUIRE=TRUE \
  > "$out/$tag-build.log" 2>&1; rc=$?
echo "$tag: build rc=$rc after $(( $(date +%s) - t0 )) s"
[[ $rc -eq 0 ]] || { tail -30 "$out/$tag-build.log"; exit 1; }
cp Build/OvmfX64/RELEASE_GCC5/FV/OVMF_CODE.fd "$out/OVMF_CODE_4M.secboot.$tag.fd"
cp Build/OvmfX64/RELEASE_GCC5/FV/OVMF_VARS.fd "$out/OVMF_VARS_4M.$tag.fd"
ls -la "$out/OVMF_CODE_4M.secboot.$tag.fd"; sha256sum "$out/OVMF_CODE_4M.secboot.$tag.fd"
strings -el "$out/OVMF_CODE_4M.secboot.$tag.fd" | grep -E 'pdt-' | head -2
