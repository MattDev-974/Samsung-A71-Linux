#!/usr/bin/env python3
"""package_boot.py - reconstruit un boot.img candidat UNTESTED (J5).

Remplace uniquement la section kernel du stock par uniLoader, preserve les
autres composants et champs d'en-tete, puis laisse la reanalyse a J3/J5.
Aucune image n'est presentee comme flashable.
"""

import hashlib
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import android_boot  # noqa: E402


def pad(data, page):
    return data + b"\x00" * ((page - len(data) % page) % page)


def main():
    if len(sys.argv) != 4:
        print("usage: package_boot.py STOCK UNILOADER OUTPUT", file=sys.stderr)
        return 2
    stock_path, ul_path, out_path = sys.argv[1:]
    stock = open(stock_path, "rb").read()
    fields, comps = android_boot.parse_boot(stock)
    hv = fields["header_version"]
    if hv not in (0, 1, 2):
        print("header non supporte", file=sys.stderr)
        return 4
    page = fields["page_size"]
    header = bytearray(stock[:page])
    ul = open(ul_path, "rb").read()
    struct.pack_into("<I", header, 8, len(ul))
    ramdisk = stock[comps["ramdisk"][0]:sum(comps["ramdisk"])] if "ramdisk" in comps else b""
    second = stock[comps["second"][0]:sum(comps["second"])] if "second" in comps else b""
    recovery = stock[comps["recovery_dtbo"][0]:sum(comps["recovery_dtbo"])] if "recovery_dtbo" in comps else b""
    dtb = stock[comps["dtb"][0]:sum(comps["dtb"])] if "dtb" in comps else b""
    # Recalcule l'id AOSP (SHA1 sur kernel/ramdisk/second + tailles).
    sha = hashlib.sha1()
    for blob in (ul, ramdisk, second):
        sha.update(blob)
        sha.update(struct.pack("<I", len(blob)))
    header[576:608] = sha.digest().ljust(32, b"\x00")
    body = pad(ul, page) + pad(ramdisk, page)
    if recovery:
        body += pad(recovery, page)
    if dtb:
        body += pad(dtb, page)
    candidate = bytes(header) + body
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "wb") as fh:
        fh.write(candidate)
    print("candidate=%s size=%d" % (os.path.basename(out_path), len(candidate)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
