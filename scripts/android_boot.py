#!/usr/bin/env python3
"""android_boot.py - parseur Android boot image, lecture seule (J3).

Implemente localement les en-tetes AOSP v0 a v4 (boot_img_hdr). Aucun contenu
extrait n'est execute. Les champs absents sont marques `not_present`, les
champs non determinables `not_determined`.
"""

import argparse
import hashlib
import json
import os
import shutil
import struct
import sys

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_INPUT = 3
EXIT_FORMAT = 4
EXIT_OUTPUT = 5
EXIT_CHANGED = 6

MAGIC = b"ANDROID!"
AVB_MAGIC = b"AVB0"


def die(msg, code=EXIT_FORMAT):
    print("android_boot: %s" % msg, file=sys.stderr)
    sys.exit(code)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def align(value, page):
    return (value + page - 1) // page * page


def u32(data, off, what):
    if off < 0 or off + 4 > len(data):
        die("champ %s hors fichier" % what)
    return struct.unpack_from("<I", data, off)[0]


def u64(data, off, what):
    if off < 0 or off + 8 > len(data):
        die("champ %s hors fichier" % what)
    return struct.unpack_from("<Q", data, off)[0]


def cstr(data, start, length, what):
    raw = data[start:start + length]
    if len(raw) != length:
        die("%s tronquee" % what)
    nul = raw.find(b"\x00")
    if nul < 0:
        die("%s non terminee par NUL" % what)
    return raw[:nul].decode("utf-8", "replace")


def compression(data):
    if data.startswith(b"\x1f\x8b"):
        return "gzip"
    if data.startswith(b"\x02\x21\x4c\x18"):
        return "lz4"
    if data.startswith(b"\xfd7zXZ\x00"):
        return "xz"
    if data.startswith(b"\x28\xb5\x2f\xfd"):
        return "zstd"
    if data.startswith(b"\x5d\x00\x00"):
        return "lzma"
    return "none"


def decode_os_version(value):
    if value == 0:
        return "not_determined", "not_determined"
    major = (value >> 25) & 0x7F
    minor = (value >> 18) & 0x7F
    patch = (value >> 11) & 0x7F
    year = ((value >> 4) & 0x7F) + 2000
    month = value & 0x0F
    if month < 1 or month > 12:
        return "%d.%d.%d" % (major, minor, patch), "not_determined"
    return "%d.%d.%d" % (major, minor, patch), "%04d-%02d" % (year, month)


def parse_avb(data):
    if len(data) < 64:
        return {"present": False}
    footer = data[-64:]
    if footer[:4] != AVB_MAGIC:
        return {"present": False}
    original = struct.unpack_from("<Q", footer, 12)[0]
    vbmeta_offset = struct.unpack_from("<Q", footer, 20)[0]
    vbmeta_size = struct.unpack_from("<Q", footer, 28)[0]
    if original > len(data) or vbmeta_offset + vbmeta_size > len(data):
        die("footer AVB incoherent")
    return {
        "present": True,
        "original_image_size": original,
        "vbmeta_offset": vbmeta_offset,
        "vbmeta_size": vbmeta_size,
    }


def parse_boot(data):
    if len(data) < 48:
        die("image tronquee avant l'en-tete")
    if data[:8] != MAGIC:
        die("magic Android boot absent")
    hv = u32(data, 40, "header_version")
    if hv < 0 or hv > 4:
        die("header_version Android inconnue : %d" % hv)
    fields = {}
    comps = {}
    if hv <= 2:
        kernel_size = u32(data, 8, "kernel_size")
        kernel_addr = u32(data, 12, "kernel_addr")
        ramdisk_size = u32(data, 16, "ramdisk_size")
        ramdisk_addr = u32(data, 20, "ramdisk_addr")
        second_size = u32(data, 24, "second_size")
        second_addr = u32(data, 28, "second_addr")
        tags_addr = u32(data, 32, "tags_addr")
        page = u32(data, 36, "page_size")
        os_version = u32(data, 44, "os_version")
        if page < 2048 or page > 65536 or (page & (page - 1)) != 0:
            die("page_size invalide : %d" % page)
        name = cstr(data, 48, 16, "name")
        cmdline = cstr(data, 64, 512, "cmdline")
        extra = cstr(data, 608, 1024, "extra_cmdline")
        cmdline = (cmdline + extra).strip()
        header_size = 1632 if hv == 0 else 1648
        recovery_size = recovery_offset = 0
        dtb_size = 0
        dtb_addr = 0
        if hv >= 1:
            header_size = u32(data, 1644, "header_size") or 1660
            recovery_size = u32(data, 1632, "recovery_dtbo_size")
            recovery_offset = u64(data, 1636, "recovery_dtbo_offset")
        if hv >= 2:
            dtb_size = u32(data, 1648, "dtb_size")
            dtb_addr = u64(data, 1652, "dtb_addr")
        if header_size < 1632 or header_size > 4096:
            die("header_size invalide : %d" % header_size)
        if page < header_size:
            die("page_size < header_size")
        kernel_off = page
        ramdisk_off = align(kernel_off + kernel_size, page)
        second_off = align(ramdisk_off + ramdisk_size, page)
        recovery_off = align(second_off + second_size, page)
        if hv >= 1 and recovery_offset:
            recovery_off = recovery_offset
        dtb_off = align(recovery_off + recovery_size, page)
        fields.update({
            "header_version": hv,
            "page_size": page,
            "kernel_size": kernel_size,
            "kernel_addr": "0x%x" % kernel_addr,
            "ramdisk_size": ramdisk_size,
            "ramdisk_addr": "0x%x" % ramdisk_addr,
            "second_size": second_size,
            "second_addr": "0x%x" % second_addr if second_size else "not_present",
            "tags_addr": "0x%x" % tags_addr,
            "dtb_size": dtb_size if hv >= 2 else "not_present",
            "dtb_addr": "0x%x" % dtb_addr if hv >= 2 and dtb_size else "not_present",
            "recovery_dtbo_size": recovery_size if hv >= 1 else "not_present",
            "recovery_dtbo_offset": recovery_off if recovery_size else "not_present",
            "name": name or "not_present",
            "cmdline": cmdline if cmdline else "not_present",
        })
        for label, start, size in (
            ("kernel", kernel_off, kernel_size),
            ("ramdisk", ramdisk_off, ramdisk_size),
            ("second", second_off, second_size),
            ("recovery_dtbo", recovery_off, recovery_size),
            ("dtb", dtb_off, dtb_size),
        ):
            if size:
                if start < 0 or start + size > len(data):
                    die("composant %s hors fichier" % label)
                comps[label] = (start, size)
        total_end = align(dtb_off + dtb_size, page) if dtb_size else align(recovery_off + recovery_size, page) if recovery_size else align(second_off + second_size, page)
    else:
        kernel_size = u32(data, 8, "kernel_size")
        ramdisk_size = u32(data, 12, "ramdisk_size")
        os_version = u32(data, 16, "os_version")
        header_size = u32(data, 20, "header_size")
        hv_field = u32(data, 40, "header_version")
        if hv_field != hv:
            die("header_version incoherente")
        expected = 1580 if hv == 3 else 1584
        if header_size < expected or header_size > 4096:
            die("header_size v%d invalide : %d" % (hv, header_size))
        page = 4096
        cmdline = cstr(data, 44, 1536, "cmdline").strip()
        signature_size = u32(data, 1580, "signature_size") if hv == 4 else 0
        kernel_off = page
        ramdisk_off = align(kernel_off + kernel_size, page)
        signature_off = align(ramdisk_off + ramdisk_size, page)
        if signature_size:
            comps["signature"] = (signature_off, signature_size)
        if kernel_size:
            comps["kernel"] = (kernel_off, kernel_size)
        if ramdisk_size:
            comps["ramdisk"] = (ramdisk_off, ramdisk_size)
        fields.update({
            "header_version": hv,
            "page_size": "not_present",
            "kernel_size": kernel_size,
            "kernel_addr": "not_present",
            "ramdisk_size": ramdisk_size,
            "ramdisk_addr": "not_present",
            "second_size": "not_present",
            "second_addr": "not_present",
            "tags_addr": "not_present",
            "dtb_size": "not_present",
            "dtb_addr": "not_present",
            "recovery_dtbo_size": "not_present",
            "recovery_dtbo_offset": "not_present",
            "name": "not_present",
            "cmdline": cmdline if cmdline else "not_present",
            "signature_size": signature_size if hv == 4 else "not_present",
        })
        total_end = align(signature_off + signature_size, page) if signature_size else align(ramdisk_off + ramdisk_size, page)
        if total_end > len(data):
            die("image v%d tronquee" % hv)
    if total_end > len(data):
        die("composants hors fichier")
    os_string, patch_level = decode_os_version(os_version)
    avb = parse_avb(data)
    fields.update({
        "os_version": "0x%x" % os_version,
        "os_version_string": os_string,
        "os_patch_level": patch_level,
        "file_size": len(data),
        "file_sha256": sha256(data),
        "total_end": total_end,
        "avb_footer_present": "yes" if avb["present"] else "no",
        "avb_original_image_size": avb.get("original_image_size", "not_present"),
        "avb_vbmeta_offset": avb.get("vbmeta_offset", "not_present"),
        "avb_vbmeta_size": avb.get("vbmeta_size", "not_present"),
        "vendor_boot_required": "not_determined",
        "init_boot_required": "not_determined",
    })
    return fields, comps


def write_outputs(data, fields, comps, outdir):
    compdir = os.path.join(outdir, "components")
    os.makedirs(compdir, exist_ok=True)
    manifest = []
    for label, (start, size) in comps.items():
        payload = data[start:start + size]
        path = os.path.join(compdir, label + ".bin")
        with open(path, "wb") as fh:
            fh.write(payload)
        digest = sha256(payload)
        manifest.append("%s  components/%s.bin" % (digest, label))
        fields["%s_offset" % label] = start
        fields["%s_sha256" % label] = digest
        fields["%s_compression" % label] = compression(payload) if label in ("kernel", "ramdisk") else "not_present"
    with open(os.path.join(outdir, "extraction-manifest.sha256"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(manifest) + ("\n" if manifest else ""))
    with open(os.path.join(outdir, "stock-boot-analysis.json"), "w", encoding="utf-8") as fh:
        json.dump(fields, fh, indent=2, sort_keys=True)
        fh.write("\n")
    with open(os.path.join(outdir, "stock-boot-analysis.txt"), "w", encoding="utf-8") as fh:
        fh.write("format=android_boot\n")
        fh.write("magic=ANDROID!\n")
        for key in sorted(fields):
            fh.write("%s=%s\n" % (key, fields[key]))
    return manifest


def main(argv):
    parser = argparse.ArgumentParser(prog="analyze-stock-boot.sh")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)

    if not os.path.isfile(args.input) or os.path.islink(args.input):
        die("entree absente, non reguliere ou symlink", EXIT_INPUT)
    data = open(args.input, "rb").read()
    if not data:
        die("entree vide", EXIT_INPUT)
    before = sha256(data)
    # Crochet de test uniquement : simule une modification concurrente.
    if os.environ.get("A71_ANALYZE_TEST_MUTATE") == "1":
        with open(args.input, "ab") as fh:
            fh.write(b"X")
    fields, comps = parse_boot(data)
    after_hash = sha256(open(args.input, "rb").read())
    if before != after_hash:
        die("entree modifiee pendant l'analyse", EXIT_CHANGED)
    if os.path.islink(args.output):
        die("sortie symlink refusee", EXIT_OUTPUT)
    if os.path.exists(args.output):
        if not os.path.isdir(args.output):
            die("sortie non repertoire", EXIT_OUTPUT)
        if os.listdir(args.output):
            if not args.force:
                die("sortie non vide (--force)", EXIT_OUTPUT)
            for name in os.listdir(args.output):
                path = os.path.join(args.output, name)
                if os.path.isdir(path) and not os.path.islink(path):
                    shutil.rmtree(path)
                else:
                    os.unlink(path)
    os.makedirs(args.output, exist_ok=True)
    fields["input_name"] = os.path.basename(args.input)
    write_outputs(data, fields, comps, args.output)
    print("analyzed %s header_version=%s" % (os.path.basename(args.input), fields["header_version"]))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
