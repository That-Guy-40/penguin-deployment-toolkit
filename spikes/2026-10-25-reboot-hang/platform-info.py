#!/usr/bin/env python3
"""platform-info.py <dump.bin> <dump-base-hex> [healthy-words.out]

What PlatformPei left in a dumped firmware memory (hang-record.sh's 80 MB
bsp dump): every PlatformInfoHob (gUefiOvmfPkgPlatformInfoGuid) as non-zero
8-byte words, the way layout/hob-list-healthy.out lists the healthy boot's,
with the fields that matter decoded; every fw_cfg cache HOB
(gOvmfFwCfgInfoHobGuid) with its item and size, the cached etc/e820 entries
decoded and the cached file directory as a key -> name map. Given the healthy
reference, prints which words differ. Offsets are those of the 2025.11 layout
(HOB length 0xc0, the struct is byte-packed): FirstNonAddress at +0x30,
PhysMemAddressWidth +0x38, Uc32Base/Size +0x39/+0x3d, PcdPciMmio64Base +0x4a,
its size +0x52, boot/max/default CPU count +0x7b/+0x7f/+0x83, QemuFwCfgChecked
+0x98 and the fw_cfg work area (supported, DMA, item, offset, reading) +0x99."""
import re
import struct
import sys
import uuid

PLATFORM_INFO = uuid.UUID("dec9b486-1f16-47c7-8f68-df1a41888ba5").bytes_le
FW_CFG_INFO = uuid.UUID("a291ce0e-dc09-11ee-9edb-7349d792af51").bytes_le


def guid_hobs(buf, guid):
    i = 0
    while True:
        i = buf.find(guid, i)
        if i < 0:
            return
        kind, length = struct.unpack_from("<HH", buf, i - 8)
        if kind == 4 and 24 <= length < 0x10000:
            yield i - 8, length
        i += 1


def words(buf, off, length):
    out = {}
    for i in range(0, length - 24, 8):
        v = struct.unpack_from("<Q", buf, off + 24 + i)[0]
        if v:
            out[i] = v
    return out


def main():
    buf = open(sys.argv[1], "rb").read()
    base = int(sys.argv[2], 16)
    healthy = {}
    if len(sys.argv) > 3:
        for m in re.finditer(r"\+0x([0-9a-f]+): 0x([0-9a-f]{16})", open(sys.argv[3]).read()):
            healthy[int(m.group(1), 16)] = int(m.group(2), 16)
    for off, length in guid_hobs(buf, PLATFORM_INFO):
        d = off + 24
        print(f"PlatformInfoHob at 0x{base + off:x}, HOB length 0x{length:x}; non-zero 8-byte words:")
        w = words(buf, off, length)
        for i, v in sorted(w.items()):
            mark = ""
            if healthy:
                mark = "   (healthy: 0x%016x)" % healthy[i] if healthy.get(i) != v else ""
            print(f"   +0x{i:03x}: 0x{v:016x}{mark}")
        u = lambda fmt, o: struct.unpack_from("<" + fmt, buf, d + o)[0]
        print(f"   FirstNonAddress 0x{u('Q', 0x30):x}  PhysMemAddressWidth {u('B', 0x38)}  Uc32Base 0x{u('I', 0x39):x} Uc32Size 0x{u('I', 0x3d):x}")
        print(f"   PcdPciMmio64Base 0x{u('Q', 0x4a):x}  PcdPciMmio64Size 0x{u('Q', 0x52):x}")
        print(f"   PcdCpuBootLogicalProcessorNumber {u('I', 0x7b)}  PcdCpuMaxLogicalProcessorNumber {u('I', 0x7f)}  DefaultMaxCpuNumber {u('I', 0x83)}")
        print(f"   QemuFwCfgChecked {u('B', 0x98)}  work area: supported {u('B', 0x99)} dma {u('B', 0x9a)} item 0x{u('H', 0x9b):04x} offset {u('I', 0x9d)} reading {u('B', 0xa1)}")
        if healthy:
            diff = [i for i in set(w) | set(healthy) if w.get(i) != healthy.get(i)]
            print("   differs from the healthy reference at:", ", ".join("+0x%03x" % i for i in sorted(diff)) or "nothing")
    for off, length in guid_hobs(buf, FW_CFG_INFO):
        d = off + 24
        item, size = struct.unpack_from("<HI", buf, d)
        print(f"fw_cfg cache HOB at 0x{base + off:x}: item 0x{item:04x}, {size} bytes")
        data = buf[d + 6:d + 6 + size]
        if item == 0x19 and size >= 4:
            n = struct.unpack_from(">I", data, 0)[0]
            for k in range(min(n, (size - 4) // 64)):
                sz, sel = struct.unpack_from(">IH", data, 4 + k * 64)
                name = data[4 + k * 64 + 8:4 + k * 64 + 64].split(b"\0")[0].decode(errors="replace")
                print(f"   0x{sel:04x} {sz:8d} {name}")
        elif size % 20 == 0 and size and any(struct.unpack_from("<I", data, k * 20 + 16)[0] in (1, 2, 3, 4) for k in range(size // 20)):
            for k in range(size // 20):
                a, ln, t = struct.unpack_from("<QQI", data, k * 20)
                print(f"   e820[{k}] base 0x{a:x} len 0x{ln:x} type {t}")


if __name__ == "__main__":
    main()
