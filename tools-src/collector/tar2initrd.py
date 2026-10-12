#!/usr/bin/env python3
"""tar2initrd.py <rootfs.tar> <out-dir> - turn mmdebstrap's tar into the collector's
boot files: out-dir/vmlinuz (the kernel out of /boot) and out-dir/initrd.img
(every other file as a newc cpio, zstd-compressed), keeping owners, modes,
links and devices exactly as the tar has them. Pure Python: no root, no
loop devices, no files extracted onto the host.
"""
import os
import stat
import subprocess
import sys
import tarfile

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)

def cpio_header(name, mode, uid, gid, nlink, mtime, size, dev=(0, 0), rdev=(0, 0), ino=0):
    nameb = name.encode("utf-8")          # sized in BYTES: Debian ships non-ASCII file names
    namesz = len(nameb) + 1
    fields = (ino, mode, uid, gid, nlink, int(mtime), size, dev[0], dev[1], rdev[0], rdev[1], namesz, 0)
    hdr = b"070701" + "".join(f"{f:08x}" for f in fields).encode() + nameb + b"\0"
    return hdr + b"\0" * ((4 - len(hdr) % 4) % 4)

def padded(data):
    return data + b"\0" * ((4 - len(data) % 4) % 4)

kernel = None
zstd = subprocess.Popen(["zstd", "-T0", "-19", "-q", "-f", "-o", os.path.join(out, "initrd.img.part")], stdin=subprocess.PIPE)
w = zstd.stdin
ino = 1
seen = set()
hardlinks = {}
with tarfile.open(src, "r|*") as tf:          # streaming: the tar is never held in memory
    for m in tf:
        name = m.name.lstrip("./").rstrip("/")
        if not name:
            continue
        if name.startswith("boot/vmlinuz-") and m.isfile():
            kernel = tf.extractfile(m).read()
            continue
        if name.startswith("boot/") or name.startswith("tmp/"):
            continue
        if name in seen:
            continue
        seen.add(name)
        ino += 1
        if m.isdir():
            w.write(cpio_header(name, stat.S_IFDIR | m.mode, m.uid, m.gid, 2, m.mtime, 0, ino=ino))
        elif m.issym():
            target = m.linkname.encode()
            w.write(cpio_header(name, stat.S_IFLNK | 0o777, m.uid, m.gid, 1, m.mtime, len(target), ino=ino))
            w.write(padded(target))
        elif m.isfile() or m.islnk():
            data = tf.extractfile(m).read() if m.isfile() else b""
            if m.islnk():   # hard link: emit as a copy of its target (seen earlier in the stream)
                data = hardlinks.get(m.linkname.lstrip("./"), b"")
            else:
                pass
            if m.isfile():
                hardlinks[name] = data if len(data) < (1 << 20) else b""
            w.write(cpio_header(name, stat.S_IFREG | m.mode, m.uid, m.gid, 1, m.mtime, len(data), ino=ino))
            w.write(padded(data))
        elif m.ischr() or m.isblk():
            kind = stat.S_IFCHR if m.ischr() else stat.S_IFBLK
            w.write(cpio_header(name, kind | m.mode, m.uid, m.gid, 1, m.mtime, 0, rdev=(m.devmajor, m.devminor), ino=ino))
        elif m.isfifo():
            w.write(cpio_header(name, stat.S_IFIFO | m.mode, m.uid, m.gid, 1, m.mtime, 0, ino=ino))
w.write(cpio_header("TRAILER!!!", 0, 0, 0, 1, 0, 0))
w.close()
if zstd.wait() != 0:
    sys.exit("zstd failed")
if not kernel:
    sys.exit("no /boot/vmlinuz-* in the tar")
with open(os.path.join(out, "vmlinuz.part"), "wb") as f:
    f.write(kernel)
os.rename(os.path.join(out, "vmlinuz.part"), os.path.join(out, "vmlinuz"))
os.rename(os.path.join(out, "initrd.img.part"), os.path.join(out, "initrd.img"))
print(f"vmlinuz {len(kernel)} bytes, initrd.img {os.path.getsize(os.path.join(out, 'initrd.img'))} bytes, {len(seen)} entries")
