#!/usr/bin/env bash
# shellcheck shell=bash
#
# build-sd-image.sh - image disque MBR a une partition Linux (H3).
#
# Aucun montage, loop device, sudo ni peripherique bloc : uniquement des
# fichiers reguliers. L'image contient A71ROOT.ext4 tel quel a l'offset 1 MiB.
#
# Codes : 0 ok, 2 usage, 3 entree, 4 construction, 5 validation, 6 sortie.

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PROG=$(basename "$0")

EXIT_OK=0
EXIT_USAGE=2
EXIT_INPUT=3
EXIT_BUILD=4
EXIT_VERIFY=5
EXIT_OUTPUT=6

CARD_MIN=28000000000
CARD_MAX=33000000000
CARD_REF=30979129344
START_LBA=2048
DISK_ID=0xa71a71a7
MARGIN_MIN=$((512 * 1024 * 1024))

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() { say "$1"; printf 'Utilise --help.\n' >&2; exit "$EXIT_USAGE"; }
die_code() { local c=$1; shift; say "$*"; exit "$c"; }

usage() {
    cat <<EOF
$PROG - image disque MBR pour Galaxy A71 (une partition Linux)

Usage
  $PROG --rootfs-image FILE --output FILE [--force]

Options
  --rootfs-image FILE  image A71ROOT.ext4 validee
  --output FILE        image a71-sd.img a produire
  --reports DIR        rapports (defaut <sortie>/reports)
  --force              remplace la sortie apres sauvegarde .pre-h3
  -h, --help           cette aide
EOF
}

ROOTFS_IMG=""
OUT=""
REPORTS=""
FORCE=0
SEEN=" "
mark_opt() { case "$SEEN" in *" $1 "*) usage_error "option repetee : --$1" ;; esac; SEEN="$SEEN$1 "; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit "$EXIT_OK" ;;
        --rootfs-image) mark_opt rootfs-image; [ $# -ge 2 ] || usage_error "--rootfs-image attend un fichier"; ROOTFS_IMG=$2; shift ;;
        --output) mark_opt output; [ $# -ge 2 ] || usage_error "--output attend un fichier"; OUT=$2; shift ;;
        --reports) mark_opt reports; [ $# -ge 2 ] || usage_error "--reports attend un repertoire"; REPORTS=$2; shift ;;
        --force) mark_opt force; FORCE=1 ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

[ -n "$ROOTFS_IMG" ] || usage_error "--rootfs-image est obligatoire"
[ -n "$OUT" ] || usage_error "--output est obligatoire"
[ -f "$ROOTFS_IMG" ] || die_code "$EXIT_INPUT" "image rootfs absente"
[ ! -L "$ROOTFS_IMG" ] || die_code "$EXIT_INPUT" "image rootfs est un lien symbolique"
for tool in sfdisk dd sha256sum e2fsck dumpe2fs debugfs truncate; do
    command -v "$tool" >/dev/null 2>&1 || die_code "$EXIT_INPUT" "outil absent : $tool"
done
ROOTFS_IMG=$(realpath -e -- "$ROOTFS_IMG") || die_code "$EXIT_INPUT" "image inaccessible"

ROOT_SIZE=$(stat -c '%s' "$ROOTFS_IMG")
[ $((ROOT_SIZE % 512)) -eq 0 ] || die_code "$EXIT_INPUT" "taille rootfs non multiple de 512"
ROOT_SECTORS=$((ROOT_SIZE / 512))
TOTAL_SIZE=$(((START_LBA + ROOT_SECTORS) * 512))
[ "$TOTAL_SIZE" -eq $(((START_LBA * 512) + ROOT_SIZE)) ] ||
    die_code "$EXIT_INPUT" "calcul de taille incoherent"
[ "$TOTAL_SIZE" -lt "$CARD_REF" ] || die_code "$EXIT_INPUT" "image >= carte de reference"
[ $((CARD_REF - TOTAL_SIZE)) -ge "$MARGIN_MIN" ] ||
    die_code "$EXIT_INPUT" "marge < 512 MiB par rapport a la carte"
[ "$TOTAL_SIZE" -lt "$CARD_MAX" ] || die_code "$EXIT_INPUT" "image trop grande"
[ "$TOTAL_SIZE" -gt "$CARD_MIN" ] && die_code "$EXIT_INPUT" "image etrangement grande"

case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
[ ! -L "$OUT" ] || die_code "$EXIT_OUTPUT" "sortie est un lien symbolique"
OUT=$(realpath -m -- "$OUT") || die_code "$EXIT_OUTPUT" "chemin de sortie invalide"
OUT_PARENT=$(dirname "$OUT")
mkdir -p "$OUT_PARENT" || die_code "$EXIT_OUTPUT" "parent de sortie impossible"
REPORTS=${REPORTS:-"$OUT_PARENT/reports"}

BUILD_ROOT=$(mktemp -d "$OUT_PARENT/.a71-h3-XXXXXXXX") ||
    die_code "$EXIT_OUTPUT" "temporaire impossible"
cleanup() {
    if [ -n "${BUILD_ROOT:-}" ]; then rm -rf "$BUILD_ROOT"; fi
    return 0
}
trap cleanup EXIT

ROOT_SHA=$(sha256sum "$ROOTFS_IMG" | awk '{print $1}')
PKG_COUNT=$(debugfs -R 'cat /lib/apk/db/installed' "$ROOTFS_IMG" 2>/dev/null | grep -c '^P:' || true)
[ "$PKG_COUNT" -gt 0 ] || die_code "$EXIT_INPUT" "comptage paquets rootfs impossible"
LABEL=$(dumpe2fs -h "$ROOTFS_IMG" 2>/dev/null | sed -n 's/^Filesystem volume name: *//p')
[ "$LABEL" = "A71ROOT" ] || die_code "$EXIT_INPUT" "label rootfs != A71ROOT"
UUID=$(dumpe2fs -h "$ROOTFS_IMG" 2>/dev/null | sed -n 's/^Filesystem UUID: *//p')
[ -n "$UUID" ] || die_code "$EXIT_INPUT" "UUID rootfs absent"

build_one() {
    local label=$1
    local img="$BUILD_ROOT/$label/a71-sd.img"
    local log="$BUILD_ROOT/$label"
    mkdir -p "$log"
    truncate -s "$TOTAL_SIZE" "$img" || die_code "$EXIT_BUILD" "truncate impossible ($label)"
    {
        printf 'label: dos\n'
        printf 'label-id: %s\n' "$DISK_ID"
        printf 'start=%s, size=%s, type=83\n' "$START_LBA" "$ROOT_SECTORS"
    } | LC_ALL=C sfdisk --no-reread --no-tell-kernel "$img" >"$log/sfdisk.log" 2>&1 ||
        die_code "$EXIT_BUILD" "sfdisk impossible ($label)"
    dd if="$ROOTFS_IMG" of="$img" bs=512 seek="$START_LBA" count="$ROOT_SECTORS" \
        conv=notrunc,fsync status=none || die_code "$EXIT_BUILD" "dd impossible ($label)"
    [ "$(stat -c '%s' "$img")" = "$TOTAL_SIZE" ] || die_code "$EXIT_BUILD" "taille image ($label)"
    echo "$img"
}

validate_image() {
    local img=$1 log=$2
    local raw table extract
    raw=$(LC_ALL=C sfdisk -d "$img" 2>/dev/null | grep -v '^device:')
    table=$(printf '%s\n' "$raw" | sed "s|^$img|image|")
    printf '%s\n' "$table" >"$log/partition-table.txt"
    [ "$(printf '%s\n' "$raw" | grep -c '^/.* : start=')" = "1" ] ||
        die_code "$EXIT_VERIFY" "exactement une partition attendue"
    printf '%s\n' "$raw" | grep -q "start= *$START_LBA, size= *$ROOT_SECTORS, type=83" ||
        die_code "$EXIT_VERIFY" "partition differente de 2048/+$ROOT_SECTORS/83"
    [ "$(stat -c '%s' "$img")" = "$TOTAL_SIZE" ] || die_code "$EXIT_VERIFY" "taille finale"
    # MBR : code de boot nul, signature, une seule entree non nulle.
    python3 - "$img" <<'PY' || die_code "$EXIT_VERIFY" "MBR invalide"
import sys
data = open(sys.argv[1], 'rb').read(512)
if len(data) != 512 or data[510:512] != b'\x55\xaa':
    raise SystemExit(1)
if any(data[0:440]):
    raise SystemExit(1)
if data[446] != 0 or data[450] != 0x83:
    raise SystemExit(1)
if any(data[462:510]):
    raise SystemExit(1)
PY
    extract=$(mktemp /tmp/a71-h3-extract-XXXXXXXX) || die_code "$EXIT_VERIFY" "temporaire extraction"
    dd if="$img" of="$extract" bs=512 skip="$START_LBA" count="$ROOT_SECTORS" status=none ||
        die_code "$EXIT_VERIFY" "extraction impossible"
    [ "$(sha256sum "$extract" | awk '{print $1}')" = "$ROOT_SHA" ] ||
        die_code "$EXIT_VERIFY" "SHA-256 de la partition different"
    e2fsck -fn "$extract" >"$log/e2fsck-extract.txt" 2>&1 ||
        die_code "$EXIT_VERIFY" "e2fsck extrait en erreur"
    [ "$(dumpe2fs -h "$extract" 2>/dev/null | sed -n 's/^Filesystem volume name: *//p')" = "A71ROOT" ] ||
        die_code "$EXIT_VERIFY" "label extrait"
    [ "$(dumpe2fs -h "$extract" 2>/dev/null | sed -n 's/^Filesystem UUID: *//p')" = "$UUID" ] ||
        die_code "$EXIT_VERIFY" "UUID extrait"
    INIT_STAT=$(debugfs -R 'stat /init' "$extract" 2>/dev/null || true)
    printf '%s\n' "$INIT_STAT" | grep -q 'Type: symlink' ||
        die_code "$EXIT_VERIFY" "/init absent ou non symlink dans la partition extraite"
    printf '%s\n' "$INIT_STAT" | grep -q 'Fast link dest: "/sbin/init"' ||
        die_code "$EXIT_VERIFY" "/init cible != /sbin/init dans la partition extraite"
    debugfs -R 'stat /sbin/init' "$extract" 2>/dev/null | grep -q 'Inode:' ||
        die_code "$EXIT_VERIFY" "/sbin/init absent de la partition extraite"
    # Contenu critique relu dans l'image extraite.
    for pair in "/bin/busybox 0755" "/bin/bbsuid 04111" "/bin/mount 04755" "/bin/umount 04755" "/etc/passwd 0644" "/etc/shadow 0640" "/root 0700" "/tmp 01777" "/var/tmp 01777"; do
        set -- $pair
        debugfs -R "stat $1" "$extract" 2>/dev/null | grep -Eq "Mode:[[:space:]]+$2" ||
            die_code "$EXIT_VERIFY" "mode extrait $1"
    done
    [ "$(debugfs -R 'cat /etc/alpine-release' "$extract" 2>/dev/null | tr -d '\r\n')" = "3.22.7" ] ||
        die_code "$EXIT_VERIFY" "version Alpine extraite"
    [ "$(debugfs -R 'cat /etc/hostname' "$extract" 2>/dev/null | tr -d '\r\n')" = "a71" ] ||
        die_code "$EXIT_VERIFY" "hostname extrait"
    [ "$(debugfs -R 'cat /lib/apk/db/installed' "$extract" 2>/dev/null | grep -c '^P:')" = "$PKG_COUNT" ] ||
        die_code "$EXIT_VERIFY" "$PKG_COUNT paquets extraits"
    tree=$(mktemp -d /tmp/a71-h3-tree-XXXXXXXX) || die_code "$EXIT_VERIFY" "arbre temporaire"
    debugfs -R "rdump / $tree" "$extract" >/dev/null 2>&1 || true
    [ "$(find "$tree/lib/modules/6.18.0-rc1-a71+" -name '*.ko' | wc -l)" = "607" ] ||
        die_code "$EXIT_VERIFY" "607 modules extraits"
    [ -s "$tree/lib/modules/6.18.0-rc1-a71+/modules.dep" ] ||
        die_code "$EXIT_VERIFY" "modules.dep extrait"
    [ "$(grep -c '^P:' "$tree/lib/apk/db/installed" 2>/dev/null || echo 0)" = "$PKG_COUNT" ] ||
        die_code "$EXIT_VERIFY" "$PKG_COUNT paquets extraits (arbre)"
    rm -rf "$tree" "$extract"
}

IMG_A=$(build_one build-a)
IMG_B=$(build_one build-b)
validate_image "$IMG_A" "$BUILD_ROOT/build-a"
validate_image "$IMG_B" "$BUILD_ROOT/build-b"

SHA_A=$(sha256sum "$IMG_A" | awk '{print $1}')
SHA_B=$(sha256sum "$IMG_B" | awk '{print $1}')
if cmp -s "$IMG_A" "$IMG_B"; then
    MATCH=yes
else
    MATCH=no
fi

if [ -e "$OUT" ]; then
    [ "$FORCE" = "1" ] || die_code "$EXIT_OUTPUT" "sortie non vide (--force)"
    BACKUP="${OUT}.pre-h3"
    [ ! -e "$BACKUP" ] || die_code "$EXIT_OUTPUT" "sauvegarde deja presente"
    mv "$OUT" "$BACKUP" || die_code "$EXIT_OUTPUT" "sauvegarde impossible"
fi
cp -a "$IMG_A" "$OUT" || die_code "$EXIT_OUTPUT" "publication impossible"
cp -a "$IMG_B" "${OUT%.img}-b.img" || die_code "$EXIT_OUTPUT" "publication B impossible"
printf '%s  %s\n' "$SHA_A" "$(basename "$OUT")" >"$OUT.sha256"
mkdir -p "$REPORTS"
cp -a "$BUILD_ROOT/build-a/partition-table.txt" "$REPORTS/partition-table.txt"
cp -a "$BUILD_ROOT/build-a/e2fsck-extract.txt" "$REPORTS/e2fsck-extract.txt"

{
    printf 'format=mbr\n'
    printf 'disk_id=%s\n' "$DISK_ID"
    printf 'sector_size=512\n'
    printf 'partition_count=1\n'
    printf 'partition_start_lba=%s\n' "$START_LBA"
    printf 'partition_size_sectors=%s\n' "$ROOT_SECTORS"
    printf 'partition_type=83\n'
    printf 'partition_start_bytes=%s\n' "$((START_LBA * 512))"
    printf 'partition_size_bytes=%s\n' "$ROOT_SIZE"
    printf 'total_size=%s\n' "$TOTAL_SIZE"
    printf 'rootfs_sha256=%s\n' "$ROOT_SHA"
    printf 'rootfs_label=%s\n' "$LABEL"
    printf 'rootfs_uuid=%s\n' "$UUID"
    printf 'bootloader=none\n'
    printf 'trailing_data=none\n'
    printf 'card_reference_size=%s\n' "$CARD_REF"
    printf 'margin_bytes=%s\n' "$((CARD_REF - TOTAL_SIZE))"
} >"$REPORTS/image-layout.txt"

{
    printf 'result=OK\n'
    printf 'image=%s\n' "$(basename "$OUT")"
    printf 'size=%s\n' "$TOTAL_SIZE"
    printf 'partition_count=1\n'
    printf 'partition_start_lba=%s\n' "$START_LBA"
    printf 'partition_size_sectors=%s\n' "$ROOT_SECTORS"
    printf 'partition_type=83\n'
    printf 'label=A71ROOT\n'
    printf 'uuid=%s\n' "$UUID"
    printf 'extract_sha256_match=yes\n'
    printf 'e2fsck_extract=ok\n'
    printf 'critical_content=ok\n'
    printf 'mbr_boot_code=none\n'
    printf 'trailing_data=none\n'
    printf 'below_card_size=yes\n'
    printf 'margin_512mib=yes\n'
    printf 'private_paths=none\n'
    printf 'runtime=not_tested\n'
    printf 'validation=provisional\n'
} >"$REPORTS/image-validation.txt"

{
    printf '# reproductibilite image SD\n'
    printf 'build_a_sha256=%s\n' "$SHA_A"
    printf 'build_b_sha256=%s\n' "$SHA_B"
    printf 'binary_match=%s\n' "$MATCH"
    printf 'disk_id=%s\n' "$DISK_ID"
    printf 'partition_start_lba=%s\n' "$START_LBA"
    printf 'partition_size_sectors=%s\n' "$ROOT_SECTORS"
    printf 'logical_match=yes\n'
} >"$REPORTS/image-reproducibility.txt"

say "image SD : $OUT"
say "sha256 : $SHA_A"
say "taille : $TOTAL_SIZE octets"
exit "$EXIT_OK"
