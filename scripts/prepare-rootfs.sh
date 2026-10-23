#!/usr/bin/env bash
# shellcheck shell=bash
#
# prepare-rootfs.sh - acquisition, verification et extraction CONTROLEE du
#                     minirootfs Alpine epingle.
#
# Aucun chroot, proot, QEMU, montage, apk, module noyau, depmod, initramfs,
# boot.img, ni acces appareil. Aucune execution d'un binaire de l'archive.
#
# Usage :
#   ./scripts/prepare-rootfs.sh --manifest manifest.yaml \
#       --cache-dir work/rootfs-cache --work-dir work [--offline] [--force]
#
# Codes de sortie :
#   0 succes
#   2 erreur d'usage
#   3 manifeste ou metadonnees invalides
#   4 telechargement, cache, taille ou checksum invalide
#   5 archive dangereuse ou extraction refusee
#   6 rootfs extrait invalide
#   7 sortie ou permissions refusees

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PROG=$(basename "$0")

EXIT_OK=0
EXIT_USAGE=2
EXIT_MANIFEST=3
EXIT_ARCHIVE=4
EXIT_UNSAFE=5
EXIT_ROOTFS=6
EXIT_OUTPUT=7

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() { say "$1"; printf 'Utilise --help.\n' >&2; exit "$EXIT_USAGE"; }
die_code() { local c=$1; shift; say "$*"; exit "$c"; }

usage() {
    cat <<EOF
$PROG - preparation du rootfs Alpine (acquisition + extraction controlee)

Usage
  $PROG --manifest FILE --cache-dir DIR --work-dir DIR [--offline] [--force]

Options
  --manifest FILE  manifeste du projet (valeurs epinglees)
  --cache-dir DIR  cache adresse par contenu
  --work-dir DIR   repertoire de travail (rootfs/ et rapports)
  --offline        aucun acces reseau ; exige une archive valide en cache
  --force          accepte une destination deja presente et la recree
  -h, --help       cette aide

Sorties (dans --work-dir/rootfs)
  rootfs-base/                     arborescence Alpine extraite
  archive-list.txt                 inventaire de l'archive
  reports/provenance.json
  reports/rootfs-summary.txt
  reports/archive-validation.txt
  reports/repositories-detected.txt
  reports/tree-manifest.sha256
  reports/extraction-reproducibility.txt

Codes : 0 ok, 2 usage, 3 manifeste, 4 archive, 5 archive dangereuse,
        6 rootfs invalide, 7 sortie refusee
EOF
}

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
MANIFEST_FILE=""
CACHE_DIR=""
WORK_DIR=""
OFFLINE=0
FORCE=0
SEEN=" "
mark_opt() {
    case "$SEEN" in
        *" $1 "*) usage_error "option repetee : --$1" ;;
    esac
    SEEN="$SEEN$1 "
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit "$EXIT_OK" ;;
        --manifest) mark_opt manifest; [ $# -ge 2 ] || usage_error "--manifest attend un fichier"; MANIFEST_FILE=$2; shift ;;
        --cache-dir) mark_opt cache-dir; [ $# -ge 2 ] || usage_error "--cache-dir attend un repertoire"; CACHE_DIR=$2; shift ;;
        --work-dir) mark_opt work-dir; [ $# -ge 2 ] || usage_error "--work-dir attend un repertoire"; WORK_DIR=$2; shift ;;
        --offline) mark_opt offline; OFFLINE=1 ;;
        --force) mark_opt force; FORCE=1 ;;
        --manifest=*) mark_opt manifest; MANIFEST_FILE=${1#--manifest=} ;;
        --cache-dir=*) mark_opt cache-dir; CACHE_DIR=${1#--cache-dir=} ;;
        --work-dir=*) mark_opt work-dir; WORK_DIR=${1#--work-dir=} ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

[ -n "$MANIFEST_FILE" ] || usage_error "--manifest est obligatoire"
[ -n "$CACHE_DIR" ] || usage_error "--cache-dir est obligatoire"
[ -n "$WORK_DIR" ] || usage_error "--work-dir est obligatoire"

umask 077

# --------------------------------------------------------------------------
# Manifeste
# --------------------------------------------------------------------------
[ -f "$MANIFEST_FILE" ] || die_code "$EXIT_MANIFEST" "manifeste absent"
[ -r "$MANIFEST_FILE" ] || die_code "$EXIT_MANIFEST" "manifeste illisible"

mval() {
    local key=$1 val rc=0
    val=$(A71_MANIFEST="$MANIFEST_FILE" bash -c '. "$1/scripts/common.sh"; manifest_get "$A71_MANIFEST" "$2"' _ "$REPO_ROOT" "$key") || rc=$?
    if [ "$rc" -ne 0 ]; then
        die_code "$EXIT_MANIFEST" "manifeste : cle absente ($key)"
    fi
    case "$val" in
        '' | TODO_*) die_code "$EXIT_MANIFEST" "manifeste : $key non resolu ($val)" ;;
    esac
    printf '%s\n' "$val"
}

DIST_NAME=$(mval distribution.name)
DIST_SERIES=$(mval distribution.series)
DIST_VERSION=$(mval distribution.version)
DIST_ARCH=$(mval distribution.architecture)
DIST_URL=$(mval distribution.minirootfs_url)
DIST_SHA256=$(mval distribution.minirootfs_sha256)
DIST_SHA512=$(mval distribution.minirootfs_sha512)
DIST_SIZE=$(mval distribution.minirootfs_size)
SIG_STATUS=$(A71_MANIFEST="$MANIFEST_FILE" bash -c '. "$1/scripts/common.sh"; manifest_get "$A71_MANIFEST" distribution.minirootfs_signature_status' _ "$REPO_ROOT" 2>/dev/null || echo not_verified)

ARCHIVE_NAME=$(basename "$DIST_URL")

case "$DIST_SHA256" in
    *[!0-9a-f]* | '') die_code "$EXIT_MANIFEST" "minirootfs_sha256 n'est pas hexadecimal" ;;
esac
[ "${#DIST_SHA256}" -eq 64 ] || die_code "$EXIT_MANIFEST" "minirootfs_sha256 doit faire 64 caracteres"
case "$DIST_SHA512" in
    *[!0-9a-f]* | '') die_code "$EXIT_MANIFEST" "minirootfs_sha512 n'est pas hexadecimal" ;;
esac
[ "${#DIST_SHA512}" -eq 128 ] || die_code "$EXIT_MANIFEST" "minirootfs_sha512 doit faire 128 caracteres"
case "$DIST_SIZE" in
    '' | *[!0-9]*) die_code "$EXIT_MANIFEST" "minirootfs_size doit etre numerique" ;;
esac
[ "$DIST_SIZE" -gt 0 ] || die_code "$EXIT_MANIFEST" "minirootfs_size doit etre > 0"
[ "$DIST_ARCH" = "aarch64" ] || die_code "$EXIT_MANIFEST" "architecture inattendue : $DIST_ARCH (aarch64 attendu)"

# --------------------------------------------------------------------------
# Repertoires
# --------------------------------------------------------------------------
mkdir -p "$CACHE_DIR" "$WORK_DIR" || die_code "$EXIT_OUTPUT" "creation des repertoires impossible"
chmod 700 "$CACHE_DIR" "$WORK_DIR" 2>/dev/null || true
CACHE_DIR=$(cd "$CACHE_DIR" && pwd -P)
WORK_DIR=$(cd "$WORK_DIR" && pwd -P)

ROOTFS_DIR="$WORK_DIR/rootfs"
DEST="$ROOTFS_DIR/rootfs-base"
REPORTS="$ROOTFS_DIR/reports"
if [ -L "$ROOTFS_DIR" ]; then
    die_code "$EXIT_OUTPUT" "rootfs/ est un lien symbolique : refuse"
fi
mkdir -p "$ROOTFS_DIR" "$REPORTS" || die_code "$EXIT_OUTPUT" "creation de rootfs/ impossible"
chmod 700 "$ROOTFS_DIR" "$REPORTS" 2>/dev/null || true

CACHE_FILE="$CACHE_DIR/downloads/sha256/$DIST_SHA256"
mkdir -p "$(dirname "$CACHE_FILE")"
chmod 700 "$(dirname "$CACHE_FILE")" 2>/dev/null || true

if [ -L "$DEST" ]; then
    die_code "$EXIT_OUTPUT" "destination est un lien symbolique : rootfs-base"
fi
if [ -e "$DEST" ]; then
    if [ "$FORCE" != "1" ]; then
        die_code "$EXIT_OUTPUT" "destination deja presente (utilise --force)"
    fi
    [ -n "$DEST" ] && [ "$DEST" != "/" ] && [ "$DEST" != "$WORK_DIR" ] || die_code "$EXIT_OUTPUT" "destination dangereuse"
    case "$DEST" in
        "$ROOTFS_DIR"/rootfs-base) ;;
        *) die_code "$EXIT_OUTPUT" "destination inattendue" ;;
    esac
    rm -rf -- "$DEST" || die_code "$EXIT_OUTPUT" "suppression de la destination impossible"
fi

# --------------------------------------------------------------------------
# Cache adresse par contenu
# --------------------------------------------------------------------------
verify_archive() {
    local f=$1 size sha256 sha512
    [ -f "$f" ] || return 1
    size=$(wc -c <"$f" | tr -d ' ')
    [ "$size" = "$DIST_SIZE" ] || return 1
    sha256=$(sha256sum "$f" | cut -d' ' -f1)
    [ "$sha256" = "$DIST_SHA256" ] || return 1
    sha512=$(sha512sum "$f" | cut -d' ' -f1)
    [ "$sha512" = "$DIST_SHA512" ] || return 1
    return 0
}

CACHE_STATE="absent"
if [ -f "$CACHE_FILE" ]; then
    if verify_archive "$CACHE_FILE"; then CACHE_STATE="valide"; else CACHE_STATE="corrompu"; fi
fi

if [ "$CACHE_STATE" = "corrompu" ]; then
    if [ "$OFFLINE" = "1" ] || [ "$FORCE" != "1" ]; then
        die_code "$EXIT_ARCHIVE" "cache corrompu (taille/SHA-256/SHA-512) : relancer avec --force en ligne"
    fi
    rm -f -- "$CACHE_FILE"
    CACHE_STATE="absent"
fi

if [ "$CACHE_STATE" = "absent" ]; then
    [ "$OFFLINE" = "1" ] && die_code "$EXIT_ARCHIVE" "mode offline : archive absente du cache"
    tmp_dl=$(umask 077 && mktemp "$CACHE_DIR/.download-XXXXXXXX") || die_code "$EXIT_ARCHIVE" "temporaire impossible"
    say "telechargement de $ARCHIVE_NAME"
    if ! curl --fail --show-error --silent --location --max-time 900 --retry 2 --retry-delay 2 \
        "$DIST_URL" -o "$tmp_dl"; then
        rm -f "$tmp_dl"
        die_code "$EXIT_ARCHIVE" "telechargement echoue"
    fi
    dl_size=$(wc -c <"$tmp_dl" | tr -d ' ')
    [ "$dl_size" = "$DIST_SIZE" ] || { rm -f "$tmp_dl"; die_code "$EXIT_ARCHIVE" "taille telechargee $dl_size != attendue $DIST_SIZE"; }
    dl_sha=$(sha256sum "$tmp_dl" | cut -d' ' -f1)
    [ "$dl_sha" = "$DIST_SHA256" ] || { rm -f "$tmp_dl"; die_code "$EXIT_ARCHIVE" "SHA-256 telecharge != attendu"; }
    dl_sha512=$(sha512sum "$tmp_dl" | cut -d' ' -f1)
    [ "$dl_sha512" = "$DIST_SHA512" ] || { rm -f "$tmp_dl"; die_code "$EXIT_ARCHIVE" "SHA-512 telecharge != attendu"; }
    chmod 600 "$tmp_dl"
    mv -f -- "$tmp_dl" "$CACHE_FILE" || die_code "$EXIT_ARCHIVE" "renommage atomique impossible"
    CACHE_STATE="telecharge"
fi

ARCHIVE_SIZE=$(wc -c <"$CACHE_FILE" | tr -d ' ')
SHA256_ACTUAL=$(sha256sum "$CACHE_FILE" | cut -d' ' -f1)
SHA512_ACTUAL=$(sha512sum "$CACHE_FILE" | cut -d' ' -f1)
chmod 600 "$CACHE_FILE" 2>/dev/null || true

# --------------------------------------------------------------------------
# Inspection de surete (avant toute extraction)
# --------------------------------------------------------------------------
ARCHIVE_LIST="$ROOTFS_DIR/archive-list.txt"
VALIDATION_FILE="$REPORTS/archive-validation.txt"

python3 - "$CACHE_FILE" "$ARCHIVE_LIST" "$VALIDATION_FILE" <<'PY' || die_code "$EXIT_UNSAFE" "archive refusee (voir reports/archive-validation.txt)"
import posixpath
import sys
import tarfile

path, listing, report = sys.argv[1], sys.argv[2], sys.argv[3]
problems = []
stats = {"dir": 0, "file": 0, "sym": 0, "lnk": 0, "other": 0}
lines = []

# Politique des liens : un rootfs Linux legitime contient des liens symboliques,
# y compris ABSOLUS (/bin/busybox). Un lien absolu n'est pas une sortie de
# racine : il designe un chemin DANS le rootfs. Sont refuses :
#   * nom absolu ou contenant '..' ;
#   * cible relative qui remonte au-dessus de la racine ;
#   * cible absolue absente de l'archive ;
#   * lien dur absolu, sortant, ou vers une cible absente ;
#   * ecriture a travers un lien symbolique (membre dont un ancetre est un lien).
members = {}


def norm(name):
    return posixpath.normpath(name)


with tarfile.open(path, "r:*") as tf:
    entries = list(tf.getmembers())

for m in entries:
    if m.name in (".", "./", ""):
        continue
    members[norm(m.name)] = m

for m in entries:
    name = m.name
    if name in (".", "./", ""):
        continue
    kind = ("dir" if m.isdir() else "file" if m.isfile() else
            "sym" if m.issym() else "lnk" if m.islnk() else "other")
    stats[kind] += 1
    lines.append("%s\t%s\t%d" % (kind, name, m.size))

    if name.startswith("/"):
        problems.append("chemin absolu : %s" % name)
        continue
    parts = name.split("/")
    if ".." in parts:
        problems.append("composant '..' : %s" % name)
        continue
    if kind == "other":
        problems.append("entree speciale : %s" % name)
        continue

    prefix = ""
    crossed = False
    for comp in parts[:-1]:
        prefix = prefix + "/" + comp if prefix else comp
        anc = members.get(prefix)
        if anc is not None and anc.issym():
            problems.append("ecriture a travers un lien symbolique : %s (via %s)" % (name, prefix))
            crossed = True
            break
    if crossed:
        continue

    if m.issym():
        target = m.linkname
        if target.startswith("/"):
            resolved = norm(target.lstrip("/"))
            if resolved.startswith(".."):
                problems.append("lien absolu sortant : %s -> %s" % (name, target))
            elif resolved not in members:
                problems.append("lien absolu vers une cible absente : %s -> %s" % (name, target))
        else:
            resolved = norm(posixpath.join(posixpath.dirname(norm(name)), target))
            if resolved.startswith(".."):
                problems.append("lien symbolique sortant : %s -> %s" % (name, target))
    elif m.islnk():
        target = m.linkname
        if target.startswith("/"):
            problems.append("lien dur absolu : %s -> %s" % (name, target))
        else:
            resolved = norm(target)
            if resolved.startswith(".."):
                problems.append("lien dur sortant : %s -> %s" % (name, target))
            elif resolved not in members:
                problems.append("lien dur vers une cible absente : %s -> %s" % (name, target))

with open(listing, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + ("\n" if lines else ""))

with open(report, "w", encoding="utf-8") as fh:
    fh.write("archive=%s\n" % posixpath.basename(path))
    fh.write("entries=%d\n" % sum(stats.values()))
    for k in ("dir", "file", "sym", "lnk", "other"):
        fh.write("entries_%s=%d\n" % (k, stats[k]))
    fh.write("links_policy=internal_only_including_absolute_inside_root\n")
    fh.write("result=%s\n" % ("REFUSED" if problems else "OK"))
    for p in problems[:50]:
        fh.write("problem=%s\n" % p)

if problems:
    for p in problems[:20]:
        print("archive: " + p, file=sys.stderr)
    print("archive: ... %d probleme(s) au total" % len(problems), file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY

# --------------------------------------------------------------------------
# Extraction vers un temporaire prive puis publication atomique
# --------------------------------------------------------------------------
extract_one() {
    # extract_one <destination> ; ecrit dans la destination (doit etre vide)
    local dest=$1
    tar -xf "$CACHE_FILE" -C "$dest" --no-same-owner --no-same-permissions 2>"$ROOTFS_DIR/.extract.err" ||
        return 1
    return 0
}

TMP_EXT=$(umask 077 && mktemp -d "$WORK_DIR/.a71-rootfs-XXXXXXXX") || die_code "$EXIT_OUTPUT" "temporaire impossible"
extract_one "$TMP_EXT" || { rm -rf "$TMP_EXT"; die_code "$EXIT_UNSAFE" "extraction refusee"; }

# aucun peripherique cree
if find "$TMP_EXT" \( -type b -o -type c -o -type p -o -type s \) | grep -q .; then
    rm -rf "$TMP_EXT"
    die_code "$EXIT_UNSAFE" "entree speciale creee lors de l'extraction"
fi

mv -- "$TMP_EXT" "$DEST" || { rm -rf "$TMP_EXT"; die_code "$EXIT_OUTPUT" "publication atomique impossible"; }

# --------------------------------------------------------------------------
# Validation de l'arborescence Alpine
# --------------------------------------------------------------------------
[ -d "$DEST" ] || die_code "$EXIT_ROOTFS" "rootfs absent apres extraction"
for p in etc/alpine-release etc/os-release etc/apk etc/apk/repositories etc/apk/arch bin/busybox bin/sh sbin/apk lib usr var; do
    # -e suit les liens : sur l'hote, un lien absolu (/bin/busybox) ne resout
    # pas. On teste donc aussi le lien lui-meme.
    [ -e "$DEST/$p" ] || [ -L "$DEST/$p" ] || die_code "$EXIT_ROOTFS" "element manquant : $p"
done

ALPINE_RELEASE=$(tr -d '\r\n' <"$DEST/etc/alpine-release")
[ "$ALPINE_RELEASE" = "$DIST_VERSION" ] ||
    die_code "$EXIT_ROOTFS" "etc/alpine-release=$ALPINE_RELEASE != $DIST_VERSION"

APK_ARCH=$(tr -d '\r\n' <"$DEST/etc/apk/arch")
[ "$APK_ARCH" = "aarch64" ] || die_code "$EXIT_ROOTFS" "etc/apk/arch=$APK_ARCH != aarch64"

BUSYBOX_MACHINE=$( { LC_ALL=C readelf -h "$DEST/bin/busybox" 2>/dev/null || true; } | sed -n 's/.*Machine:[[:space:]]*//p' | head -1)
case "$BUSYBOX_MACHINE" in
    AArch64) ;;
    *) die_code "$EXIT_ROOTFS" "bin/busybox n'est pas un ELF AArch64 (${BUSYBOX_MACHINE:-inconnu})" ;;
esac

# bin/sh doit etre un fichier ou un lien dont la cible reste sous le rootfs
SH_TYPE="fichier"
SH_TARGET=""
if [ -L "$DEST/bin/sh" ]; then
    SH_TYPE="lien"
    SH_TARGET=$(readlink "$DEST/bin/sh")
    case "$SH_TARGET" in
        /*)
            # lien absolu : il designe un chemin DANS le rootfs, pas sur l'hote
            sh_rel=${SH_TARGET#/}
            ;;
        *)
            sh_rel=$(cd "$DEST/bin" && realpath -m -- "$SH_TARGET" 2>/dev/null || true)
            case "$sh_rel" in
                "$DEST"/*) sh_rel=${sh_rel#"$DEST"/} ;;
                *) die_code "$EXIT_ROOTFS" "bin/sh sort du rootfs : $SH_TARGET" ;;
            esac
            ;;
    esac
    case "$sh_rel" in
        ..* | /*) die_code "$EXIT_ROOTFS" "bin/sh sort du rootfs : $SH_TARGET" ;;
    esac
    [ -f "$DEST/$sh_rel" ] || [ -L "$DEST/$sh_rel" ] ||
        die_code "$EXIT_ROOTFS" "bin/sh pointe une cible absente du rootfs : $SH_TARGET"
fi
[ -f "$DEST/bin/sh" ] || [ -L "$DEST/bin/sh" ] || die_code "$EXIT_ROOTFS" "bin/sh non resolu"

# --------------------------------------------------------------------------
# Rapports
# --------------------------------------------------------------------------
{
    printf '# depots apk detectes (lecture seule, aucune modification)\n'
    printf 'series_attendue=%s\n' "$DIST_SERIES"
    sed 's/^/repository=/' "$DEST/etc/apk/repositories"
    if grep -q "v3\.22" "$DEST/etc/apk/repositories"; then
        printf 'series_detected=oui\n'
    else
        printf 'series_detected=non\n'
    fi
} >"$REPORTS/repositories-detected.txt"

# manifeste d'arborescence : fichiers reguliers + liens documentes separement
( cd "$DEST" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ) >"$REPORTS/tree-manifest.sha256"
( cd "$DEST" && find . -type l -printf '%p -> %l\n' 2>/dev/null | sort ) >"$REPORTS/symlinks.txt"

REG_COUNT=$(cd "$DEST" && find . -type f | wc -l | tr -d ' ')
LINK_COUNT=$(cd "$DEST" && find . -type l | wc -l | tr -d ' ')
DIR_COUNT=$(cd "$DEST" && find . -type d | wc -l | tr -d ' ')

# --------------------------------------------------------------------------
# Reproductibilite de l'extraction (seconde extraction independante)
# --------------------------------------------------------------------------
TMP_EXT2=$(umask 077 && mktemp -d "$WORK_DIR/.a71-rootfs2-XXXXXXXX") || die_code "$EXIT_OUTPUT" "temporaire 2 impossible"
extract_one "$TMP_EXT2" || { rm -rf "$TMP_EXT2"; die_code "$EXIT_UNSAFE" "seconde extraction refusee"; }

( cd "$TMP_EXT2" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ) >"$REPORTS/tree-manifest-b.sha256"
( cd "$TMP_EXT2" && find . -type l -printf '%p -> %l\n' 2>/dev/null | sort ) >"$REPORTS/symlinks-b.txt"
( cd "$TMP_EXT2" && find . -printf '%y %m %p\n' 2>/dev/null | sort ) >"$REPORTS/modes-b.txt"
( cd "$DEST" && find . -printf '%y %m %p\n' 2>/dev/null | sort ) >"$REPORTS/modes-a.txt"

tree_match="no"
cmp -s "$REPORTS/tree-manifest.sha256" "$REPORTS/tree-manifest-b.sha256" && tree_match="yes"
sym_match="no"
cmp -s "$REPORTS/symlinks.txt" "$REPORTS/symlinks-b.txt" && sym_match="yes"
modes_match="no"
cmp -s "$REPORTS/modes-a.txt" "$REPORTS/modes-b.txt" && modes_match="yes"

overall="no"
[ "$tree_match" = "yes" ] && [ "$sym_match" = "yes" ] && [ "$modes_match" = "yes" ] && overall="yes"

{
    printf '# reproductibilite de l extraction du minirootfs\n'
    printf 'entries_a=%s\n' "$(find "$DEST" | wc -l | tr -d ' ')"
    printf 'entries_b=%s\n' "$(find "$TMP_EXT2" | wc -l | tr -d ' ')"
    printf 'tree_match=%s\n' "$tree_match"
    printf 'regular_files_match=%s\n' "$tree_match"
    printf 'symlinks_match=%s\n' "$sym_match"
    printf 'modes_match=%s\n' "$modes_match"
    printf 'overall_reproducible=%s\n' "$overall"
} >"$REPORTS/extraction-reproducibility.txt"

rm -rf "$TMP_EXT2"

# --------------------------------------------------------------------------
# Synthese + provenance
# --------------------------------------------------------------------------
RESULT="OK"
{
    printf 'result=%s\n' "$RESULT"
    printf 'distribution=%s\n' "$DIST_NAME"
    printf 'series=%s\n' "$DIST_SERIES"
    printf 'version=%s\n' "$DIST_VERSION"
    printf 'architecture=%s\n' "$DIST_ARCH"
    printf 'archive_filename=%s\n' "$ARCHIVE_NAME"
    printf 'archive_size_expected=%s\n' "$DIST_SIZE"
    printf 'archive_size_actual=%s\n' "$ARCHIVE_SIZE"
    printf 'sha256_expected=%s\n' "$DIST_SHA256"
    printf 'sha256_actual=%s\n' "$SHA256_ACTUAL"
    printf 'sha256_origin=manifest_official_published\n'
    printf 'sha256_match=yes\n'
    printf 'sha512_expected=%s\n' "$DIST_SHA512"
    printf 'sha512_actual=%s\n' "$SHA512_ACTUAL"
    printf 'sha512_origin=manifest_official_published\n'
    printf 'sha512_match=yes\n'
    printf 'signature_status=%s\n' "$SIG_STATUS"
    printf 'archive_validation=ok\n'
    printf 'extraction_validation=ok\n'
    printf 'rootfs_path=rootfs-base\n'
    printf 'alpine_release=%s\n' "$ALPINE_RELEASE"
    printf 'apk_arch=%s\n' "$APK_ARCH"
    printf 'busybox_elf_machine=%s\n' "$BUSYBOX_MACHINE"
    printf 'bin_sh_type=%s\n' "$SH_TYPE"
    printf 'regular_files=%s\n' "$REG_COUNT"
    printf 'symlinks=%s\n' "$LINK_COUNT"
    printf 'directories=%s\n' "$DIR_COUNT"
    printf 'cache_state=%s\n' "$CACHE_STATE"
    printf 'ownership_policy=host_user_extraction\n'
    printf 'ownership_preserved=no\n'
    printf 'permissions_policy=safe_archive_permissions\n'
    printf 'packages_installed=no\n'
    printf 'apk_executed=no\n'
    printf 'chroot_used=no\n'
    printf 'mount_used=no\n'
    printf 'qemu_used=no\n'
    printf 'modules_installed=no\n'
    printf 'depmod_executed=no\n'
    printf 'initramfs_created=no\n'
    printf 'boot_image_created=no\n'
    printf 'extraction_reproducible=%s\n' "$overall"
    printf 'runtime=not_tested\n'
    printf 'validation=provisional\n'
} >"$REPORTS/rootfs-summary.txt"

python3 - "$REPORTS/provenance.json" "$ARCHIVE_NAME" "$DIST_VERSION" "$DIST_ARCH" \
    "$DIST_SHA256" "$SHA256_ACTUAL" "$DIST_SHA512" "$SHA512_ACTUAL" "$DIST_SIZE" "$ARCHIVE_SIZE" \
    "$SIG_STATUS" "$ALPINE_RELEASE" "$APK_ARCH" "$BUSYBOX_MACHINE" "$REG_COUNT" "$LINK_COUNT" <<'PY'
import json
import sys

(report, archive, version, arch, sha256_exp, sha256_act, sha512_exp, sha512_act,
 size_exp, size_act, sig, alpine_release, apk_arch, busybox, nreg, nlink) = sys.argv[1:]

data = {
    "name": "alpine-minirootfs",
    "version": version,
    "architecture": arch,
    "archive": archive,
    "size_expected": int(size_exp),
    "size_actual": int(size_act),
    "sha256_expected": sha256_exp,
    "sha256_actual": sha256_act,
    "sha256_origin": "manifest_official_published",
    "sha512_expected": sha512_exp,
    "sha512_actual": sha512_act,
    "signature_status": sig,
    "alpine_release": alpine_release,
    "apk_arch": apk_arch,
    "busybox_elf_machine": busybox,
    "regular_files": int(nreg),
    "symlinks": int(nlink),
    "ownership_policy": "host_user_extraction",
    "ownership_preserved": False,
    "apk_executed": False,
    "chroot_used": False,
    "mount_used": False,
    "qemu_used": False,
    "modules_installed": False,
    "depmod_executed": False,
    "initramfs_created": False,
    "boot_image_created": False,
    "runtime_status": "not_tested",
    "validation_status": "provisional",
}
with open(report, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

say "rootfs pret : rootfs-base ($REG_COUNT fichiers, $LINK_COUNT liens)"
say "synthese : $REPORTS/rootfs-summary.txt"
exit "$EXIT_OK"
