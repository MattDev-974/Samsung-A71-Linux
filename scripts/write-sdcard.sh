#!/usr/bin/env bash
# shellcheck shell=bash
#
# write-sdcard.sh - ecriture controlee de a71-sd.img sur /dev/sdd (I1).
#
# Ce script n'est PAS execute sur un peripherique reel dans cet environnement.
# Il refuse tout autre peripherique que /dev/sdd, verifie MAJ:MIN=8:48, et ne
# demonte que les partitions dont PKNAME=sde.
#
# A71_WRITE_TEST_MODE=1 est un crochet de test : il n'est jamais necessaire en
# usage reel, ne desactive jamais la cible /dev/sdd ni les gardes de contenu, et
# n'est utilisable qu'avec des commandes bouchonnees par le test.
#
# Codes : 0 succes, 2 usage, 3 garde/entree, 4 image/hash/table, 5 ecriture,
#         6 verification apres ecriture.

set -Eeuo pipefail

PROG=$(basename "$0")
EXIT_OK=0
EXIT_USAGE=2
EXIT_GUARD=3
EXIT_IMAGE=4
EXIT_WRITE=5
EXIT_VERIFY=6

DEVICE_LITERAL=/dev/sdd
MIN_SIZE=28000000000
MAX_SIZE=33000000000
EXPECTED_MAJMIN=8:48
MARGIN=$((512 * 1024 * 1024))

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
fail() { local c=$1; shift; say "$*"; exit "$c"; }
usage_error() { fail "$EXIT_USAGE" "$1"; }

usage() {
    cat <<EOF
$PROG - ecriture controlee de a71-sd.img sur /dev/sdd

Usage
  sudo $PROG --image FILE --device /dev/sdd [--verify-only]
  sudo $PROG --image FILE --device /dev/sdd --yes-i-understand-testing-only

Options
  --image FILE                         image disque compatible /init
  --sha256 FILE                        manifeste de hash (defaut FILE.sha256)
  --device DEV                         doit etre exactement /dev/sdd
  --verify-only                        gardes non destructives seulement
  --yes-i-understand-testing-only      confirmation automatique (tests)
  -h, --help                           cette aide

Le peripherique /dev/sdd sera TOTALEMENT EFFACE en mode ecriture.
EOF
}

IMAGE=""
SHA_FILE=""
DEVICE=""
VERIFY_ONLY=0
YES_TESTING=0
SEEN=" "
mark_opt() { case "$SEEN" in *" $1 "*) usage_error "option repetee : --$1" ;; esac; SEEN="$SEEN$1 "; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit "$EXIT_OK" ;;
        --image) mark_opt image; [ $# -ge 2 ] || usage_error "--image attend un fichier"; IMAGE=$2; shift ;;
        --sha256) mark_opt sha256; [ $# -ge 2 ] || usage_error "--sha256 attend un fichier"; SHA_FILE=$2; shift ;;
        --device) mark_opt device; [ $# -ge 2 ] || usage_error "--device attend un chemin"; DEVICE=$2; shift ;;
        --verify-only) mark_opt verify-only; VERIFY_ONLY=1 ;;
        --yes-i-understand-testing-only) mark_opt yes; YES_TESTING=1 ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done
[ -n "$IMAGE" ] || usage_error "--image est obligatoire"
[ -n "$DEVICE" ] || usage_error "--device est obligatoire"
[ "$DEVICE" = "$DEVICE_LITERAL" ] || fail "$EXIT_GUARD" "peripherique refuse : seul /dev/sdd est autorise"

TEST_MODE=${A71_WRITE_TEST_MODE:-0}
DEVICE_REAL=${A71_TEST_DEVICE_PATH:-$DEVICE}
if [ "$TEST_MODE" != "1" ]; then
    [ "$EUID" -eq 0 ] || fail "$EXIT_GUARD" "root requis (EUID=0)"
    [ -b "$DEVICE_REAL" ] || fail "$EXIT_GUARD" "cible n'est pas un block device"
else
    [ -e "$DEVICE_REAL" ] || fail "$EXIT_GUARD" "cible de test absente"
fi
[ ! -L "$DEVICE_REAL" ] || fail "$EXIT_GUARD" "cible est un lien symbolique"
[ -f "$IMAGE" ] || fail "$EXIT_IMAGE" "image absente"
[ ! -L "$IMAGE" ] || fail "$EXIT_IMAGE" "image est un lien symbolique"

for tool in lsblk sfdisk dd sha256sum dumpe2fs debugfs blkid findmnt swapon udevadm partprobe blockdev stat python3 sync; do
    command -v "$tool" >/dev/null 2>&1 || fail "$EXIT_GUARD" "commande requise absente : $tool"
done

# --- Informations lsblk (cle=valeur, robuste aux espaces) ---------------
LSBLK_RAW=$(lsblk -b -dn -P -o NAME,MAJ:MIN,RM,RO,TYPE,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS "$DEVICE_REAL" 2>/dev/null) ||
    fail "$EXIT_GUARD" "lsblk a echoue"
LSBLK_PARSED=$(printf '%s\n' "$LSBLK_RAW" | python3 -c '
import re,sys
keys=["NAME","MAJ:MIN","RM","RO","TYPE","SIZE","MODEL","SERIAL","TRAN","MOUNTPOINTS"]
vals=dict(re.findall(r"([A-Z:]+)=\"([^\"]*)\"",sys.stdin.read()))
print("\t".join(vals.get(k,"") for k in keys))
')
IFS=$'\t' read -r -a LSF <<<"$LSBLK_PARSED"
[ "${#LSF[@]}" -eq 9 ] && LSF+=("")
[ "${#LSF[@]}" -eq 10 ] || fail "$EXIT_GUARD" "lsblk illisible"
NAME=${LSF[0]}; MAJMIN=${LSF[1]}; RM=${LSF[2]}; RO=${LSF[3]}; TYPE=${LSF[4]}
SIZE=${LSF[5]}; MODEL=${LSF[6]}; SERIAL=${LSF[7]}; TRAN=${LSF[8]}; MOUNTPOINTS=${LSF[9]}

[ "$TYPE" = "disk" ] || fail "$EXIT_GUARD" "TYPE=$TYPE (attendu disk)"
[ "$RM" = "1" ] || fail "$EXIT_GUARD" "RM=$RM (attendu 1)"
[ "$RO" = "0" ] || fail "$EXIT_GUARD" "RO=$RO (attendu 0)"
case "$SIZE" in '' | *[!0-9]*) fail "$EXIT_GUARD" "taille cible illisible" ;; esac
[ "$SIZE" -ge "$MIN_SIZE" ] && [ "$SIZE" -le "$MAX_SIZE" ] ||
    fail "$EXIT_GUARD" "taille cible hors plage : $SIZE"
[ "$MAJMIN" = "$EXPECTED_MAJMIN" ] ||
    fail "$EXIT_GUARD" "MAJ:MIN=$MAJMIN (attendu 8:64) - nouvelle validation humaine requise"
[ -z "$MOUNTPOINTS" ] || fail "$EXIT_GUARD" "cible deja montee : $MOUNTPOINTS"

IMAGE_SIZE=$(stat -c '%s' "$IMAGE")
[ "$IMAGE_SIZE" -gt 0 ] || fail "$EXIT_IMAGE" "image vide"
[ $((IMAGE_SIZE % 1048576)) -eq 0 ] ||
    fail "$EXIT_IMAGE" "taille image non multiple de 1 MiB (lecture/ecriture bornee)"
[ $((SIZE - IMAGE_SIZE)) -ge "$MARGIN" ] ||
    fail "$EXIT_GUARD" "marge image/cible < 512 MiB"

# --- Hash de l'image ----------------------------------------------------
HASH_FILE=${SHA_FILE:-"$IMAGE.sha256"}
[ -f "$HASH_FILE" ] || fail "$EXIT_IMAGE" "manifeste de hash absent : $HASH_FILE"
EXPECTED_HASH=$(awk '{print $1; exit}' "$HASH_FILE")
[ -n "$EXPECTED_HASH" ] || fail "$EXIT_IMAGE" "hash attendu vide"
ACTUAL_HASH=$(sha256sum "$IMAGE" | awk '{print $1}')
[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || fail "$EXIT_IMAGE" "hash image different"

# --- Table de partitions : lecture stricte, sans dumpe2fs sur le MBR ----
TABLE_RAW=$(LC_ALL=C sfdisk -d "$IMAGE" 2>/dev/null) ||
    fail "$EXIT_IMAGE" "table: sfdisk -d a echoue"
TABLE_FIELDS=$(python3 - "$IMAGE_SIZE" "$TABLE_RAW" <<'PY' || true
import re
import sys

text = sys.argv[2]
image_size = int(sys.argv[1])
label = None
sector = None
parts = []
for line in text.splitlines():
    line = line.strip()
    if line.startswith("label:"):
        label = line.split(":", 1)[1].strip()
    elif line.startswith("sector-size:"):
        sector = line.split(":", 1)[1].strip()
    elif " : start=" in line:
        match = re.search(r"start=\s*(\S+),\s*size=\s*(\S+),\s*type=\s*(\S+)", line)
        if not match:
            sys.exit(1)
        parts.append(match.groups())

if label != "dos":
    sys.exit(1)
if sector != "512":
    sys.exit(1)
if len(parts) != 1:
    sys.exit(1)
start_s, size_s, type_s = parts[0]
if not start_s.isdigit() or not size_s.isdigit():
    sys.exit(1)
if type_s not in ("83", "0x83"):
    sys.exit(1)
start = int(start_s)
size = int(size_s)
if start < 2048 or start % 2048 != 0:
    sys.exit(1)
if size <= 0:
    sys.exit(1)
offset = start * 512
part_bytes = size * 512
if offset < 0 or part_bytes < 0 or offset + part_bytes > image_size:
    sys.exit(1)
if part_bytes % 4096 != 0:
    sys.exit(1)
print("%s\t%s\t%s\t%s\t%s\t%s" % (label, sector, start, size, offset, part_bytes))
PY
)
[ -n "$TABLE_FIELDS" ] || fail "$EXIT_IMAGE" "table: label dos, sector-size 512, une partition Linux/83 alignée et contenue sont requis"
IFS=$'\t' read -r TABLE_LABEL SECTOR_SIZE PART_START PART_SIZE PART_OFFSET_BYTES PART_SIZE_BYTES <<<"$TABLE_FIELDS"
[ "$TABLE_LABEL" = "dos" ] || fail "$EXIT_IMAGE" "table: label $TABLE_LABEL != dos"
[ "$SECTOR_SIZE" = "512" ] || fail "$EXIT_IMAGE" "table: sector-size $SECTOR_SIZE != 512"
[ "$PART_START" -ge 2048 ] && [ $((PART_START % 2048)) -eq 0 ] ||
    fail "$EXIT_IMAGE" "table: partition non alignee sur 1 MiB (start=$PART_START)"
[ "$PART_SIZE" -gt 0 ] || fail "$EXIT_IMAGE" "table: taille de partition nulle"
[ "$PART_OFFSET_BYTES" = "$((PART_START * 512))" ] ||
    fail "$EXIT_IMAGE" "table: offset de partition incoherent"
[ "$PART_SIZE_BYTES" = "$((PART_SIZE * 512))" ] ||
    fail "$EXIT_IMAGE" "table: taille de partition incoherente"
[ $((PART_OFFSET_BYTES + PART_SIZE_BYTES)) -le "$IMAGE_SIZE" ] ||
    fail "$EXIT_IMAGE" "table: partition depasse la fin du fichier"
COUNT=1

# --- Extraction exacte de la partition dans un temporaire prive (077) ---
umask 077
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/a71-write-XXXXXXXX") ||
    fail "$EXIT_IMAGE" "extraction: temporaire impossible"
trap 'rm -rf "$TMP_DIR"' EXIT
[ -d "$TMP_DIR" ] && [ ! -L "$TMP_DIR" ] ||
    fail "$EXIT_IMAGE" "extraction: temporaire non regulier"
PART_FILE="$TMP_DIR/partition.ext4"
dd if="$IMAGE" of="$PART_FILE" bs=512 skip="$PART_START" count="$PART_SIZE" status=none ||
    fail "$EXIT_IMAGE" "extraction: dd de la partition a echoue"
[ -f "$PART_FILE" ] && [ ! -L "$PART_FILE" ] ||
    fail "$EXIT_IMAGE" "extraction: fichier de partition absent"
EXTRACT_SIZE=$(stat -c '%s' "$PART_FILE")
[ "$EXTRACT_SIZE" = "$PART_SIZE_BYTES" ] ||
    fail "$EXIT_IMAGE" "extraction: taille $EXTRACT_SIZE != $PART_SIZE_BYTES"
DUMP_OUT=$(dumpe2fs -h "$PART_FILE" 2>/dev/null) ||
    fail "$EXIT_IMAGE" "ext4: dumpe2fs a echoue sur la partition extraite"
LABEL=$(printf '%s\n' "$DUMP_OUT" | sed -n 's/^Filesystem volume name: *//p')
[ "$LABEL" = "A71ROOT" ] || fail "$EXIT_IMAGE" "label: '$LABEL' != A71ROOT"
FS_TYPE=$(blkid -o value -s TYPE "$PART_FILE" 2>/dev/null || true)
[ "$FS_TYPE" = "ext4" ] || fail "$EXIT_IMAGE" "ext4: type '$FS_TYPE' != ext4"

# --- Contrat historique switch_root /newroot /init ---------------------
INIT_STAT=$(debugfs -R 'stat /init' "$PART_FILE" 2>/dev/null || true)
printf '%s\n' "$INIT_STAT" | grep -q 'Type: symlink' ||
    fail "$EXIT_IMAGE" "rootfs incompatible: /init absent ou n'est pas un symlink"
printf '%s\n' "$INIT_STAT" | grep -q 'Fast link dest: "/sbin/init"' ||
    fail "$EXIT_IMAGE" "rootfs incompatible: /init ne pointe pas exactement vers /sbin/init"
debugfs -R 'stat /sbin/init' "$PART_FILE" 2>/dev/null | grep -q 'Inode:' ||
    fail "$EXIT_IMAGE" "rootfs incompatible: /sbin/init absent"

# --- Montages, swap, holders, device-mapper -----------------------------
MOUNTS=$(findmnt -rn -S "$DEVICE_REAL" 2>/dev/null || true)
[ -z "$MOUNTS" ] || fail "$EXIT_GUARD" "une partition de la cible est montee"
SWAPS=$(swapon --show=NAME --noheadings 2>/dev/null || true)
if printf '%s\n' "$SWAPS" | grep -qE "(^|/)${NAME}([0-9]+)?$"; then
    fail "$EXIT_GUARD" "cible ou partition utilisee comme swap"
fi
if [ "${A71_TEST_HOLDER:-0}" = "1" ] || { [ -d "/sys/block/$NAME/holders" ] && [ -n "$(ls -A "/sys/block/$NAME/holders" 2>/dev/null)" ]; }; then
    fail "$EXIT_GUARD" "holders sysfs presents sur $NAME"
fi
if command -v dmsetup >/dev/null 2>&1; then
    DM=$(dmsetup ls 2>/dev/null || true)
    if printf '%s\n' "$DM" | grep -qE "(^|[^a-z])${NAME}([^a-z]|$)"; then
        fail "$EXIT_GUARD" "cible referencee par device-mapper"
    fi
fi
# Aucune partition de la cible montee/use : verifier aussi les enfants.
while IFS= read -r line; do
    [ -n "$line" ] || continue
    child=$(printf '%s\n' "$line" | awk '{print $1}')
    [ -n "$child" ] || continue
    CHILD_MOUNT=$(findmnt -rn -S "/dev/$child" 2>/dev/null || true)
    [ -z "$CHILD_MOUNT" ] || fail "$EXIT_GUARD" "partition montee : /dev/$child"
done < <(lsblk -ln -o NAME "$DEVICE_REAL" 2>/dev/null | tail -n +2)

# --- Resume -------------------------------------------------------------
say "image        : $(basename "$IMAGE") ($IMAGE_SIZE octets)"
say "sha256       : $ACTUAL_HASH"
say "device       : $DEVICE"
say "cible        : $SIZE octets"
say "modele       : $MODEL"
say "serie        : $SERIAL"
say "transport    : $TRAN"
say "MAJ:MIN      : $MAJMIN"
say "partitions   : $COUNT (Linux/83, start=$PART_START, size=$PART_SIZE, offset=$PART_OFFSET_BYTES, ext4=$PART_SIZE_BYTES)"
say "label        : $LABEL (type=$FS_TYPE)"

if [ "$VERIFY_ONLY" = "1" ]; then
    say "VERIFY-ONLY : toutes les gardes sont passees, aucune ecriture"
    exit "$EXIT_OK"
fi

# --- Confirmation -------------------------------------------------------
if [ "$TEST_MODE" != "1" ] || [ "$YES_TESTING" != "1" ]; then
    if [ "$YES_TESTING" = "1" ] && [ "$TEST_MODE" != "1" ]; then
        fail "$EXIT_GUARD" "--yes-i-understand-testing-only exige A71_WRITE_TEST_MODE=1"
    fi
    printf 'ECRIRE /dev/sdd : ' >/dev/tty 2>/dev/null ||
        fail "$EXIT_GUARD" "terminal de confirmation indisponible"
    IFS= read -r answer </dev/tty || fail "$EXIT_GUARD" "confirmation impossible"
    [ "$answer" = "ECRIRE /dev/sdd" ] || fail "$EXIT_GUARD" "confirmation refusee"
fi

# --- Demonter uniquement les partitions PKNAME=sde ---------------------
while IFS=$'\t' read -r child parent; do
    [ -n "$child" ] || continue
    if [ "$parent" = "$NAME" ]; then
        umount "/dev/$child" || fail "$EXIT_GUARD" "demontage impossible : /dev/$child"
    fi
done < <(lsblk -ln -o NAME,PKNAME "$DEVICE_REAL" 2>/dev/null | tail -n +2)
sync

# --- Ecriture -----------------------------------------------------------
COUNT_1M=$((IMAGE_SIZE / 1048576))
dd if="$IMAGE" of="$DEVICE_REAL" bs=1M count="$COUNT_1M" conv=fsync status=none ||
    fail "$EXIT_WRITE" "ecriture dd echouee"
sync
if command -v partprobe >/dev/null 2>&1 && partprobe "$DEVICE_REAL" 2>/dev/null; then
    :
elif command -v blockdev >/dev/null 2>&1 && blockdev --rereadpt "$DEVICE_REAL" 2>/dev/null; then
    :
else
    fail "$EXIT_WRITE" "partprobe/blockdev --rereadpt impossible"
fi
udevadm settle --timeout=10 2>/dev/null || true

# --- Relecture et verification -----------------------------------------
dd if="$DEVICE_REAL" of="$TMP_DIR/readback" bs=1M count="$COUNT_1M" status=none ||
    fail "$EXIT_VERIFY" "relecture: dd a echoue"
READ_HASH=$(sha256sum "$TMP_DIR/readback" | awk '{print $1}')
[ "$READ_HASH" = "$EXPECTED_HASH" ] || fail "$EXIT_VERIFY" "hash relu different"
TABLE_AFTER=$(LC_ALL=C sfdisk -d "$DEVICE_REAL" 2>/dev/null | grep -v '^device:') ||
    fail "$EXIT_VERIFY" "table relue impossible"
printf '%s\n' "$TABLE_AFTER" | grep -q "start= *$PART_START, size= *$PART_SIZE, type=83" ||
    fail "$EXIT_VERIFY" "table relue differente"
LABEL_AFTER_RAW=$(dumpe2fs -h "${DEVICE_REAL}1" 2>/dev/null) ||
    fail "$EXIT_VERIFY" "label: dumpe2fs a echoue apres ecriture"
LABEL_AFTER=$(printf '%s\n' "$LABEL_AFTER_RAW" | sed -n 's/^Filesystem volume name: *//p')
[ "$LABEL_AFTER" = "A71ROOT" ] || fail "$EXIT_VERIFY" "label relu different"

say "ECRITURE ET VERIFICATION REUSSIES sur $DEVICE"
say "hash relu : $READ_HASH"
exit "$EXIT_OK"
