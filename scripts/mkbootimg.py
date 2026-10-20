#!/usr/bin/env python3
"""Minimal Android boot image (header v0/v2) assembler.

Usage:
  mkbootimg.py --kernel Image --ramdisk initrd.gz --dtb board.dtb \
               --output boot.img [--header-version 2] [--cmdline "..."] \
               [--seandroid]

The Galaxy A71 bootloader (like most Qualcomm Samsung devices) expects the
AOSP boot image layout: a 2048-byte page containing the header, followed by
the page-aligned kernel, ramdisk, (recovery_dtbo), dtb.
"""
import argparse
import hashlib
import struct
import sys

def pad(data: bytes, page: int) -> bytes:
    rem = len(data) % page
    return data + b"\0" * ((page - rem) % page)


def load(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def build(args) -> bytes:
    kernel = load(args.kernel)
    ramdisk = load(args.ramdisk) if args.ramdisk else b""
    dtb = load(args.dtb) if args.dtb else b""
    second = b""
    recovery_dtbo = b""

    # Android boot header.  header_version 0 ends after extra_cmdline;
    # v1 adds recovery_dtbo/header_size, v2 adds dtb_size/dtb_addr.
    if args.header_version == 0:
        header = struct.pack(
            "<8s10I16s512s32s1024s",
            b"ANDROID!",
            len(kernel), args.kernel_addr,
            len(ramdisk), args.ramdisk_addr,
            0, 0,                      # second_size, second_addr
            args.tags_addr,
            args.page_size,
            0,                         # header_version (v0 uses dt_size here)
            args.os_version,
            args.name.encode()[:16].ljust(16, b"\0"),
            args.cmdline.encode()[:511].ljust(512, b"\0"),
            b"\0" * 32,
            args.extra_cmdline.encode()[:1023].ljust(1024, b"\0"),
        )
    else:
        header = struct.pack(
            "<8s10I16s512s32s1024sIQIIQ",
            b"ANDROID!",
            len(kernel), args.kernel_addr,
            len(ramdisk), args.ramdisk_addr,
            0, 0,
            args.tags_addr,
            args.page_size,
            args.header_version,
            args.os_version,
            args.name.encode()[:16].ljust(16, b"\0"),
            args.cmdline.encode()[:511].ljust(512, b"\0"),
            b"\0" * 32,
            args.extra_cmdline.encode()[:1023].ljust(1024, b"\0"),
            0,                         # recovery_dtbo_size
            0,                         # recovery_dtbo_offset
            0,                         # header_size (patched below)
            len(dtb),
            args.dtb_addr,
        )

    # The header must fit in one page; pad it and patch the SHA1 id.
    header = header.ljust(args.page_size, b"\0")
    if args.header_version:
        # header_size lives at offset 1644 (1632 + recovery_dtbo_size 4 +
        # recovery_dtbo_offset 8); the packed v1/v2 header is 1660 bytes.
        header = header[:1644] + struct.pack("<I", 1660) + header[1648:]
    # Boot image id = SHA1 over kernel, ramdisk, second, and their sizes.
    sha = hashlib.sha1()
    for blob in (kernel, ramdisk, second):
        sha.update(blob)
        sha.update(struct.pack("<I", len(blob)))
    boot_id = sha.digest().ljust(32, b"\0")  # AOSP pads the SHA1 to 32 bytes
    id_off = 8 + 10 * 4 + 16 + 512
    header = header[:id_off] + boot_id + header[id_off + 32:]

    page = args.page_size
    out = header + pad(kernel, page) + pad(ramdisk, page)
    if recovery_dtbo:
        out += pad(recovery_dtbo, page)
    if dtb:
        out += pad(dtb, page)
    if args.seandroid:
        out += b"SEANDROIDENFORCE"
    return out


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--kernel", required=True)
    p.add_argument("--ramdisk")
    p.add_argument("--dtb")
    p.add_argument("--output", required=True)
    p.add_argument("--header-version", type=int, default=2, choices=(0, 2))
    p.add_argument("--cmdline", default="console=tty0 console=ttyMSM0,115200n8")
    p.add_argument("--extra-cmdline", default="")
    p.add_argument("--name", default="a71")
    p.add_argument("--os-version", type=lambda x: int(x, 0), default=0x1e000000)
    # Addresses copied from the LineageOS 23.2 boot.img for a71: the
    # bootloader ignores them in practice, but matching a known-good image is
    # the safest choice.
    p.add_argument("--kernel-addr", type=lambda x: int(x, 0), default=0x8000)
    p.add_argument("--ramdisk-addr", type=lambda x: int(x, 0), default=0x1000000)
    p.add_argument("--tags-addr", type=lambda x: int(x, 0), default=0x100)
    p.add_argument("--dtb-addr", type=lambda x: int(x, 0), default=0x1f00000)
    p.add_argument("--page-size", type=int, default=4096,
                   help="flash page size (4096 on the A71, as in its stock boot.img)")
    p.add_argument("--seandroid", action="store_true",
                   help="append the SEANDROIDENFORCE tag used by Samsung")
    args = p.parse_args()

    img = build(args)
    with open(args.output, "wb") as f:
        f.write(img)
    print(f"{args.output}: {len(img)} bytes "
          f"(kernel {len(load(args.kernel))}, ramdisk "
          f"{len(load(args.ramdisk)) if args.ramdisk else 0}, dtb "
          f"{len(load(args.dtb)) if args.dtb else 0})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
