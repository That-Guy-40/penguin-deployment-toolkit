#!/usr/bin/env python3
"""spikes/2026-10-25-reboot-hang/find-module.py and pcd-db.py: on synthetic dumps built
from the repo's own evidence (a real PE image from layout/), with RIPs inside and
outside, and a hand-built PCD database."""
import os
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import pylib as t

SPIKE = os.path.join(t.REPO, "spikes", "2026-10-25-reboot-hang")
FM = os.path.join(SPIKE, "find-module.py")
PCD = os.path.join(SPIKE, "pcd-db.py")
IMG = os.path.join(SPIKE, "layout", "PciHostBridgeDxe-7ad0f000.img")   # a real DXE driver, 17600 bytes
W = tempfile.mkdtemp(prefix="pdt-tests.")


def run(*args):
    r = subprocess.run([sys.executable, "-I", *args], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


try:
    pe = open(IMG, "rb").read()
    t.chk_true("fixture: the layout image starts with MZ", pe[:2] == b"MZ", repr(pe[:2]))
    # a dump: 4 KB of noise, the image at +0x1000, noise after; loaded at 0x7ad0e000
    dump = os.path.join(W, "dump.bin")
    with open(dump, "wb") as f:
        f.write(b"\x11" * 0x1000 + pe + b"\x22" * 0x3000)
    base = 0x7AD0E000
    img_at = base + 0x1000
    rc, out = run(FM, dump, f"{base:x}", f"{img_at + 0x386b:x}")
    t.chk("one PE image found in the dump", True, "1 PE images in" in out)
    t.chk_true("listed at the address it sits at", f"{img_at:#x}..{img_at + len(pe):#x}" in out, out[:400])
    t.chk_true("the RIP is placed in it with its image offset 0x386b", f"RIP {img_at + 0x386b:#x}: in" in out and "offset 0x386b" in out, out[-300:])
    t.chk("exit 0 when every RIP was placed", 0, rc)
    rc, out = run(FM, dump, f"{base:x}", f"{img_at + 0x386b:x}", f"{base + 0x10:x}")
    if rc == 1 and "in no PE image of this dump" in out:
        t.control("a RIP outside every image: 'in no PE image' and exit 1")
    else:
        t.fail("a RIP outside every image", f"rc {rc}: {out[-300:]}")
    # the image size must come from the PE header, not the file: pad the file and check the end
    rc, out = run(FM, dump, f"{base:x}", f"{img_at + len(pe) - 1:x}")
    t.chk("the last byte of the image is inside it (size from the PE header)", 0, rc)
    rc, out = run(FM, dump, f"{base:x}", f"{img_at + len(pe):x}")
    t.chk("the byte after the image is outside it", 1, rc)
    # corrupt the PE signature: the image must vanish from the listing (what the MZ scan guards against)
    bad = bytearray(b"\x11" * 0x1000 + pe)
    e_lfanew = struct.unpack_from("<I", pe, 0x3C)[0]
    bad[0x1000 + e_lfanew:0x1000 + e_lfanew + 4] = b"XXXX"
    with open(os.path.join(W, "bad.bin"), "wb") as f:
        f.write(bad)
    rc, out = run(FM, os.path.join(W, "bad.bin"), f"{base:x}", f"{img_at + 0x10:x}")
    if "0 PE images" in out and rc == 1:
        t.control("an MZ without a PE\\0\\0 signature is not an image (0 found, RIP unplaced)")
    else:
        t.fail("corrupt PE signature control", out[:300])
    rc, out = run(FM)
    t.chk("no arguments: usage and exit 2", 2, rc)

    # --extract-fv + --fv naming on the installed OVMF, if present (host-dependent)
    code = "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd"
    if os.path.isfile(code):
        fv = os.path.join(W, "dxe.fv")
        rc, out = run(FM, "--extract-fv", code, fv)
        t.chk("--extract-fv decompresses the LZMA volume(s) and exits 0", 0, rc)
        t.chk_true("and names at least 50 PE images from their FFS UI sections", any(int(w) >= 50 for w in out.split() if w.isdigit()), out[:200])
        rc, out = run(FM, "--fv", fv, dump, f"{base:x}", f"{img_at + 0x386b:x}")
        if "PciHostBridgeDxe" in out:
            t.pass_("--fv names the dumped image PciHostBridgeDxe from the firmware volume (header fingerprint)")
        else:
            t.unknown("--fv names the dumped image", "the installed OVMF is not the 2025.11 build the fixture came from, or no match: " + out[:200])
    else:
        t.unknown("--extract-fv / --fv on the installed OVMF", f"{code} not present")

    # pcd-db.py on a hand-built PCD database (header v7), tokens 0x11 and 0x12 as UINT32
    import uuid
    guid = uuid.UUID("3c7d193c-682c-4c14-a68f-552dea4f437e").bytes_le
    lcount = 0x14
    ltn_off = 0x100            # local token number table at db+0x100
    data_off = 0x200           # UINT32 values live at db+0x200 + 4*token
    length = 0x400
    hdr = struct.pack("<IIQIIIIIIIIIHHHH", 7, length, 0, 0, 0x40, ltn_off, 0, 0, 0, 0, 0, 0, lcount, 0, 0, 0)
    db = bytearray(b"\0" * (length + 0x40))
    db[0:16] = guid
    db[16:16 + len(hdr)] = hdr
    for tok in range(1, lcount + 1):
        voff = data_off + 4 * tok
        entry = voff | (4 << 24)   # plain data (ptype 0), UINT32 (dtype 4)
        struct.pack_into("<I", db, ltn_off + 4 * (tok - 1), entry)
        struct.pack_into("<I", db, voff, {0x11: 32, 0x12: 64}.get(tok, 7))
    pdb_path = os.path.join(W, "pcd.bin")
    with open(pdb_path, "wb") as f:
        f.write(b"\xaa" * 0x80 + db)
    rc, out = run(PCD, pdb_path, "77f7e000")
    t.chk("pcd-db.py exits 0", 0, rc)
    t.chk_true("finds the database at base + 0x80 with version 7 and 20 local tokens", "database @0x77f7e080: version 7" in out and "20 local tokens" in out, out[:300])
    t.chk_true("token 0x11 = 32 (the hung boot's CPU count) is printed", "token 0x11: u32 at db+0x244 (initialised) = 32" in out, out)
    t.chk_true("token 0x12 = 64 is printed", "token 0x12: u32 at db+0x248 (initialised) = 64" in out, out)
    t.chk_true("token 0x10 is printed too (the three around 0x11 always are), with its value 7", "token 0x10: u32 at db+0x240 (initialised) = 7" in out, out)
    t.chk_true("a token outside 0x10..0x12 with an unremarkable value (0x5 = 7) is not printed", "token 0x5:" not in out, out)
    with open(os.path.join(W, "noguid.bin"), "wb") as f:
        f.write(b"\xaa" * 0x400)
    rc, out = run(PCD, os.path.join(W, "noguid.bin"), "0")
    if rc == 0 and "database @" not in out:
        t.control("a blob without the PCD database GUID yields no database")
    else:
        t.fail("no-GUID control", out[:200])
finally:
    import shutil
    shutil.rmtree(W, ignore_errors=True)
t.finish()
