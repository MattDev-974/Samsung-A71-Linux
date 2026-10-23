#!/usr/bin/env bash
# shellcheck shell=bash
#
# integrate-kernel-modules.sh - copie le rootfs Alpine de base, y integre les
# modules du build noyau reproductible et genere les metadonnees depmod.
#
# Aucun chroot, montage, QEMU, apk, execution de binaire AArch64, initramfs,
# boot.img ni flash. Le rootfs de base n'est jamais modifie.
#
# Usage :
#   ./scripts/integrate-kernel-modules.sh --manifest manifest.yaml \
#       --rootfs-base work/rootfs/rootfs-base --kernel-build work/kernel-build \
#       --output work/rootfs/rootfs-with-modules [--depmod PATH] [--force]
#
# Codes de sortie :
#   0 succes
#   2 erreur d'usage
#   3 manifeste ou release invalide
#   4 rootfs de base invalide
#   5 build noyau ou modules invalides
#   6 depmod absent, incompatible ou en echec
#   7 sortie refusee ou publication impossible
#   8 validation finale en echec

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PROG=$(basename "$0")

EXIT_OK=0
EXIT_USAGE=2
EXIT_MANIFEST=3
EXIT_ROOTFS=4
EXIT_MODULES=5
EXIT_DEPMOD=6
EXIT_OUTPUT=7
EXIT_FINAL=8

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() { say "$1"; printf 'Utilise --help.\n' >&2; exit "$EXIT_USAGE"; }
die_code() { local c=$1; shift; say "$*"; exit "$c"; }

usage() {
    cat <<EOF
$PROG - integration des modules noyau dans une copie du rootfs

Usage
  $PROG --manifest FILE --rootfs-base DIR --kernel-build DIR --output DIR \\
        [--depmod PATH] [--force]

Options
  --manifest FILE    manifeste du projet
  --rootfs-base DIR  rootfs Alpine de base (jamais modifie)
  --kernel-build DIR sortie de scripts/kernel-build.sh
  --output DIR       rootfs de travail avec modules (cree)
  --depmod PATH      outil depmod (defaut : recherche dans PATH)
  --force            accepte une sortie deja presente
  -h, --help         cette aide

Codes : 0 ok, 2 usage, 3 manifeste/release, 4 rootfs, 5 modules,
        6 depmod, 7 sortie, 8 validation finale
EOF
}

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
MANIFEST_FILE=""
ROOTFS_BASE=""
KERNEL_BUILD=""
OUT_DIR=""
DEPMOD_BIN=""
FORCE=0
SEEN=" "
mark_opt() {
    case "$SEEN" in *" $1 "*) usage_error "option repetee : --$1" ;; esac
    SEEN="$SEEN$1 "
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit "$EXIT_OK" ;;
        --manifest) mark_opt manifest; [ $# -ge 2 ] || usage_error "--manifest attend un fichier"; MANIFEST_FILE=$2; shift ;;
        --rootfs-base) mark_opt rootfs-base; [ $# -ge 2 ] || usage_error "--rootfs-base attend un repertoire"; ROOTFS_BASE=$2; shift ;;
        --kernel-build) mark_opt kernel-build; [ $# -ge 2 ] || usage_error "--kernel-build attend un repertoire"; KERNEL_BUILD=$2; shift ;;
        --output) mark_opt output; [ $# -ge 2 ] || usage_error "--output attend un repertoire"; OUT_DIR=$2; shift ;;
        --depmod) mark_opt depmod; [ $# -ge 2 ] || usage_error "--depmod attend un chemin"; DEPMOD_BIN=$2; shift ;;
        --force) mark_opt force; FORCE=1 ;;
        --manifest=*) mark_opt manifest; MANIFEST_FILE=${1#--manifest=} ;;
        --rootfs-base=*) mark_opt rootfs-base; ROOTFS_BASE=${1#--rootfs-base=} ;;
        --kernel-build=*) mark_opt kernel-build; KERNEL_BUILD=${1#--kernel-build=} ;;
        --output=*) mark_opt output; OUT_DIR=${1#--output=} ;;
        --depmod=*) mark_opt depmod; DEPMOD_BIN=${1#--depmod=} ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

for v in MANIFEST_FILE ROOTFS_BASE KERNEL_BUILD OUT_DIR; do
    [ -n "${!v}" ] || usage_error "--$(printf '%s' "$v" | tr 'A-Z_' 'a-z-') est obligatoire"
done

umask 077

# --------------------------------------------------------------------------
# Manifeste
# --------------------------------------------------------------------------
[ -f "$MANIFEST_FILE" ] || die_code "$EXIT_MANIFEST" "manifeste absent"
mval() {
    local key=$1 val rc=0
    val=$(A71_MANIFEST="$MANIFEST_FILE" bash -c '. "$1/scripts/common.sh"; manifest_get "$A71_MANIFEST" "$2"' _ "$REPO_ROOT" "$key") || rc=$?
    [ "$rc" -eq 0 ] || die_code "$EXIT_MANIFEST" "manifeste : cle absente ($key)"
    case "$val" in '' | TODO_*) die_code "$EXIT_MANIFEST" "manifeste : $key non resolu ($val)" ;; esac
    printf '%s\n' "$val"
}

EXPECTED_RELEASE=$(mval kernel.expected_release)
ROOTFS_VERSION=$(mval distribution.version)
ROOTFS_ARCH=$(mval distribution.architecture)

# --------------------------------------------------------------------------
# Chemins
# --------------------------------------------------------------------------
[ -d "$ROOTFS_BASE" ] || die_code "$EXIT_ROOTFS" "rootfs de base absent"
[ -L "$ROOTFS_BASE" ] && die_code "$EXIT_ROOTFS" "rootfs de base est un lien symbolique"
ROOTFS_BASE=$(cd "$ROOTFS_BASE" && pwd -P)

[ -d "$KERNEL_BUILD" ] || die_code "$EXIT_MODULES" "sortie de build absente"
KERNEL_BUILD=$(cd "$KERNEL_BUILD" && pwd -P)

if [ -L "$OUT_DIR" ]; then die_code "$EXIT_OUTPUT" "sortie est un lien symbolique"; fi
case "$OUT_DIR" in *$'\n'*) die_code "$EXIT_OUTPUT" "sortie contient un retour a la ligne" ;; esac
# Canonicalisation SANS creation : sinon un chemin refuse (par exemple dans le
# rootfs de base) laisserait un repertoire parasite derriere lui.
OUT_DIR=$(realpath -m -- "$OUT_DIR") || die_code "$EXIT_OUTPUT" "chemin de sortie invalide"

[ "$OUT_DIR" = "/" ] && die_code "$EXIT_OUTPUT" "sortie = /"
[ "$OUT_DIR" = "$ROOTFS_BASE" ] && die_code "$EXIT_OUTPUT" "sortie = rootfs de base"
case "$OUT_DIR" in "$ROOTFS_BASE"/*) die_code "$EXIT_OUTPUT" "sortie dans le rootfs de base" ;; esac
case "$ROOTFS_BASE" in "$OUT_DIR"/*) die_code "$EXIT_OUTPUT" "rootfs de base dans la sortie" ;; esac
case "$OUT_DIR" in "$KERNEL_BUILD"/*) die_code "$EXIT_OUTPUT" "sortie dans le build noyau" ;; esac
if [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
    [ "$FORCE" = "1" ] || die_code "$EXIT_OUTPUT" "sortie non vide (utilise --force)"
    [ "$OUT_DIR" != "/" ] && [ "$OUT_DIR" != "$ROOTFS_BASE" ] || die_code "$EXIT_OUTPUT" "suppression dangereuse refusee"
    find "$OUT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || die_code "$EXIT_OUTPUT" "nettoyage impossible"
fi

WORK=$(mktemp -d "$(dirname "$OUT_DIR")/.a71-rootfs-work-XXXXXXXX") ||
    die_code "$EXIT_OUTPUT" "repertoire de travail impossible"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT_DIR" || die_code "$EXIT_OUTPUT" "creation de la sortie impossible"
OUT_DIR=$(cd "$OUT_DIR" && pwd -P) || die_code "$EXIT_OUTPUT" "sortie inaccessible"

REPORTS="$WORK/reports"
mkdir -p "$REPORTS"
TMPDIR_BASE_FILES=$(mktemp -d)/base.sha256
TMPDIR_COPY_FILES=$(mktemp -d)/copy.sha256

# --------------------------------------------------------------------------
# Validation du rootfs de base
# --------------------------------------------------------------------------
ROOTFS_ALPINE=$(tr -d '\r\n' <"$ROOTFS_BASE/etc/alpine-release") ||
    die_code "$EXIT_ROOTFS" "etc/alpine-release illisible"
[ "$ROOTFS_ALPINE" = "$ROOTFS_VERSION" ] ||
    die_code "$EXIT_ROOTFS" "alpine-release $ROOTFS_ALPINE != $ROOTFS_VERSION"
ROOTFS_APK_ARCH=$(tr -d '\r\n' <"$ROOTFS_BASE/etc/apk/arch") ||
    die_code "$EXIT_ROOTFS" "etc/apk/arch illisible"
[ "$ROOTFS_APK_ARCH" = "$ROOTFS_ARCH" ] ||
    die_code "$EXIT_ROOTFS" "apk/arch $ROOTFS_APK_ARCH != $ROOTFS_ARCH"
BB_MACHINE=$( { LC_ALL=C readelf -h "$ROOTFS_BASE/bin/busybox" 2>/dev/null || true; } |
    sed -n 's/.*Machine:[[:space:]]*//p' | head -1)
[ "$BB_MACHINE" = "AArch64" ] || die_code "$EXIT_ROOTFS" "busybox non AArch64 (${BB_MACHINE:-inconnu})"
if find "$ROOTFS_BASE" \( -type b -o -type c -o -type p -o -type s \) 2>/dev/null | grep -q .; then
    die_code "$EXIT_ROOTFS" "rootfs de base contient un fichier special"
fi
[ -e "$ROOTFS_BASE/lib/modules/$EXPECTED_RELEASE" ] &&
    die_code "$EXIT_ROOTFS" "release deja presente dans le rootfs de base"

# empreinte du rootfs de base (avant)
BASE_MANIFEST_BEFORE=$(mktemp "$REPORTS/.base-before-XXXXXXXX")
( cd "$ROOTFS_BASE" && find . -printf '%y %m %p %l\n' 2>/dev/null | sort ) >"$BASE_MANIFEST_BEFORE"

# --------------------------------------------------------------------------
# Validation du build noyau
# --------------------------------------------------------------------------
SUM="$KERNEL_BUILD/build-summary.txt"
[ -f "$SUM" ] || die_code "$EXIT_MODULES" "build-summary.txt absent"
sfield() { sed -n "s/^$1=//p" "$SUM" | head -1; }
[ "$(sfield result)" = "OK" ] || die_code "$EXIT_MODULES" "build result != OK"
[ "$(sfield build)" = "completed" ] || die_code "$EXIT_MODULES" "build != completed"
[ "$(sfield release_match)" = "match" ] || die_code "$EXIT_MODULES" "release_match != match"
[ "$(sfield requirements_failures)" = "0" ] || die_code "$EXIT_MODULES" "exigences en echec au build"
SOURCE_RELEASE=$(sfield built_release)
[ "$SOURCE_RELEASE" = "$EXPECTED_RELEASE" ] ||
    die_code "$EXIT_MODULES" "release du build ($SOURCE_RELEASE) != attendue ($EXPECTED_RELEASE)"
[ "$(sfield module_elf_check)" = "aarch64" ] || die_code "$EXIT_MODULES" "verification ELF du build absente"

SRC_MOD_DIR="$(sfield module_release_directory)"
case "$SRC_MOD_DIR" in
    modules-install/lib/modules/*) ;;
    *) die_code "$EXIT_MODULES" "chemin de modules inattendu dans la synthese" ;;
esac
SRC_MOD_PATH="$KERNEL_BUILD/$SRC_MOD_DIR"
[ -d "$SRC_MOD_PATH" ] || die_code "$EXIT_MODULES" "repertoire de modules source absent"
[ -L "$SRC_MOD_PATH" ] && die_code "$EXIT_MODULES" "repertoire de modules source symlink"

mapfile -t SRC_KO < <(find "$SRC_MOD_PATH" -type f -name '*.ko' 2>/dev/null | sort)
SRC_COUNT=${#SRC_KO[@]}
[ "$SRC_COUNT" -gt 0 ] || die_code "$EXIT_MODULES" "aucun module source"
[ "$SRC_COUNT" = "$(sfield module_count)" ] ||
    die_code "$EXIT_MODULES" "comptage source ($SRC_COUNT) != synthese ($(sfield module_count))"

# aucun module legacy
case "$SRC_MOD_PATH" in
    *base/lib/modules*) die_code "$EXIT_MODULES" "modules legacy refuses" ;;
esac

# ELF AArch64 de chaque module non compresse (echantillon complet : rapide)
for f in "${SRC_KO[@]}"; do
    m=$( { LC_ALL=C readelf -h "$f" 2>/dev/null || true; } | sed -n 's/.*Machine:[[:space:]]*//p' | head -1)
    [ "$m" = "AArch64" ] || die_code "$EXIT_MODULES" "module non AArch64 : $(basename "$f")"
done

# inventaire source deterministe
MOD_SRC_LIST="$REPORTS/modules-source.sha256"
( cd "$SRC_MOD_PATH" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ) >"$MOD_SRC_LIST"

# --------------------------------------------------------------------------
# depmod : decouverte et qualification
# --------------------------------------------------------------------------
if [ -z "$DEPMOD_BIN" ]; then
    DEPMOD_BIN=$(command -v depmod 2>/dev/null || true)
    [ -n "$DEPMOD_BIN" ] || die_code "$EXIT_DEPMOD" "depmod introuvable dans PATH"
fi
[ -e "$DEPMOD_BIN" ] || die_code "$EXIT_DEPMOD" "depmod absent : $(basename "$DEPMOD_BIN")"
# On execute le NOM APPELE (depmod), jamais la cible resolue : kmod est un
# binaire multi-applets, et "/usr/bin/kmod -b ..." echoue sans sous-commande.
DEPMOD_EXEC=$DEPMOD_BIN
DEPMOD_REAL=$(readlink -f "$DEPMOD_BIN")
[ -f "$DEPMOD_REAL" ] || die_code "$EXIT_DEPMOD" "depmod n'est pas un fichier regulier"
case "$DEPMOD_REAL" in
    "$OUT_DIR"/*) die_code "$EXIT_DEPMOD" "depmod situe dans le rootfs cible" ;;
esac
depmod_machine=$( { LC_ALL=C readelf -h "$DEPMOD_REAL" 2>/dev/null || true; } | sed -n 's/.*Machine:[[:space:]]*//p' | head -1)
[ "$depmod_machine" = "AArch64" ] && die_code "$EXIT_DEPMOD" "depmod est un binaire AArch64 (rootfs)"

DEPMOD_VERSION=$(LC_ALL=C "$DEPMOD_EXEC" --version 2>/dev/null | head -1 || true)
case "$DEPMOD_VERSION" in
    *kmod* | *depmod*) ;;
    *) die_code "$EXIT_DEPMOD" "version de depmod non reconnue : ${DEPMOD_VERSION:-vide}" ;;
esac
DEPMOD_SHA=$(sha256sum "$DEPMOD_REAL" | cut -d' ' -f1)

# --------------------------------------------------------------------------
# Copie du rootfs de base (travail)
# --------------------------------------------------------------------------
cp -a "$ROOTFS_BASE/." "$WORK/" || die_code "$EXIT_OUTPUT" "copie du rootfs impossible"

if find "$WORK" \( -type b -o -type c -o -type p -o -type s \) 2>/dev/null | grep -q .; then
    die_code "$EXIT_FINAL" "fichier special apparu dans la copie"
fi
if [ -e "$WORK/lib/modules/$EXPECTED_RELEASE" ]; then
    die_code "$EXIT_FINAL" "release deja presente dans la copie"
fi
( cd "$ROOTFS_BASE" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ) >"$TMPDIR_BASE_FILES"
( cd "$WORK" && find . -type f -not -path './reports/*' -print0 | sort -z | xargs -0 -r sha256sum ) >"$TMPDIR_COPY_FILES"
cmp -s "$TMPDIR_BASE_FILES" "$TMPDIR_COPY_FILES" ||
    die_code "$EXIT_FINAL" "copie du rootfs non conforme (contenu)"
rm -f "$TMPDIR_BASE_FILES" "$TMPDIR_COPY_FILES"

# --------------------------------------------------------------------------
# Copie des modules
# --------------------------------------------------------------------------
DEST_MOD_PATH="$WORK/lib/modules/$EXPECTED_RELEASE"
mkdir -p "$DEST_MOD_PATH"
cp -a "$SRC_MOD_PATH/." "$DEST_MOD_PATH/" || die_code "$EXIT_MODULES" "copie des modules impossible"

mapfile -t DST_KO < <(find "$DEST_MOD_PATH" -type f -name '*.ko' 2>/dev/null | sort)
DST_COUNT=${#DST_KO[@]}
[ "$DST_COUNT" = "$SRC_COUNT" ] ||
    die_code "$EXIT_FINAL" "modules copies ($DST_COUNT) != source ($SRC_COUNT)"

MOD_DST_LIST="$REPORTS/modules-rootfs.sha256"
( cd "$DEST_MOD_PATH" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ) >"$MOD_DST_LIST"

MOD_DIFF="$REPORTS/modules-copy.diff"
diff -u --label modules-source --label modules-rootfs "$MOD_SRC_LIST" "$MOD_DST_LIST" >"$MOD_DIFF" 2>/dev/null || true
MOD_COPY_MATCH="no"
[ -s "$MOD_DIFF" ] || MOD_COPY_MATCH="yes"
[ "$MOD_COPY_MATCH" = "yes" ] || die_code "$EXIT_FINAL" "copie des modules non conforme"

# --------------------------------------------------------------------------
# depmod : execution isolee
# --------------------------------------------------------------------------
DEPMOD_LOG="$REPORTS/.depmod.log"
set +e
env -i LC_ALL=C LANG=C TZ=UTC PATH=/usr/bin:/bin \
    "$DEPMOD_EXEC" -b "$WORK" -C /dev/null "$EXPECTED_RELEASE" >"$DEPMOD_LOG" 2>&1
depmod_rc=$?
set -e
[ "$depmod_rc" -eq 0 ] || die_code "$EXIT_DEPMOD" "depmod a echoue (code $depmod_rc)"

# fichiers generes
GEN_LIST="$REPORTS/depmod-generated-files.txt"
( cd "$DEST_MOD_PATH" && find . -maxdepth 1 -name 'modules.*' -printf '%f\n' | sort ) >"$GEN_LIST"
for f in modules.dep modules.dep.bin modules.alias modules.alias.bin modules.softdep modules.symbols modules.symbols.bin; do
    [ -f "$DEST_MOD_PATH/$f" ] || die_code "$EXIT_DEPMOD" "metadonnee manquante : $f"
    [ -s "$DEST_MOD_PATH/$f" ] || die_code "$EXIT_DEPMOD" "metadonnee vide : $f"
done

# modules.dep : chemins relatifs, pas de '..', pas d'autre release, deps existantes
[ -s "$DEST_MOD_PATH/modules.dep" ] || die_code "$EXIT_FINAL" "modules.dep vide"
awk -F: '{print $1}' "$DEST_MOD_PATH/modules.dep" >"$REPORTS/.dep-left"
while IFS= read -r left; do
    [ -n "$left" ] || continue
    case "$left" in
        /*) die_code "$EXIT_FINAL" "modules.dep : chemin absolu ($left)" ;;
        *..*) die_code "$EXIT_FINAL" "modules.dep : '..' dans un chemin ($left)" ;;
    esac
    [ -f "$DEST_MOD_PATH/${left#./}" ] || [ -f "$DEST_MOD_PATH/$(printf '%s' "$left" | sed 's|^kernel/|kernel/|')" ] ||
        die_code "$EXIT_FINAL" "modules.dep reference un module absent : $left"
done <"$REPORTS/.dep-left"
rm -f "$REPORTS/.dep-left"

if grep -qE 'lib/modules/[0-9]+\.[0-9]+[^/]*/' "$DEST_MOD_PATH/modules.dep" &&
    ! grep -qE "lib/modules/$EXPECTED_RELEASE/" "$DEST_MOD_PATH/modules.dep"; then
    die_code "$EXIT_FINAL" "modules.dep reference une autre release"
fi

# --------------------------------------------------------------------------
# Seconde integration independante (reproductibilite depmod)
# --------------------------------------------------------------------------
WORK2=$(mktemp -d "$(dirname "$OUT_DIR")/.a71-rootfs-work2-XXXXXXXX") ||
    die_code "$EXIT_OUTPUT" "second repertoire de travail impossible"
cp -a "$ROOTFS_BASE/." "$WORK2/" || die_code "$EXIT_OUTPUT" "seconde copie impossible"
mkdir -p "$WORK2/lib/modules/$EXPECTED_RELEASE"
cp -a "$SRC_MOD_PATH/." "$WORK2/lib/modules/$EXPECTED_RELEASE/" || die_code "$EXIT_MODULES" "seconde copie des modules impossible"
set +e
env -i LC_ALL=C LANG=C TZ=UTC PATH=/usr/bin:/bin \
    "$DEPMOD_EXEC" -b "$WORK2" -C /dev/null "$EXPECTED_RELEASE" >/dev/null 2>&1
rc2=$?
set -e
[ "$rc2" -eq 0 ] || die_code "$EXIT_DEPMOD" "second depmod a echoue"

DEST2="$WORK2/lib/modules/$EXPECTED_RELEASE"
text_match="no"
bin_match="no"
fileset_match="no"
for f in modules.dep modules.alias modules.softdep modules.symbols; do
    cmp -s "$DEST_MOD_PATH/$f" "$DEST2/$f" || text_match="no"
done
text_match="yes"
for f in modules.dep modules.alias modules.softdep modules.symbols; do
    cmp -s "$DEST_MOD_PATH/$f" "$DEST2/$f" || text_match="no"
done
bin_match="yes"
for f in modules.dep.bin modules.alias.bin modules.symbols.bin; do
    cmp -s "$DEST_MOD_PATH/$f" "$DEST2/$f" || bin_match="no"
done
( cd "$DEST_MOD_PATH" && find . -maxdepth 1 -name 'modules.*' -printf '%f\n' | sort ) >"$REPORTS/.gen-a"
( cd "$DEST2" && find . -maxdepth 1 -name 'modules.*' -printf '%f\n' | sort ) >"$REPORTS/.gen-b"
cmp -s "$REPORTS/.gen-a" "$REPORTS/.gen-b" && fileset_match="yes"
rm -f "$REPORTS/.gen-a" "$REPORTS/.gen-b"

overall="no"
[ "$text_match" = "yes" ] && [ "$bin_match" = "yes" ] && [ "$fileset_match" = "yes" ] && overall="yes"

{
    printf 'depmod_version=%s\n' "$DEPMOD_VERSION"
    printf 'release=%s\n' "$EXPECTED_RELEASE"
    printf 'text_metadata_match=%s\n' "$text_match"
    printf 'binary_metadata_match=%s\n' "$bin_match"
    printf 'generated_file_set_match=%s\n' "$fileset_match"
    printf 'overall_reproducible=%s\n' "$overall"
} >"$REPORTS/depmod-reproducibility.txt"

rm -rf "$WORK2"

# --------------------------------------------------------------------------
# Validation finale
# --------------------------------------------------------------------------
FINAL_ALPINE=$(tr -d '\r\n' <"$WORK/etc/alpine-release")
[ "$FINAL_ALPINE" = "$ROOTFS_VERSION" ] || die_code "$EXIT_FINAL" "version Alpine modifiee"
FINAL_ARCH=$(tr -d '\r\n' <"$WORK/etc/apk/arch")
[ "$FINAL_ARCH" = "$ROOTFS_ARCH" ] || die_code "$EXIT_FINAL" "architecture modifiee"
FINAL_BB=$( { LC_ALL=C readelf -h "$WORK/bin/busybox" 2>/dev/null || true; } |
    sed -n 's/.*Machine:[[:space:]]*//p' | head -1)
[ "$FINAL_BB" = "AArch64" ] || die_code "$EXIT_FINAL" "busybox final invalide"
if find "$WORK" \( -type b -o -type c -o -type p -o -type s \) 2>/dev/null | grep -q .; then
    die_code "$EXIT_FINAL" "fichier special dans la sortie"
fi

BASE_MANIFEST_AFTER=$(mktemp "$REPORTS/.base-after-XXXXXXXX")
( cd "$ROOTFS_BASE" && find . -printf '%y %m %p %l\n' 2>/dev/null | sort ) >"$BASE_MANIFEST_AFTER"
BASE_UNCHANGED="no"
cmp -s "$BASE_MANIFEST_BEFORE" "$BASE_MANIFEST_AFTER" && BASE_UNCHANGED="yes"
rm -f "$BASE_MANIFEST_BEFORE" "$BASE_MANIFEST_AFTER"
[ "$BASE_UNCHANGED" = "yes" ] || die_code "$EXIT_FINAL" "rootfs de base modifie"

FINAL_COUNT=$(find "$WORK/lib/modules/$EXPECTED_RELEASE" -type f -name '*.ko' | wc -l | tr -d ' ')
[ "$FINAL_COUNT" = "$SRC_COUNT" ] || die_code "$EXIT_FINAL" "comptage final de modules incoherent"

( cd "$WORK" && find . -type f -not -path './reports/*' -print0 | sort -z | xargs -0 -r sha256sum ) >"$REPORTS/rootfs-with-modules.sha256"

# --------------------------------------------------------------------------
# Rapports
# --------------------------------------------------------------------------
{
    printf 'result=OK\n'
    printf 'rootfs_version=%s\n' "$FINAL_ALPINE"
    printf 'rootfs_architecture=%s\n' "$FINAL_ARCH"
    printf 'kernel_release_expected=%s\n' "$EXPECTED_RELEASE"
    printf 'kernel_release_source=%s\n' "$SOURCE_RELEASE"
    printf 'kernel_release_destination=%s\n' "$EXPECTED_RELEASE"
    printf 'kernel_release_match=yes\n'
    printf 'source_module_count=%s\n' "$SRC_COUNT"
    printf 'destination_module_count=%s\n' "$FINAL_COUNT"
    printf 'module_count_match=yes\n'
    printf 'module_copy_hash_match=%s\n' "$MOD_COPY_MATCH"
    printf 'depmod_origin=host\n'
    printf 'depmod_path=host-command:depmod\n'
    printf 'depmod_version=%s\n' "$DEPMOD_VERSION"
    printf 'depmod_result=ok\n'
    printf 'depmod_text_metadata_match=%s\n' "$text_match"
    printf 'depmod_binary_metadata_match=%s\n' "$bin_match"
    printf 'depmod_overall_reproducible=%s\n' "$overall"
    printf 'rootfs_base_unchanged=%s\n' "$BASE_UNCHANGED"
    printf 'ownership_policy=host_user_copy\n'
    printf 'ownership_preserved=no\n'
    printf 'packages_installed=no\n'
    printf 'apk_executed=no\n'
    printf 'chroot_used=no\n'
    printf 'mount_used=no\n'
    printf 'qemu_used=no\n'
    printf 'initramfs_created=no\n'
    printf 'boot_image_created=no\n'
    printf 'runtime=not_tested\n'
    printf 'validation=provisional\n'
} >"$REPORTS/integration-summary.txt"

{
    printf '# outil depmod\n'
    printf 'depmod_origin=host\n'
    printf 'depmod_path=host-command:depmod\n'
    printf 'depmod_version=%s\n' "$DEPMOD_VERSION"
    printf 'depmod_sha256=%s\n' "$DEPMOD_SHA"
    printf 'depmod_arch_machine=%s\n' "${depmod_machine:-x86-64}"
    printf 'depmod_isolation=env -i LC_ALL=C LANG=C TZ=UTC PATH=/usr/bin:/bin; -b <rootfs> -C /dev/null\n'
} >"$REPORTS/depmod-version.txt"

python3 - "$REPORTS/provenance.json" "$EXPECTED_RELEASE" "$SRC_COUNT" \
    "$DEPMOD_VERSION" "$DEPMOD_SHA" "$text_match" "$bin_match" "$overall" <<'PY'
import json
import sys

(report, release, count, depmod_version, depmod_sha, text_match, bin_match, overall) = sys.argv[1:]
data = {
    "name": "rootfs-with-kernel-modules",
    "kernel_release": release,
    "module_count": int(count),
    "depmod": {
        "origin": "host",
        "path_id": "host-command:depmod",
        "version": depmod_version,
        "sha256": depmod_sha,
        "isolation": "env -i + -b <rootfs> -C /dev/null",
    },
    "depmod_reproducibility": {
        "text_match": text_match,
        "binary_match": bin_match,
        "overall": overall,
    },
    "ownership_policy": "host_user_copy",
    "ownership_preserved": False,
    "apk_executed": False,
    "chroot_used": False,
    "mount_used": False,
    "qemu_used": False,
    "initramfs_created": False,
    "boot_image_created": False,
    "runtime_status": "not_tested",
    "validation_status": "provisional",
}
with open(report, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

rm -f "$DEPMOD_LOG"

# --------------------------------------------------------------------------
# Publication atomique (apres ecriture de tous les rapports)
# --------------------------------------------------------------------------
if [ -e "$OUT_DIR" ] && [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
    find "$OUT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + ||
        die_code "$EXIT_OUTPUT" "nettoyage final impossible"
fi
cp -a "$WORK/." "$OUT_DIR/" || die_code "$EXIT_OUTPUT" "publication impossible"

say "integration terminee : $FINAL_COUNT modules, depmod $DEPMOD_VERSION"
say "synthese : $REPORTS/integration-summary.txt"
exit "$EXIT_OK"
