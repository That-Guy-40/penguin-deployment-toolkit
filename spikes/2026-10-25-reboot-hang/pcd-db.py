#!/usr/bin/env python3
"""pcd-db.py <dump-or-volume.bin> <base-hex> [...]: find every PEI/DXE PCD database
(gPcdDataBaseSignatureGuid) in a memory dump or a decompressed firmware volume and
print the UINT32 dynamic PCDs around token 0x11, so that the token number CpuMpPei
passes to PcdGet32 can be named: in the PEI database of this OVMF build token 0x11
defaults to 0 (PcdCpuBootLogicalProcessorNumber|0 in OvmfPkgX64.dsc) and 0x12 to 64
(PcdCpuMaxLogicalProcessorNumber|64); a healthy boot sets both to 4.
PCD_DATABASE_HEADER version 7 (MdeModulePkg/Include/Guid/PcdDataBaseSignatureGuid.h)."""
import struct, sys, uuid
GUID = uuid.UUID("3c7d193c-682c-4c14-a68f-552dea4f437e").bytes_le
args = sys.argv[1:]
for i in range(0, len(args), 2):
    path, base = args[i], int(args[i + 1], 16)
    buf = open(path, "rb").read()
    print(f"== {path} @ {base:#x}")
    off = 0
    while (h := buf.find(GUID, off)) >= 0:
        off = h + 1
        (ver, length, _sku, _lall, uninit, ltn, _exm, _gt, _st, _sz, _skt, _nt,
         lcount, excount, gcount, _pad) = struct.unpack_from("<IIQIIIIIIIIIHHHH", buf, h + 16)
        print(f" database @{base + h:#x}: version {ver}, {length} bytes (+{uninit} uninitialised), {lcount} local tokens, {excount} ex, {gcount} guids")
        toks = struct.unpack_from(f"<{lcount}I", buf, h + ltn)
        for t in range(1, lcount + 1):
            e = toks[t - 1]
            voff, dtype, ptype = e & 0x000FFFFF, (e >> 24) & 0xF, e >> 28
            if ptype == 0 and dtype == 4:  # plain data, UINT32
                v = struct.unpack_from("<I", buf, h + voff)[0]
                if t in (0x10, 0x11, 0x12) or v in (4, 32, 64):
                    where = "uninitialised area" if voff >= length else "initialised"
                    print(f"   token {t:#x}: u32 at db+{voff:#x} ({where}) = {v}")
