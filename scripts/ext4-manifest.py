#!/usr/bin/env python3
"""ext4-manifest.py - manifeste de proprietaires vers commandes debugfs (H2).

Lecture stricte du format `uid:gid:mode:type:path`, verification contre l'arbre
de staging, generation de commandes debugfs `sif`, et verification des inodes
relus. Aucun montage, chroot, sudo ni loop device.
"""

import argparse
import os
import posixpath
import re
import stat
import sys

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_INPUT = 3

TYPE_MODE = {"f": 0o100000, "d": 0o040000, "l": 0o120000}


def die(message, code=EXIT_INPUT):
    print("ext4-manifest: %s" % message, file=sys.stderr)
    sys.exit(code)


def safe_path(path):
    if not path.startswith("/"):
        return False
    if path != "/" and (path.endswith("/") or "//" in path):
        return False
    if ".." in path.split("/"):
        return False
    for ch in path:
        if ord(ch) < 0x20 or ord(ch) == 0x7F or ch in " \t\\\"'`":
            return False
    return True


def read_manifest(path, rootfs):
    entries = []
    seen = set()
    with open(path, "r", encoding="utf-8", errors="strict") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split(":", 4)
            if len(fields) != 5:
                die("ligne %d : 5 champs attendus" % lineno, EXIT_FAIL)
            uid_s, gid_s, mode_s, kind, rel = fields
            if not safe_path(rel):
                die("ligne %d : chemin invalide" % lineno, EXIT_FAIL)
            if rel in seen:
                die("ligne %d : doublon %s" % (lineno, rel), EXIT_FAIL)
            seen.add(rel)
            try:
                uid = int(uid_s, 10)
                gid = int(gid_s, 10)
                perms = int(mode_s, 8)
            except ValueError:
                die("ligne %d : uid/gid/mode invalide" % lineno, EXIT_FAIL)
            if kind not in TYPE_MODE:
                die("ligne %d : type invalide" % lineno, EXIT_FAIL)
            if uid < 0 or gid < 0 or perms > 0o7777:
                die("ligne %d : valeur hors plage" % lineno, EXIT_FAIL)
            full = TYPE_MODE[kind] | perms
            target = rootfs if rel == "/" else os.path.join(rootfs, rel.lstrip("/"))
            try:
                st = os.lstat(target)
            except OSError:
                die("ligne %d : chemin absent de l'image : %s" % (lineno, rel), EXIT_FAIL)
            actual = "d" if stat.S_ISDIR(st.st_mode) else "l" if stat.S_ISLNK(st.st_mode) else "f" if stat.S_ISREG(st.st_mode) else "o"
            if actual != kind:
                die("ligne %d : type attendu %s, reel %s (%s)" % (lineno, kind, actual, rel), EXIT_FAIL)
            entries.append((rel, kind, perms, full, uid, gid))
    if not entries:
        die("manifeste vide", EXIT_FAIL)
    return entries


def write_tsv(entries, path):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# path\ttype\tperms\tfull_mode\tuid\tgid\n")
        for rel, kind, perms, full, uid, gid in entries:
            fh.write("%s\t%s\t%04o\t%07o\t%d\t%d\n" % (rel, kind, perms, full, uid, gid))


def cmd_check(args):
    entries = read_manifest(args.manifest, args.rootfs)
    write_tsv(entries, args.tsv)
    counts = {}
    for _rel, kind, _perms, _full, _uid, _gid in entries:
        counts[kind] = counts.get(kind, 0) + 1
    print("entries=%d" % len(entries))
    for kind in sorted(counts):
        print("type_%s=%d" % (kind, counts[kind]))
    return EXIT_OK


def read_tsv(path):
    rows = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            if not line.strip() or line.startswith("#"):
                continue
            rel, kind, perms, full, uid, gid = line.rstrip("\n").split("\t")
            rows.append((rel, kind, int(perms, 8), int(full, 8), int(uid), int(gid)))
    return rows


def cmd_debugfs(args):
    rows = read_tsv(args.tsv)
    with open(args.output, "w", encoding="utf-8") as fh:
        for rel, _kind, _perms, full, uid, gid in rows:
            fh.write("sif %s mode 0%o\n" % (rel, full))
            fh.write("sif %s uid %d\n" % (rel, uid))
            fh.write("sif %s gid %d\n" % (rel, gid))
            fh.write("sif %s ctime @%d\n" % (rel, args.epoch))
            fh.write("sif %s mtime @%d\n" % (rel, args.epoch))
            fh.write("sif %s atime @%d\n" % (rel, args.epoch))
    return EXIT_OK


def cmd_stat_commands(args):
    rows = read_tsv(args.tsv)
    with open(args.output, "w", encoding="utf-8") as fh:
        for rel, _kind, _perms, _full, _uid, _gid in rows:
            fh.write("stat %s\n" % rel)
    return EXIT_OK


def parse_stat_output(path):
    text = open(path, "r", encoding="utf-8", errors="replace").read().splitlines()
    blocks = []
    current = {}
    for line in text:
        match = re.search(r"Inode:\s+\d+\s+Type:\s+(\w+).*Mode:\s+([0-7]+)", line)
        if match:
            if current:
                blocks.append(current)
            current = {"type": match.group(1), "mode": int(match.group(2), 8)}
            continue
        match = re.search(r"User:\s+(\d+)\s+Group:\s+(\d+)", line)
        if match and current:
            current["uid"] = int(match.group(1))
            current["gid"] = int(match.group(2))
    if current:
        blocks.append(current)
    return blocks


def cmd_verify_stat(args):
    rows = read_tsv(args.tsv)
    blocks = parse_stat_output(args.stat)
    if len(blocks) != len(rows):
        die("stat: %d blocs pour %d entrees" % (len(blocks), len(rows)), EXIT_FAIL)
    failures = 0
    for (rel, kind, perms, _full, uid, gid), block in zip(rows, blocks):
        type_name = {"f": "regular", "d": "directory", "l": "symlink"}[kind]
        if block.get("type") != type_name:
            print("FAIL type %s" % rel)
            failures += 1
        if block.get("mode") != perms:
            print("FAIL mode %s" % rel)
            failures += 1
        if block.get("uid") != uid or block.get("gid") != gid:
            print("FAIL uid/gid %s" % rel)
            failures += 1
    print("entries=%d" % len(rows))
    print("failures=%d" % failures)
    return EXIT_OK if failures == 0 else EXIT_FAIL


def hash_file(path):
    import hashlib
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            block = fh.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def cmd_tree_check(args):
    rows = read_tsv(args.tsv)
    failures = 0
    expected = set()
    for rel, kind, perms, _full, _uid, _gid in rows:
        expected.add(rel)
        src = args.rootfs if rel == "/" else os.path.join(args.rootfs, rel.lstrip("/"))
        dst = args.extract if rel == "/" else os.path.join(args.extract, rel.lstrip("/"))
        try:
            sst = os.lstat(src)
            dstt = os.lstat(dst)
        except OSError:
            print("FAIL absent %s" % rel)
            failures += 1
            continue
        if kind == "l":
            if not os.path.islink(dst) or os.readlink(src) != os.readlink(dst):
                print("FAIL symlink %s" % rel)
                failures += 1
            continue
        # rdump non privilegie ne peut pas restaurer setuid/setgid/sticky :
        # ces bits sont verifies sur l'inode par debugfs stat (verify-stat).
        if stat.S_IMODE(dstt.st_mode) != perms and not (perms & 0o7000):
            print("FAIL mode %s" % rel)
            failures += 1
        if kind == "f":
            if sst.st_size != dstt.st_size:
                print("FAIL taille %s" % rel)
                failures += 1
                continue
            old = stat.S_IMODE(dstt.st_mode)
            if not os.access(dst, os.R_OK):
                os.chmod(dst, old | 0o400)
            try:
                if hash_file(src) != hash_file(dst):
                    print("FAIL contenu %s" % rel)
                    failures += 1
            finally:
                if stat.S_IMODE(os.lstat(dst).st_mode) != old:
                    os.chmod(dst, old)
    for base, dirs, files in os.walk(args.extract):
        for name in list(dirs) + files:
            rel = "/" + os.path.relpath(os.path.join(base, name), args.extract)
            if rel not in expected and rel != "/lost+found":
                print("FAIL extra %s" % rel)
                failures += 1
    print("entries=%d" % len(rows))
    print("failures=%d" % failures)
    return EXIT_OK if failures == 0 else EXIT_FAIL


def cmd_write_manifest(args):
    rows = read_tsv(args.tsv)
    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write("label=%s\n" % args.label)
        fh.write("uuid=%s\n" % args.uuid)
        fh.write("entries=%d\n" % len(rows))
        fh.write("# path\ttype\tmode\tuid\tgid\n")
        for rel, kind, perms, _full, uid, gid in rows:
            fh.write("%s\t%s\t%04o\t%d\t%d\n" % (rel, kind, perms, uid, gid))
    return EXIT_OK


def main(argv):
    parser = argparse.ArgumentParser(prog="ext4-manifest.py")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("check")
    p.add_argument("--rootfs", required=True)
    p.add_argument("--manifest", required=True)
    p.add_argument("--tsv", required=True)
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("debugfs-commands")
    p.add_argument("--tsv", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--epoch", required=True, type=int)
    p.set_defaults(func=cmd_debugfs)

    p = sub.add_parser("stat-commands")
    p.add_argument("--tsv", required=True)
    p.add_argument("--output", required=True)
    p.set_defaults(func=cmd_stat_commands)

    p = sub.add_parser("verify-stat")
    p.add_argument("--tsv", required=True)
    p.add_argument("--stat", required=True)
    p.set_defaults(func=cmd_verify_stat)

    p = sub.add_parser("tree-check")
    p.add_argument("--rootfs", required=True)
    p.add_argument("--extract", required=True)
    p.add_argument("--tsv", required=True)
    p.set_defaults(func=cmd_tree_check)

    p = sub.add_parser("write-manifest")
    p.add_argument("--tsv", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--label", required=True)
    p.add_argument("--uuid", required=True)
    p.set_defaults(func=cmd_write_manifest)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
