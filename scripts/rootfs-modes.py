#!/usr/bin/env python3
"""rootfs-modes.py - base de modes du rootfs A71 (D1).

Trois operations, toutes sans montage/chroot/sudo :

  build-db     construit une base de modes a partir de l'archive minirootfs
               verifiee et des paquets .apk signes (metadonnees tar reelles).
  apply        applique les modes cibles au rootfs de travail et ecrit le
               manifeste de proprietaires logique (uid:gid:mode:type:path).
  fingerprint  empreinte deterministe d'un arbre (contenu + modes + liens).

Le script n'utilise que la bibliotheque standard Python 3.
"""

import argparse
import hashlib
import io
import os
import re
import stat
import sys
import tarfile
import zlib

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_USAGE = 2


def die(message, code=EXIT_ERROR):
    print("rootfs-modes: %s" % message, file=sys.stderr)
    sys.exit(code)


def norm_rel(name):
    """Normalise un nom tar en chemin relatif sur, ou None pour la racine."""
    while name.startswith("./"):
        name = name[2:]
    name = name.strip("/")
    if name in ("", "."):
        return None
    parts = []
    for part in name.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            raise ValueError("chemin avec '..' : %s" % name)
        parts.append(part)
    if not parts:
        return None
    return "/".join(parts)


def mode_text(mode):
    return format(mode & 0o7777, "04o")


def parse_mode_text(text, where):
    try:
        value = int(text, 8)
    except ValueError:
        die("%s : mode octal invalide : %s" % (where, text))
    if value < 0 or value > 0o7777:
        die("%s : mode hors plage : %s" % (where, text))
    return value


def tar_entries(raw, source, db):
    """Ajoute les entrees d'un flux tar (octets) a la base."""
    try:
        tf = tarfile.open(fileobj=io.BytesIO(raw), mode="r:")
    except tarfile.TarError:
        return 0
    count = 0
    with tf:
        for member in tf:
            if member.name.startswith(".SIGN.") or member.name == ".PKGINFO":
                continue
            try:
                rel = norm_rel(member.name)
            except ValueError:
                continue
            if rel is None:
                continue
            if member.isdir():
                kind = "d"
            elif member.issym():
                kind = "l"
            elif member.isfile():
                kind = "f"
            else:
                continue
            mode = member.mode & 0o7777
            db[rel] = (kind, mode, member.uid, member.gid, source)
            count += 1
    return count


def apk_streams(data):
    """Decoupe un .apk en flux gzip concatenes (signature, controle, data)."""
    while data:
        dec = zlib.decompressobj(16 + zlib.MAX_WBITS)
        try:
            out = dec.decompress(data)
        except zlib.error:
            return
        out += dec.flush()
        if out:
            yield out
        if not dec.unused_data:
            return
        data = dec.unused_data


def read_package_stems(path):
    stems = set()
    if not path:
        return stems
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                stems.add(line)
    return stems


def build_db(args):
    db = {}
    version = args.version
    if args.archive:
        try:
            with tarfile.open(args.archive, "r:*") as tf:
                members = list(tf)
        except (OSError, tarfile.TarError) as exc:
            die("archive illisible : %s" % exc)
        for member in members:
            if member.name in (".", "./"):
                continue
            try:
                rel = norm_rel(member.name)
            except ValueError:
                continue
            if rel is None:
                continue
            if member.isdir():
                kind = "d"
            elif member.issym():
                kind = "l"
            elif member.isfile():
                kind = "f"
            else:
                continue
            db[rel] = (kind, member.mode & 0o7777, member.uid, member.gid,
                       "minirootfs:%s" % version)

    stems = read_package_stems(args.packages)
    apk_files = []
    if args.apk_dir:
        for name in sorted(os.listdir(args.apk_dir)):
            if not name.endswith(".apk"):
                continue
            stem = name[:-4]
            stem = re.sub(r"\.[0-9a-f]{8}$", "", stem)
            if stems and stem not in stems:
                continue
            apk_files.append((stem, os.path.join(args.apk_dir, name)))
    for stem, path in apk_files:
        try:
            with open(path, "rb") as fh:
                raw = fh.read()
        except OSError as exc:
            die("paquet illisible : %s" % exc)
        for stream in apk_streams(raw):
            tar_entries(stream, "apk:%s" % stem, db)

    if not db:
        die("base de modes vide")
    lines = ["# path\ttype\tmode\tuid\tgid\tsource"]
    for rel in sorted(db):
        kind, mode, uid, gid, source = db[rel]
        lines.append("%s\t%s\t%s\t%d\t%d\t%s" %
                     (rel, kind, mode_text(mode), uid, gid, source))
    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    if args.summary:
        sources = {}
        for _, _, _, _, source in db.values():
            sources[source] = sources.get(source, 0) + 1
        with open(args.summary, "w", encoding="utf-8") as fh:
            fh.write("entries=%d\n" % len(db))
            fh.write("archive=%s\n" % (os.path.basename(args.archive) if args.archive else "none"))
            for source in sorted(sources):
                fh.write("source=%s count=%d\n" % (source, sources[source]))
    return EXIT_OK


def read_db(path):
    db = {}
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) != 6:
                die("base de modes, ligne %d invalide" % lineno)
            rel, kind, mode, uid, gid, source = fields
            if kind not in ("d", "f", "l"):
                die("base de modes, ligne %d : type invalide" % lineno)
            db[rel] = (kind, parse_mode_text(mode, "base de modes"),
                       int(uid), int(gid), source)
    return db


def read_policy(path):
    policy = {}
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.rstrip("\n").split(None, 5)
            if len(parts) != 6:
                die("politique, ligne %d : 6 champs attendus" % lineno)
            kind, mode, uid, gid, rel, justification = parts
            if kind not in ("d", "f", "l"):
                die("politique, ligne %d : type invalide" % lineno)
            if not rel.startswith("/") or ".." in rel.split("/"):
                die("politique, ligne %d : chemin invalide" % lineno)
            if rel == "/":
                rel = ""
            else:
                rel = rel.strip("/")
                if not rel:
                    die("politique, ligne %d : chemin vide" % lineno)
            if kind == "d" and rel == "":
                pass
            elif rel == "":
                die("politique, ligne %d : la racine doit etre un repertoire" % lineno)
            if rel in policy:
                die("politique, ligne %d : chemin duplique" % lineno)
            policy[rel] = (kind, parse_mode_text(mode, "politique"),
                           int(uid), int(gid), justification)
    return policy


def walk_tree(root):
    """Parcourt sans suivre les liens ; rend (rel, abspath, lstat)."""
    stack = [("", root)]
    out = []
    while stack:
        rel_dir, abs_dir = stack.pop()
        try:
            entries = sorted(os.scandir(abs_dir), key=lambda e: e.name)
        except OSError as exc:
            die("lecture impossible : %s" % exc)
        for entry in entries:
            rel = entry.name if not rel_dir else rel_dir + "/" + entry.name
            try:
                st = entry.stat(follow_symlinks=False)
            except OSError as exc:
                die("stat impossible : %s (%s)" % (rel, exc))
            out.append((rel, entry.path, st))
            if stat.S_ISDIR(st.st_mode):
                stack.append((rel, entry.path))
    return sorted(out, key=lambda item: item[0])


def choose_mode(rel, st, db, policy):
    if rel in policy:
        kind, mode, uid, gid, justification = policy[rel]
        return kind, mode, uid, gid, "policy", justification
    if rel in db:
        kind, mode, uid, gid, source = db[rel]
        return kind, mode, uid, gid, source, ""
    if rel == "reports" or rel.startswith("reports/"):
        if stat.S_ISDIR(st.st_mode):
            return "d", 0o700, 0, 0, "project:reports-private", ""
        if stat.S_ISLNK(st.st_mode):
            return "l", 0o777, 0, 0, "project:reports-private", ""
        return "f", 0o600, 0, 0, "project:reports-private", ""
    if rel == "lib/modules" or rel.startswith("lib/modules/"):
        if stat.S_ISDIR(st.st_mode):
            return "d", 0o755, 0, 0, "policy:kernel-modules", ""
        if stat.S_ISLNK(st.st_mode):
            return "l", 0o777, 0, 0, "policy:kernel-modules", ""
        return "f", 0o644, 0, 0, "policy:kernel-modules", ""
    if stat.S_ISDIR(st.st_mode):
        return "d", 0o755, 0, 0, "default:system", ""
    if stat.S_ISLNK(st.st_mode):
        return "l", 0o777, 0, 0, "default:symlink", ""
    return "f", 0o644, 0, 0, "default:file", ""


def actual_kind(st):
    if stat.S_ISDIR(st.st_mode):
        return "d"
    if stat.S_ISLNK(st.st_mode):
        return "l"
    if stat.S_ISREG(st.st_mode):
        return "f"
    return "o"


def apply_modes(args):
    db = read_db(args.db)
    policy = read_policy(args.policy)
    tree = [("", args.root, os.lstat(args.root))] + walk_tree(args.root)

    errors = []
    changes = []
    source_counts = {}
    manifest = []

    for rel, abspath, st in tree:
        kind = actual_kind(st)
        if kind == "o":
            errors.append("%s : entree speciale refusee" % rel)
            continue
        want_kind, mode, uid, gid, source, justification = choose_mode(
            rel, st, db, policy)
        if want_kind != kind:
            errors.append("%s : type attendu %s, reel %s" % (rel, want_kind, kind))
            continue
        source_counts[source] = source_counts.get(source, 0) + 1
        old_mode = stat.S_IMODE(st.st_mode)
        if kind != "l" and old_mode != mode:
            changes.append((rel, kind, old_mode, mode, source, justification))
        if kind != "l":
            try:
                os.chmod(abspath, mode, follow_symlinks=False)
            except (NotImplementedError, OSError):
                try:
                    os.chmod(abspath, mode)
                except OSError as exc:
                    errors.append("%s : chmod impossible (%s)" % (rel, exc))
                    continue
        if not rel.startswith("reports/"):
            manifest.append("%d:%d:%s:%s:/%s" %
                            (uid, gid, mode_text(mode), kind, rel))

    if not errors:
        with open(args.manifest, "w", encoding="utf-8") as fh:
            fh.write("\n".join(manifest) + "\n")

    # Verification ciblee (jamais de chmod recursif general).
    allowed_setid = set()
    allowed_world = set()
    for rel, (kind, mode, _uid, _gid, _just) in policy.items():
        if mode & 0o6000:
            allowed_setid.add(rel)
        if mode & 0o0002:
            allowed_world.add(rel)

    actual = {}
    for rel, abspath, st in walk_tree(args.root):
        actual[rel] = (actual_kind(st), stat.S_IMODE(st.st_mode))

    for rel, (kind, mode) in actual.items():
        if kind == "l":
            continue
        if mode & 0o6000 and rel not in allowed_setid:
            errors.append("%s : setuid/setgid non autorise (%s)" %
                          (rel, mode_text(mode)))
        if mode & 0o0002 and rel not in allowed_world:
            errors.append("%s : world-writable non autorise (%s)" %
                          (rel, mode_text(mode)))

    checks = [
        ("bin/busybox", 0o755, 0o111),
        ("bin/bbsuid", 0o4111, 0o4111),
        ("etc/passwd", 0o644, 0o444),
        ("etc/group", 0o644, 0o444),
    ]
    for rel, expected_mode, required_bits in checks:
        if rel not in actual:
            errors.append("%s : absent" % rel)
            continue
        kind, mode = actual[rel]
        if kind != "f":
            errors.append("%s : type inattendu" % rel)
            continue
        if mode != expected_mode:
            errors.append("%s : mode %s, attendu %s" %
                          (rel, mode_text(mode), mode_text(expected_mode)))
        if mode & required_bits != required_bits:
            errors.append("%s : bits requis absents" % rel)

    for rel in ("etc/shadow", "etc/gshadow"):
        if rel in actual:
            kind, mode = actual[rel]
            if kind != "f":
                errors.append("%s : type inattendu" % rel)
            elif mode & 0o007:
                errors.append("%s : lisible par les autres (%s)" %
                              (rel, mode_text(mode)))

    for rel in ("tmp", "var/tmp"):
        if rel not in actual:
            errors.append("%s : absent" % rel)
            continue
        kind, mode = actual[rel]
        if kind != "d":
            errors.append("%s : type inattendu" % rel)
        elif mode & 0o1000 == 0 or mode & 0o002 == 0:
            errors.append("%s : sticky/world-writable manquant (%s)" %
                          (rel, mode_text(mode)))

    by_source = {}
    for item in changes:
        by_source[item[4]] = by_source.get(item[4], 0) + 1
    with open(args.report, "w", encoding="utf-8") as fh:
        fh.write("entries_total=%d\n" % len(tree))
        fh.write("manifest_entries=%d\n" % len(manifest))
        fh.write("mode_changes=%d\n" % len(changes))
        for source in sorted(source_counts):
            fh.write("source=%s count=%d changes=%d\n" %
                     (source, source_counts[source], by_source.get(source, 0)))
        fh.write("chmod_recursive=no\n")
        fh.write("verification=%s\n" % ("FAILED" if errors else "OK"))
    if args.changes:
        with open(args.changes, "w", encoding="utf-8") as fh:
            for rel, kind, old_mode, new_mode, source, justification in changes:
                fh.write("%s\t%s\t%s\t%s\t%s\t%s\n" %
                         (rel, kind, mode_text(old_mode), mode_text(new_mode),
                          source, justification or "-"))
    if args.policy_report:
        with open(args.policy_report, "w", encoding="utf-8") as fh:
            for rel in sorted(policy):
                kind, mode, uid, gid, justification = policy[rel]
                present = "yes" if rel in actual else "no"
                fh.write("%s\t%s\t%s\t%d\t%d\tpresent=%s\t%s\n" %
                         (rel, kind, mode_text(mode), uid, gid, present,
                          justification))
    if errors:
        for error in errors[:50]:
            print("rootfs-modes: %s" % error, file=sys.stderr)
        print("rootfs-modes: %d erreur(s)" % len(errors), file=sys.stderr)
        return EXIT_ERROR
    return EXIT_OK


def hash_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            block = fh.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def hash_file_readable(path):
    """Hash un fichier, en ajoutant u+r temporairement si necessaire.

    bbsuid est en 04111 : le proprietaire ne peut pas le lire. On restaure
    exactement le mode d'origine apres le hash (aucun chmod recursif).
    """
    try:
        return hash_file(path)
    except PermissionError:
        old_mode = stat.S_IMODE(os.lstat(path).st_mode)
        os.chmod(path, old_mode | 0o400)
        try:
            return hash_file(path)
        finally:
            os.chmod(path, old_mode)


def fingerprint(args):
    tree = walk_tree(args.root)
    lines = []
    for rel, abspath, st in tree:
        if args.exclude_reports and (rel == "reports" or rel.startswith("reports/")):
            continue
        kind = actual_kind(st)
        mode = mode_text(stat.S_IMODE(st.st_mode))
        if kind == "l":
            lines.append("l %s %s" % (mode, rel))
        elif kind == "d":
            lines.append("d %s %s" % (mode, rel))
        elif kind == "f":
            try:
                digest = hash_file_readable(abspath)
            except OSError as exc:
                die("hash impossible : %s (%s)" % (rel, exc))
            lines.append("f %s %d %s %s" % (mode, st.st_size, digest, rel))
        else:
            die("entree speciale : %s" % rel)
    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    return EXIT_OK


def mode_diff(args):
    def read_manifest(path):
        values = {}
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                fields = line.split(":", 4)
                if len(fields) != 5:
                    continue
                uid, gid, mode, kind, rel = fields
                values[rel] = (int(uid), int(gid), int(mode, 8), kind)
        return values

    old = read_manifest(args.old)
    new = read_manifest(args.new)
    changed = []
    for rel in sorted(set(old) & set(new)):
        if old[rel] != new[rel]:
            changed.append((rel, old[rel], new[rel]))
    only_old = sorted(set(old) - set(new))
    only_new = sorted(set(new) - set(old))
    with open(args.report, "w", encoding="utf-8") as fh:
        fh.write("entries_old=%d\n" % len(old))
        fh.write("entries_new=%d\n" % len(new))
        fh.write("changed=%d\n" % len(changed))
        fh.write("only_old=%d\n" % len(only_old))
        fh.write("only_new=%d\n" % len(only_new))
        fh.write("chmod_recursive=no\n")
        fh.write("source_of_truth=configs/rootfs-mode-policy.txt + paquets .apk signes + minirootfs\n")
        fh.write("\n# path old_uid:gid:mode:type new_uid:gid:mode:type\n")
        for rel, before, after in changed:
            fh.write("%s\t%d:%d:%04o:%s\t%d:%d:%04o:%s\n" %
                     (rel, before[0], before[1], before[2], before[3],
                      after[0], after[1], after[2], after[3]))
    return EXIT_OK


def main(argv):
    parser = argparse.ArgumentParser(prog="rootfs-modes.py")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("build-db")
    p.add_argument("--archive")
    p.add_argument("--apk-dir")
    p.add_argument("--packages")
    p.add_argument("--version", default="3.22.7")
    p.add_argument("--output", required=True)
    p.add_argument("--summary")
    p.set_defaults(func=build_db)

    p = sub.add_parser("apply")
    p.add_argument("--root", required=True)
    p.add_argument("--db", required=True)
    p.add_argument("--policy", required=True)
    p.add_argument("--manifest", required=True)
    p.add_argument("--report", required=True)
    p.add_argument("--changes")
    p.add_argument("--policy-report")
    p.set_defaults(func=apply_modes)

    p = sub.add_parser("fingerprint")
    p.add_argument("--root", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--exclude-reports", action="store_true")
    p.set_defaults(func=fingerprint)

    p = sub.add_parser("mode-diff")
    p.add_argument("--old", required=True)
    p.add_argument("--new", required=True)
    p.add_argument("--report", required=True)
    p.set_defaults(func=mode_diff)

    args = parser.parse_args(argv)
    if not os.path.isdir(args.root) if hasattr(args, "root") else False:
        die("rootfs absent : %s" % args.root, EXIT_USAGE)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
