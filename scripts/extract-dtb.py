#!/usr/bin/env python3
"""Extract the device tree blob from an Android boot image.

The Samsung bootloader only accepts a boot.img whose dtb section is the
*Android* device tree (from the stock or LineageOS boot image).  A mainline
DTB there makes sboot fall back to Download mode, which is why uniLoader must
carry the mainline DTB internally instead.

Usage:
  extract-dtb.py lineage-boot.img out/android.dtb
"""
import struct
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as f:
        data = f.read()
    magic, ks, _kaddr, rs, _raddr, ss, _saddr, _tags, page, hv, _osv = \
        struct.unpack("<8s10I", data[:48])
    if magic != b"ANDROID!":
        print("not an Android boot image", file=sys.stderr)
        return 1
    dtb_size = struct.unpack("<I", data[1648:1652])[0]
    if hv < 2 or dtb_size == 0:
        print("no dtb section in this image", file=sys.stderr)
        return 1

    def pad(x):
        return (x + page - 1) // page * page

    off = page + pad(ks) + pad(rs) + pad(ss)
    dtb = data[off:off + dtb_size]
    with open(dst, "wb") as f:
        f.write(dtb)
    print(f"{dst}: {dtb_size} bytes from {src} (page {page}, offset {off})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
