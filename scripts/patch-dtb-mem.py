#!/usr/bin/env python3
"""Set the memory node size in a device tree blob.

The Samsung bootloader patches the memory node of the DTB it passes to the
kernel, but uniLoader boots our embedded mainline DTB instead, so the node
keeps its placeholder size of 0 and the kernel sees no RAM at all.

Usage:
  patch-dtb-mem.py in.dtb out.dtb --size 0x180000000 [--base 0x80000000]
"""
import argparse
import struct
import subprocess
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--base", type=lambda s: int(s, 0), default=0x80000000)
    ap.add_argument("--size", type=lambda s: int(s, 0), required=True)
    ap.add_argument("--dtc", default="dtc")
    args = ap.parse_args()

    dts = subprocess.run([args.dtc, "-I", "dtb", "-O", "dts", args.src],
                         check=True, capture_output=True, text=True).stdout
    marker = 'device_type = "memory";'
    idx = dts.find(marker)
    if idx < 0:
        print("no memory node found", file=sys.stderr)
        return 1
    reg = f"reg = <0x00 0x{args.base:08x} 0x{(args.size >> 32) & 0xffffffff:02x} 0x{args.size & 0xffffffff:08x}>;"
    end = dts.find(";", dts.find("reg = <", idx)) + 1
    out = dts[:dts.rfind("reg = <", idx, end)] + reg + dts[end:]
    subprocess.run([args.dtc, "-I", "dts", "-O", "dtb", "-o", args.dst],
                   input=out, text=True, check=True)
    print(f"{args.dst}: memory {args.base:#x}..{args.base + args.size:#x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
