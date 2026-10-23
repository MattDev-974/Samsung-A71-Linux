#!/usr/bin/env python3
"""mkcpio.py - archive cpio newc deterministe pour l'initramfs A71 (F1).

Aucune dependance externe. Les noms sont relatifs, l'ordre est lexical, les
timestamps viennent de --epoch, uid/gid sont forces a 0, les modes viennent de
l'arbre de staging (lui-meme construit avec des modes explicites).
"""

import argparse
import os
import stat
import sys

MAGIC = b"070701"
HEADER_LEN = 110
TRAILER = "TRAILER!!!"


def die(message, code=1):
    print("mkcpio: %s" % message, file=sys.stderr)
    sys.exit(code)


def pad4(data):
    return data + b"\x00" * ((4 - len(data) % 4) % 4)


def header(ino, mode, uid, gid, nlink, mtime, size, name, rdev=0):
    encoded = name.encode("utf-8")
    fields = (ino, mode, uid, gid, nlink, mtime, size, 0, 0,
              (rdev >> 8) & 0xFF, rdev & 0xFF, len(encoded) + 1, 0)
    return MAGIC + b"".join(b"%08X" % value for value in fields) + encoded + b"\x00"


def walk(root):
    items = []
    for base, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if not os.path.islink(os.path.join(base, d)))
        for name in sorted(dirs) + sorted(files):
            path = os.path.join(base, name)
            rel = os.path.relpath(path, root)
            items.append((rel, path))
    items.sort(key=lambda item: item[0])
    return items


def create(args):
    if not os.path.isdir(args.root):
        die("staging absent", 2)
    items = [(".", args.root)] + walk(args.root)
    with open(args.output, "wb") as out:
        ino = 1
        for rel, path in items:
            st = os.lstat(path)
            name = "." if rel == "." else rel.replace(os.sep, "/")
            if name.startswith("/") or ".." in name.split("/"):
                die("chemin interdit : %s" % name)
            if stat.S_ISDIR(st.st_mode):
                mode = stat.S_IFDIR | stat.S_IMODE(st.st_mode)
                out.write(pad4(header(ino, mode, 0, 0, 2, args.epoch, 0, name)))
            elif stat.S_ISLNK(st.st_mode):
                mode = stat.S_IFLNK | stat.S_IMODE(st.st_mode)
                target = os.readlink(path).encode("utf-8")
                out.write(pad4(header(ino, mode, 0, 0, 1, args.epoch, len(target), name)))
                out.write(pad4(target))
            elif stat.S_ISREG(st.st_mode):
                mode = stat.S_IFREG | stat.S_IMODE(st.st_mode)
                size = st.st_size
                out.write(pad4(header(ino, mode, 0, 0, 1, args.epoch, size, name)))
                with open(path, "rb") as fh:
                    while True:
                        block = fh.read(1024 * 1024)
                        if not block:
                            break
                        out.write(block)
                out.write(b"\x00" * ((4 - size % 4) % 4))
            else:
                die("entree speciale refusee : %s" % name)
            ino += 1
        out.write(pad4(header(0, 0, 0, 0, 1, args.epoch, 0, TRAILER)))
    return 0


def parse_header(data, offset):
    if data[offset:offset + 6] != MAGIC:
        die("magic newc invalide a l'offset %d" % offset)
    fields = []
    pos = offset + 6
    for _ in range(13):
        chunk = data[pos:pos + 8]
        if len(chunk) != 8:
            die("en-tete tronque")
        try:
            fields.append(int(chunk, 16))
        except ValueError:
            die("champ hexadecimal invalide")
        pos += 8
    (ino, mode, uid, gid, nlink, mtime, size, devmajor, devminor,
     rdevmajor, rdevminor, namesize, check) = fields
    name = data[pos:pos + namesize - 1].decode("utf-8", "replace")
    if len(data) < pos + namesize:
        die("nom tronque")
    data_pos = offset + HEADER_LEN + namesize
    data_pos += (4 - data_pos % 4) % 4
    return {
        "ino": ino, "mode": mode, "uid": uid, "gid": gid, "nlink": nlink,
        "mtime": mtime, "size": size, "devmajor": devmajor,
        "devminor": devminor, "rdevmajor": rdevmajor, "rdevminor": rdevminor,
        "name": name, "data_pos": data_pos,
    }


def list_archive(args):
    with open(args.input, "rb") as fh:
        data = fh.read()
    offset = 0
    count = 0
    while offset + HEADER_LEN <= len(data):
        entry = parse_header(data, offset)
        if entry["name"] == TRAILER:
            print("TRAILER")
            return 0
        if entry["name"].startswith("/") or ".." in entry["name"].split("/"):
            die("chemin interdit dans l'archive : %s" % entry["name"])
        if entry["uid"] != 0 or entry["gid"] != 0:
            die("uid/gid non nul : %s" % entry["name"])
        if stat.S_ISLNK(entry["mode"]):
            target = data[entry["data_pos"]:entry["data_pos"] + entry["size"]]
            print("%04o 0 0 l %s -> %s" % (stat.S_IMODE(entry["mode"]), entry["name"],
                                           target.decode("utf-8", "replace")))
        elif stat.S_ISDIR(entry["mode"]):
            print("%04o 0 0 d %s" % (stat.S_IMODE(entry["mode"]), entry["name"]))
        else:
            print("%04o 0 0 f %s" % (stat.S_IMODE(entry["mode"]), entry["name"]))
        count += 1
        offset = entry["data_pos"] + entry["size"]
        offset += (4 - offset % 4) % 4
    die("archive sans TRAILER (entrees lues : %d)" % count)


def main(argv):
    parser = argparse.ArgumentParser(prog="mkcpio.py")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("create")
    p.add_argument("--root", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--epoch", required=True, type=int)
    p.set_defaults(func=create)
    p = sub.add_parser("list")
    p.add_argument("--input", required=True)
    p.set_defaults(func=list_archive)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
