#!/usr/bin/env python3
"""Fixtures Android boot v0-v4 pour J3/J4 (aucun appareil)."""

import argparse
import os
import struct
import sys


def pad(data, page):
    return data + b"\0" * ((page - len(data) % page) % page)


def make(version, page=4096, kernel_size=300, ramdisk_size=200, dtb_size=64,
         avb=False, cmdline=b"console=ttyMSM0,115200n8"):
    kernel = (b"KERNEL" + bytes(kernel_size))[:kernel_size]
    ramdisk = (b"RAMDISK" + bytes(ramdisk_size))[:ramdisk_size]
    dtb = (b"\xd0\x0d\xfe\xed" + bytes(dtb_size))[:dtb_size]
    cmd = cmdline[:511].ljust(512, b"\0")
    extra = b"\0" * 1024
    name = b"a71".ljust(16, b"\0")
    if version in (0, 1, 2):
        base = struct.pack(
            "<8s10I16s512s32s1024s",
            b"ANDROID!", kernel_size, 0x8000, ramdisk_size, 0x1000000,
            0, 0, 0x100, page, version, 0x1e000000, name, cmd,
            b"\0" * 32, extra,
        )
        if version >= 1:
            base += struct.pack("<IQI", 0, 0, 1660)
        if version >= 2:
            base += struct.pack("<IQ", dtb_size, 0x1f00000)
        header = pad(base, page)
        body = pad(kernel, page) + pad(ramdisk, page)
        if version >= 2:
            body += pad(dtb, page)
    else:
        header_size = 1580 if version == 3 else 1584
        header = struct.pack(
            "<8sIIII4I I1536s",
            b"ANDROID!", kernel_size, ramdisk_size, 0x1e000000,
            header_size, 0, 0, 0, 0, version, cmdline[:1536].ljust(1536, b"\0"),
        )
        if version == 4:
            header += struct.pack("<I", 0)
        header = pad(header, page)
        body = pad(kernel, page) + pad(ramdisk, page)
    image = header + body
    if avb:
        footer = bytearray(64)
        footer[0:4] = b"AVB0"
        struct.pack_into("<I", footer, 4, 1)
        struct.pack_into("<I", footer, 8, 0)
        struct.pack_into("<Q", footer, 12, len(image))
        struct.pack_into("<Q", footer, 20, 0)
        struct.pack_into("<Q", footer, 28, 0)
        image += bytes(footer)
    return image


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--version", type=int, required=True, choices=range(0, 5))
    p.add_argument("--page", type=int, default=4096)
    p.add_argument("--avb", action="store_true")
    args = p.parse_args()
    data = make(args.version, args.page, avb=args.avb)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "wb") as fh:
        fh.write(data)
    print("%s version=%d size=%d" % (args.out, args.version, len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
