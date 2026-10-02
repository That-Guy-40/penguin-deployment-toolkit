# winpe-drivers/ - drivers Windows PE itself needs

Stock WinPE drives most NICs and disks with inbox drivers. For hardware it has
none for (virtio is the lab example), the drivers have to be present in WinPE
*before* it can reach the server. They get there the same way everything else
does: wimboot injects them.

`boot.ipxe` asks for two snippets and ignores a 404:

```
winpe-drivers/${netX/busid}.ipxe           the NIC's PCI id, e.g. 01:1a:f4:10:00.ipxe = PCI 1af4:1000
winpe-drivers/model-${product}.ipxe        the SMBIOS product name, e.g. "model-Latitude 5440.ipxe"
```

A snippet is a short iPXE script whose paths are relative to this directory:

```
#!ipxe
initrd --name netkvm.inf virtio/netkvm.inf || exit 1
initrd --name netkvm.sys virtio/netkvm.sys || exit 1
...                                              every file the .inf names
initrd --name pdt-drvload.txt virtio/pdt-drvload.txt || exit 1
```

`pdt-drvload.txt` lists the `.inf` files, one per line; `ts/deploy.cmd` runs
`drvload` on each before starting the network. Inject **every** file of the
driver: `drvload` fails with "file not found" if anything the `.inf` names is
missing. `bin/lint` checks that every file a snippet injects exists.

`bin/fetch-tools virtio` generates the virtio snippets and files here. The
installed system needs the drivers too: that is a driver pack
(`http/drivers/<name>.wim`, `DRIVERS=` in a cfg), a separate thing.

The key is the PCI id and not iPXE's chip name because, started by the
firmware's own PXE stack as on real hardware, iPXE drives the NIC through the
firmware and calls every chip `SNP`.

Everything here except this file is generated or site-specific and not tracked
by git.
