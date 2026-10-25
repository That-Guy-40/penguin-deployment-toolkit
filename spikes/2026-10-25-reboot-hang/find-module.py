#!/usr/bin/env python3
"""find-module.py - which firmware image is a hung CPU executing?

  find-module.py [--fv <volume.bin>] <dump.bin> <dump-base-hex> <rip-hex> [more-rip-hex...]
  find-module.py --extract-fv <OVMF_CODE.fd> <volume.bin>

The dump is guest-physical memory saved by QEMU (pmemsave), loaded at
<dump-base>. Every PE/COFF image in it (MZ ... PE\\0\\0) is listed with its
load address, size, the .pdb path from its debug directory (edk2 RELEASE
builds keep it, so the module is named) and, for each RIP given, the image
that contains it with the RIP's offset into the image (objdump the matching
.efi at that offset). Exit 0 when every RIP was placed, 1 otherwise.

Ubuntu's OVMF is built without .pdb paths, so --fv names the images another
way: <volume.bin> is the firmware's DXE volume (--extract-fv decompresses the
LZMA section of OVMF_CODE*.fd into one), whose FFS files carry each module's
name as a UCS-2 UI section next to its PE32 section. An image in memory is
matched to an FFS file by its PE header (timestamp, entry point, size, section
table), which relocation does not change.
"""
import re
import struct
import sys


def images(buf, base):
    out = []
    for m in re.finditer(rb"MZ", buf):
        off = m.start()
        if off + 0x40 > len(buf):
            continue
        e_lfanew = struct.unpack_from("<I", buf, off + 0x3C)[0]
        pe = off + e_lfanew
        if e_lfanew > 0x400 or pe + 0x18 > len(buf) or buf[pe:pe + 4] != b"PE\0\0":
            continue
        machine, nsec = struct.unpack_from("<HH", buf, pe + 4)
        opt = pe + 0x18
        magic = struct.unpack_from("<H", buf, opt)[0]
        if magic == 0x20B:  # PE32+
            entry = struct.unpack_from("<I", buf, opt + 0x10)[0]
            imgbase = struct.unpack_from("<Q", buf, opt + 0x18)[0]
            size = struct.unpack_from("<I", buf, opt + 0x38)[0]
            ndd = struct.unpack_from("<I", buf, opt + 0x6C)[0]
            dd = opt + 0x70
        elif magic == 0x10B:
            entry = struct.unpack_from("<I", buf, opt + 0x10)[0]
            imgbase = struct.unpack_from("<I", buf, opt + 0x1C)[0]
            size = struct.unpack_from("<I", buf, opt + 0x38)[0]
            ndd = struct.unpack_from("<I", buf, opt + 0x5C)[0]
            dd = opt + 0x60
        else:
            continue
        if not (0x1000 <= size <= 0x4000000):
            continue
        pdb = ""
        if ndd > 6:
            dbg_rva, dbg_size = struct.unpack_from("<II", buf, dd + 6 * 8)
            if dbg_rva and off + dbg_rva + 28 <= len(buf):
                # one or more IMAGE_DEBUG_DIRECTORY entries of 28 bytes
                for k in range(dbg_size // 28):
                    e = off + dbg_rva + k * 28
                    typ, _sz, _rva, ptr = struct.unpack_from("<I", buf, e + 12)[0], *struct.unpack_from("<III", buf, e + 16)
                    rva = struct.unpack_from("<I", buf, e + 20)[0]
                    if typ == 2 and off + rva + 24 <= len(buf):  # CODEVIEW
                        cv = off + rva
                        if buf[cv:cv + 4] == b"RSDS":
                            s = buf[cv + 24:cv + 24 + 260]
                            pdb = s.split(b"\0", 1)[0].decode("latin-1")
                        elif buf[cv:cv + 4] == b"NB10":
                            s = buf[cv + 16:cv + 16 + 260]
                            pdb = s.split(b"\0", 1)[0].decode("latin-1")
        out.append(dict(addr=base + off, size=size, entry=entry, imgbase=imgbase, pdb=pdb, machine=machine, fp=fingerprint(buf, off)))
    return out


def fingerprint(buf, off):
    """The PE header bits relocation leaves alone, as a tuple, or None."""
    try:
        e_lfanew = struct.unpack_from("<I", buf, off + 0x3C)[0]
        pe = off + e_lfanew
        if buf[pe:pe + 4] != b"PE\0\0":
            return None
        machine, nsec, stamp = struct.unpack_from("<HHI", buf, pe + 4)
        optsize = struct.unpack_from("<H", buf, pe + 0x14)[0]
        opt = pe + 0x18
        entry = struct.unpack_from("<I", buf, opt + 0x10)[0]
        size = struct.unpack_from("<I", buf, opt + 0x38)[0]
        sects = buf[opt + optsize:opt + optsize + 40 * nsec]
        return (machine, nsec, stamp, entry, size, bytes(sects))
    except struct.error:
        return None


def ffs_images(fv):
    """FFS files of a firmware volume: {fingerprint: name} for each PE32/TE section."""
    names = {}
    # Firmware volume header: signature _FVH at 0x28, header length at 0x30
    pos = 0
    while True:
        i = fv.find(b"_FVH", pos)
        if i < 0:
            break
        fvh = i - 0x28
        hdrlen = struct.unpack_from("<H", fv, fvh + 0x30)[0]
        fvlen = struct.unpack_from("<Q", fv, fvh + 0x20)[0]
        p = fvh + hdrlen
        end = min(fvh + fvlen, len(fv))
        while p + 24 <= end:
            ftype = fv[p + 18]
            fsize = int.from_bytes(fv[p + 20:p + 23], "little")
            if ftype == 0xFF or fsize == 0:  # padding to the end of the volume
                break
            if fv[p + 23] & 0x01 == 0 and fsize >= 24:
                sp = p + 24
                name = None
                pes = []
                while sp + 4 <= p + fsize:
                    ssize = int.from_bytes(fv[sp:sp + 3], "little")
                    stype = fv[sp + 3]
                    if ssize < 4:
                        break
                    if stype == 0x15:  # user interface
                        name = fv[sp + 4:sp + ssize].decode("utf-16le", "replace").rstrip("\0")
                    elif stype in (0x10, 0x12):  # PE32, TE
                        pes.append(sp + 4)
                    sp += (ssize + 3) & ~3
                for pe in pes:
                    fp = fingerprint(fv, pe) if fv[pe:pe + 2] == b"MZ" else None
                    if fp and name:
                        names[fp] = name
            p += (fsize + 7) & ~7
        pos = i + 4
    return names


def extract_fv(code, out):
    import lzma, uuid
    buf = open(code, "rb").read()
    g = uuid.UUID("EE4E5898-3914-4259-9D6E-DC7BD79403CF").bytes_le  # LZMA GUIDed section
    total = b""
    for m in re.finditer(re.escape(g), buf):
        sec = m.start() - 4
        size = struct.unpack_from("<I", buf, sec)[0] & 0xFFFFFF
        data_off = struct.unpack_from("<H", buf, m.start() + 16)[0]
        try:
            total += lzma.decompress(buf[sec + data_off:sec + size], format=lzma.FORMAT_ALONE)
        except lzma.LZMAError as e:
            print(f"section at {sec:#x}: {e} (skipped)", file=sys.stderr)
    open(out, "wb").write(total)
    print(f"{out}: {len(total)} bytes, {len(ffs_images(total))} named PE images")


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--extract-fv":
        return extract_fv(sys.argv[2], sys.argv[3])
    names = {}
    if len(sys.argv) > 2 and sys.argv[1] == "--fv":
        names = ffs_images(open(sys.argv[2], "rb").read())
        del sys.argv[1:3]
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    buf = open(sys.argv[1], "rb").read()
    base = int(sys.argv[2], 16)
    rips = [int(x, 16) for x in sys.argv[3:]]
    imgs = images(buf, base)
    print(f"{len(imgs)} PE images in {sys.argv[1]} ({len(buf)} bytes at {base:#x}):")
    for im in imgs:
        im["name"] = im["pdb"].replace("\\", "/").rsplit("/", 1)[-1] or names.get(im["fp"]) or "(unnamed)"
    for im in imgs:
        name = im["name"]
        reloc = "" if im["imgbase"] == im["addr"] else f"  (header says ImageBase {im['imgbase']:#x})"
        print(f"  {im['addr']:#x}..{im['addr'] + im['size']:#x}  {im['size']:>8}  {name}{reloc}")
    rc = 0
    for rip in rips:
        hit = [im for im in imgs if im["addr"] <= rip < im["addr"] + im["size"]]
        if hit:
            im = hit[0]
            name = im["name"]
            print(f"RIP {rip:#x}: in {name} at image offset {rip - im['addr']:#x} (image at {im['addr']:#x})")
        else:
            print(f"RIP {rip:#x}: in no PE image of this dump")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
