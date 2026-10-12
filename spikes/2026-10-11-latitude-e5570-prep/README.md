# 2026-10-11: preparing for the first physical machine (Dell Latitude E5570)

The machine arrives next week: Dell Latitude E5570, service tag 425JZF2, a
2016 Skylake laptop, UEFI-capable, Secure Boot not enforcing. The LAN's DHCP
is a consumer four-port router. Nothing here is verified against the
machine yet; everything below is **[read]** from vendor pages or prepared
on the host, and is what the first boot will test.

## Done on the host

- **Driver pack.** Dell publishes a Windows 10 pack for this model (A18,
  2020; no Windows 11 pack exists: Dell's KB 000109893 says "Not
  Applicable"). `bin/fetch-drivers` (new) downloaded
  `E5570-Win10-A18-441JC.CAB` from `dl.dell.com` (912 MB; the host answers
  403 without a browser User-Agent), SHA-256
  `8f5af0fe82d566513e8b673344fa1e2a9dc94b1498bc0fb2da824659aca7a426`
  (not published by Dell; pinned here from the first download), unpacked it
  with `cabextract` and packed it as `http/drivers/latitude-e5570.wim`
  (116 `.inf`, 897 MB: audio, chipset, communication, docks, input, network,
  security, storage, video). Windows 10 drivers on 24H2: DISM will add them;
  which ones Windows actually binds, against its own inbox ones, the
  machine will say.
- **Model file.** `http/models/latitude-e5570.cfg` with
  `DRIVERS=latitude-e5570`. The slug is computed from Dell's SMBIOS product
  string "Latitude E5570" by the same rule as `ts/slug.js`; the machine's
  `ts-start` event (`model=`) confirms it.
- `bin/lint`: all PASS with the pack and model file in place.

## What the first boot will tell us, in order

1. Firmware setup: UEFI boot mode, "UEFI Network Stack" / PXE on, legacy
   ROMs off. The I219-LM NIC is driven by WinPE's inbox e1000e-class driver,
   so no WinPE-side injection (`winpe-drivers/`) should be needed.
2. `bin/pxe-lan start` (proxy mode) beside the router: the firmware must
   take our proxy offer (`ipxe.efi` over TFTP) while the router hands out
   the address. Verified in `lab-netns`, never on a real switch. If the
   firmware times out: `pxe-lan`'s `--log-dhcp` output and the router's
   lease table.
3. `bin/status` shows the machine as `shell` with its UUID, `product=Latitude
   E5570`, `model=latitude-e5570`, `nic=<I219 pci id>`, `chip=SNP`
   (firmware path). Nothing is written: no `machines/<uuid>.cfg` yet.
4. Create `machines/<uuid>.cfg` (`MODE=deploy`, `ROLE=` as wanted), reboot:
   full deploy. `40-drivers` adds the pack; first logon reports WinRE and
   the role. Measure PXE → `deployed`.
5. `boot ok trigger=…` after a power cycle, like the VMs.

## Open until then

- Whether the firmware's PXE client accepts a proxy-DHCP offer at all (some
  consumer-era firmware wants `next-server` from the real DHCP server).
- Whether the Win10 pack's storage driver (Intel RST) is needed for the
  SATA/NVMe controller or the inbox one suffices.
- LAN throughput of the 3.4 GB image (PLAN §5 q4).
