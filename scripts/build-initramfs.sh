#!/usr/bin/env bash
# shellcheck shell=bash
#
# build-initramfs.sh - initramfs cpio newc reproductible pour le Galaxy A71 (F1).
#
# Aucun montage, chroot, QEMU, sudo, loop device ni acces appareil. Le rootfs
# d'entree doit avoir ete valide par scripts/validate-rootfs.sh. Aucun module
# n'est inclus si les pilotes critiques sont integres (=y) dans la config.
#
# Codes : 0 ok, 2 usage, 3 entree invalide, 4 config non conforme,
#         5 construction/verification, 6 sortie.

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PROG=$(basename "$0")

EXIT_OK=0
EXIT_USAGE=2
EXIT_INPUT=3
EXIT_CONFIG=4
EXIT_BUILD=5
EXIT_OUTPUT=6

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() { say "$1"; printf 'Utilise --help.\n' >&2; exit "$EXIT_USAGE"; }
die_code() { local c=$1; shift; say "$*"; exit "$c"; }

usage() {
    cat <<EOF
$PROG - initramfs reproductible (cpio newc + gzip)

Usage
  $PROG --rootfs DIR --kernel-config FILE --kernel-release STR \\
        --output DIR --source-date-epoch N [--force]

Options
  --rootfs DIR              rootfs valide (scripts/validate-rootfs.sh)
  --kernel-config FILE      .config final valide
  --kernel-release STR      release attendue : 6.18.0-rc1-a71+
  --output DIR              repertoire de sortie
  --source-date-epoch N     epoch reproductible (ex. 1760369959)
  --firmware FILE           ajoute qcom/a630_sqe.fw (hash M7B.2 exige)
  --force                   remplace la sortie apres sauvegarde .pre-f1
  -h, --help                cette aide
EOF
}

ROOTFS=""
KERNEL_CONFIG=""
KERNEL_RELEASE=""
OUT_DIR=""
EPOCH=""
FIRMWARE=""
FW_SHA=1c21b527d9183487cc550dabbb3f43e555df5a977a461934fc61f0635a9aa90c
FORCE=0
SEEN=" "
mark_opt() { case "$SEEN" in *" $1 "*) usage_error "option repetee : --$1" ;; esac; SEEN="$SEEN$1 "; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit "$EXIT_OK" ;;
        --rootfs) mark_opt rootfs; [ $# -ge 2 ] || usage_error "--rootfs attend un repertoire"; ROOTFS=$2; shift ;;
        --kernel-config) mark_opt kernel-config; [ $# -ge 2 ] || usage_error "--kernel-config attend un fichier"; KERNEL_CONFIG=$2; shift ;;
        --kernel-release) mark_opt kernel-release; [ $# -ge 2 ] || usage_error "--kernel-release attend une valeur"; KERNEL_RELEASE=$2; shift ;;
        --output) mark_opt output; [ $# -ge 2 ] || usage_error "--output attend un repertoire"; OUT_DIR=$2; shift ;;
        --source-date-epoch) mark_opt source-date-epoch; [ $# -ge 2 ] || usage_error "--source-date-epoch attend un entier"; EPOCH=$2; shift ;;
        --firmware) mark_opt firmware; [ $# -ge 2 ] || usage_error "--firmware attend un fichier"; FIRMWARE=$2; shift ;;
        --force) mark_opt force; FORCE=1 ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

[ -n "$ROOTFS" ] || usage_error "--rootfs est obligatoire"
[ -n "$KERNEL_CONFIG" ] || usage_error "--kernel-config est obligatoire"
[ -n "$KERNEL_RELEASE" ] || usage_error "--kernel-release est obligatoire"
[ -n "$OUT_DIR" ] || usage_error "--output est obligatoire"
[ -n "$EPOCH" ] || usage_error "--source-date-epoch est obligatoire"
if [ -n "$FIRMWARE" ]; then
    [ -f "$FIRMWARE" ] && [ ! -L "$FIRMWARE" ] || die_code "$EXIT_INPUT" "firmware absent ou symlink"
    [ "$(stat -c '%s' "$FIRMWARE")" = 34188 ] || die_code "$EXIT_INPUT" "taille firmware != 34188"
    [ "$(sha256sum "$FIRMWARE" | awk '{print $1}')" = "$FW_SHA" ] || die_code "$EXIT_INPUT" "hash firmware incorrect"
fi
case "$EPOCH" in '' | *[!0-9]*) usage_error "--source-date-epoch doit etre un entier positif" ;; esac
[ "$KERNEL_RELEASE" = "6.18.0-rc1-a71+" ] ||
    die_code "$EXIT_INPUT" "release inattendue : $KERNEL_RELEASE"

[ -d "$ROOTFS" ] || die_code "$EXIT_INPUT" "rootfs absent"
[ ! -L "$ROOTFS" ] || die_code "$EXIT_INPUT" "rootfs est un lien symbolique"
ROOTFS=$(cd "$ROOTFS" && pwd -P)
[ -f "$KERNEL_CONFIG" ] || die_code "$EXIT_INPUT" "configuration noyau absente"
[ -f "$ROOTFS/bin/busybox" ] || die_code "$EXIT_INPUT" "BusyBox absent du rootfs"
[ -f "$ROOTFS/lib/ld-musl-aarch64.so.1" ] || die_code "$EXIT_INPUT" "chargeur musl absent du rootfs"
[ -f "$ROOTFS/reports/ownership-manifest.txt" ] || die_code "$EXIT_INPUT" "manifeste de proprietaires absent"
[ -x "$REPO_ROOT/scripts/validate-rootfs.sh" ] || die_code "$EXIT_INPUT" "validateur absent"

case "$OUT_DIR" in /*) ;; *) OUT_DIR="$PWD/$OUT_DIR" ;; esac
[ ! -L "$OUT_DIR" ] || die_code "$EXIT_OUTPUT" "sortie est un lien symbolique"
OUT_DIR=$(realpath -m -- "$OUT_DIR") || die_code "$EXIT_OUTPUT" "chemin de sortie invalide"
OUT_PARENT=$(dirname "$OUT_DIR")
mkdir -p "$OUT_PARENT" || die_code "$EXIT_OUTPUT" "parent de sortie impossible"

TMP_OUT=$(mktemp -d "$OUT_PARENT/.a71-initramfs-XXXXXXXX") || die_code "$EXIT_OUTPUT" "temporaire impossible"
cleanup() {
    if [ -n "${TMP_OUT:-}" ]; then
        rm -rf "$TMP_OUT"
    fi
    return 0
}
trap cleanup EXIT

# 1) rootfs reellement valide (lecture seule).
"$REPO_ROOT/scripts/validate-rootfs.sh" \
    --rootfs "$ROOTFS" \
    --manifest "$REPO_ROOT/manifest.yaml" \
    --ownership-manifest "$ROOTFS/reports/ownership-manifest.txt" \
    --report "$TMP_OUT/rootfs-validation.txt" >/dev/null 2>&1 ||
    die_code "$EXIT_INPUT" "rootfs non valide (E1)"

# 2) pilotes critiques integres =y, donc aucun module dans l'initramfs.
CRITICAL_SYMBOLS="
CONFIG_MMC
CONFIG_MMC_SDHCI
CONFIG_MMC_SDHCI_PLTFM
CONFIG_MMC_SDHCI_MSM
CONFIG_EXT4_FS
CONFIG_BLK_DEV_INITRD
CONFIG_DEVTMPFS
CONFIG_DEVTMPFS_MOUNT
"
for sym in $CRITICAL_SYMBOLS; do
    line=$(grep -E "^$sym=" "$KERNEL_CONFIG" | tail -1 || true)
    [ "$line" = "$sym=y" ] ||
        die_code "$EXIT_CONFIG" "pilote critique non integre : $sym (attendu =y)"
done

# 3) BusyBox : ELF AArch64 et mode corrige.
python3 - "$ROOTFS/bin/busybox" <<'PY' || die_code "$EXIT_INPUT" "BusyBox non ELF AArch64"
import sys
p=sys.argv[1]
with open(p,'rb') as f: h=f.read(20)
if len(h)<20 or h[:4]!=b'\x7fELF' or h[4]!=2 or h[5]!=1 or int.from_bytes(h[18:20],'little')!=183:
    raise SystemExit(1)
PY
[ "$(stat -c '%a' "$ROOTFS/bin/busybox")" = "755" ] ||
    die_code "$EXIT_INPUT" "BusyBox n'est pas en 0755"
if [ -e "$ROOTFS/init" ] || [ -L "$ROOTFS/init" ]; then
    [ -L "$ROOTFS/init" ] && [ "$(readlink "$ROOTFS/init")" = "/sbin/init" ] ||
        die_code "$EXIT_INPUT" "rootfs: /init incompatible avec le contrat"
fi

make_stage() {
    local stage=$1
    mkdir -p "$stage/bin" "$stage/sbin" "$stage/lib" "$stage/dev" "$stage/proc" \
        "$stage/sys" "$stage/run" "$stage/newroot"
    cp "$ROOTFS/bin/busybox" "$stage/bin/busybox"
    chmod 755 "$stage/bin/busybox"
    # BusyBox Alpine est dynamique : le chargeur musl est indispensable.
    cp "$ROOTFS/lib/ld-musl-aarch64.so.1" "$stage/lib/ld-musl-aarch64.so.1"
    chmod 755 "$stage/lib/ld-musl-aarch64.so.1"
    if [ -n "$FIRMWARE" ]; then
        mkdir -p "$stage/lib/firmware/qcom"
        cp "$FIRMWARE" "$stage/lib/firmware/qcom/a630_sqe.fw"
        chmod 0644 "$stage/lib/firmware/qcom/a630_sqe.fw"
    fi
    ln -s ld-musl-aarch64.so.1 "$stage/lib/libc.musl-aarch64.so.1"
    cat >"$stage/init" <<'INIT'
#!/bin/sh
# a71 initramfs - monte A71ROOT puis switch_root. Aucun reseau, aucun secret.
PATH=/bin:/sbin
export PATH

log() {
    echo "a71-init: $*" >/dev/console 2>/dev/null || true
    echo "a71-init: $*" >/dev/ttyMSM0 2>/dev/null || true
}

rescue() {
    log "$*"
    exec /bin/sh
}

mkdir -p /proc /sys /run /newroot /dev
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mount -t tmpfs tmpfs /dev 2>/dev/null || true
[ -c /dev/console ] || mknod /dev/console c 5 1 2>/dev/null || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true

root=LABEL=A71ROOT
rootfstype=ext4
rootwait=1
rootdelay=0
if [ -r /proc/cmdline ]; then
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            root=*) root=${arg#root=} ;;
            rootfstype=*) rootfstype=${arg#rootfstype=} ;;
            rootwait) rootwait=1 ;;
            rootdelay=*) rootdelay=${arg#rootdelay=} ;;
        esac
    done
fi

case "$rootdelay" in ''|*[!0-9]*) rootdelay=0 ;; esac
[ "$rootdelay" -gt 15 ] && rootdelay=15
limit=$rootdelay
[ "$rootwait" = 1 ] && limit=$((limit + 10))
[ "$limit" -lt 1 ] && limit=1

dev=""
case "$root" in
    LABEL=*)
        label=${root#LABEL=}
        tries=0
        while [ "$tries" -lt "$limit" ]; do
            dev=$(blkid -L "$label" 2>/dev/null)
            [ -n "$dev" ] && break
            tries=$((tries + 1))
            [ "$tries" -lt "$limit" ] && sleep 1
        done
        ;;
    /*) dev=$root ;;
    *) rescue "racine non supportee: $root" ;;
esac
[ -n "$dev" ] || rescue "root introuvable: $root"
[ -b "$dev" ] || rescue "racine absente: $dev"

[ "$rootdelay" -gt 0 ] && sleep "$rootdelay"

mounted=0
for opt in ro rw; do
    if mount -t "$rootfstype" -o "$opt" "$dev" /newroot; then
        mounted=1
        break
    fi
done
[ "$mounted" = 1 ] || rescue "montage impossible: $dev"
[ -x /newroot/sbin/init ] || rescue "/newroot/sbin/init absent"

for d in dev proc sys run; do
    mkdir -p "/newroot/$d" 2>/dev/null || true
    mount -o move "/$d" "/newroot/$d" 2>/dev/null || umount "/$d" 2>/dev/null || true
done

log "switch_root vers $dev"
exec switch_root /newroot /sbin/init
INIT
    chmod 755 "$stage/init"
    ln -s /bin/busybox "$stage/bin/sh"
    ln -s /bin/busybox "$stage/bin/cat"
    ln -s /bin/busybox "$stage/bin/mount"
    ln -s /bin/busybox "$stage/bin/umount"
    ln -s /bin/busybox "$stage/bin/sleep"
    ln -s /bin/busybox "$stage/bin/ls"
    ln -s /bin/busybox "$stage/bin/dmesg"
    ln -s /bin/busybox "$stage/bin/mkdir"
    ln -s /bin/busybox "$stage/bin/mknod"
    ln -s /bin/busybox "$stage/sbin/blkid"
    ln -s /bin/busybox "$stage/sbin/switch_root"
    ln -s /bin/busybox "$stage/sbin/mdev"
    if [ -n "$FIRMWARE" ]; then
        # Normaliser les modes pour que umask 077/022 ne change pas l'archive.
        find "$stage" -type d -exec chmod 0755 {} +
        find "$stage" -type f -exec chmod 0644 {} +
        chmod 0755 "$stage/init" "$stage/bin/busybox" "$stage/lib/ld-musl-aarch64.so.1"
    fi
    find "$stage" -exec touch -h -d "@$EPOCH" {} +
}

if [ -n "$FIRMWARE" ]; then
    ( umask 077; make_stage "$TMP_OUT/build-a" ) || die_code "$EXIT_BUILD" "staging A impossible"
    ( umask 022; make_stage "$TMP_OUT/build-b" ) || die_code "$EXIT_BUILD" "staging B impossible"
else
    make_stage "$TMP_OUT/build-a" || die_code "$EXIT_BUILD" "staging A impossible"
    make_stage "$TMP_OUT/build-b" || die_code "$EXIT_BUILD" "staging B impossible"
fi

python3 "$REPO_ROOT/scripts/mkcpio.py" create --root "$TMP_OUT/build-a" \
    --output "$TMP_OUT/initramfs-a.cpio" --epoch "$EPOCH" ||
    die_code "$EXIT_BUILD" "cpio A impossible"
python3 "$REPO_ROOT/scripts/mkcpio.py" create --root "$TMP_OUT/build-b" \
    --output "$TMP_OUT/initramfs-b.cpio" --epoch "$EPOCH" ||
    die_code "$EXIT_BUILD" "cpio B impossible"

gzip -n -9 -c "$TMP_OUT/initramfs-a.cpio" >"$TMP_OUT/initramfs-a.img" ||
    die_code "$EXIT_BUILD" "compression A impossible"
gzip -n -9 -c "$TMP_OUT/initramfs-b.cpio" >"$TMP_OUT/initramfs-b.img" ||
    die_code "$EXIT_BUILD" "compression B impossible"

cmp -s "$TMP_OUT/initramfs-a.cpio" "$TMP_OUT/initramfs-b.cpio" ||
    die_code "$EXIT_BUILD" "archives cpio non reproductibles"
cmp -s "$TMP_OUT/initramfs-a.img" "$TMP_OUT/initramfs-b.img" ||
    die_code "$EXIT_BUILD" "images compressees non reproductibles"

# 4) Verifications reelles de l'archive.
gzip -t "$TMP_OUT/initramfs-a.img" || die_code "$EXIT_BUILD" "gzip invalide"
gzip -dc "$TMP_OUT/initramfs-a.img" >"$TMP_OUT/initramfs-a.check.cpio" ||
    die_code "$EXIT_BUILD" "decompression impossible"
python3 "$REPO_ROOT/scripts/mkcpio.py" list --input "$TMP_OUT/initramfs-a.check.cpio" \
    >"$TMP_OUT/initramfs-list.txt" || die_code "$EXIT_BUILD" "lecture cpio impossible"

grep -qx '0755 0 0 f init' "$TMP_OUT/initramfs-list.txt" ||
    die_code "$EXIT_BUILD" "/init absent ou mauvais mode"
grep -qx '0755 0 0 f bin/busybox' "$TMP_OUT/initramfs-list.txt" ||
    die_code "$EXIT_BUILD" "BusyBox absent ou mauvais mode"
grep -qx '0755 0 0 f lib/ld-musl-aarch64.so.1' "$TMP_OUT/initramfs-list.txt" ||
    die_code "$EXIT_BUILD" "chargeur musl absent ou mauvais mode"
if [ -n "$FIRMWARE" ]; then
    grep -qx '0644 0 0 f lib/firmware/qcom/a630_sqe.fw' "$TMP_OUT/initramfs-list.txt" ||
        die_code "$EXIT_BUILD" "firmware absent ou mauvais mode/uid/gid"
    [ "$(awk '$5 == "lib/firmware/qcom/a630_sqe.fw" {c++} END {print c+0}' "$TMP_OUT/initramfs-list.txt")" = 1 ] ||
        die_code "$EXIT_BUILD" "firmware duplique"
    [ "$(awk '$4 == "f" && $5 ~ /^lib\/firmware\// {c++} END {print c+0}' "$TMP_OUT/initramfs-list.txt")" = 1 ] ||
        die_code "$EXIT_BUILD" "firmware supplementaire"
    [ "$(sha256sum "$TMP_OUT/build-a/lib/firmware/qcom/a630_sqe.fw" | awk '{print $1}')" = "$FW_SHA" ] ||
        die_code "$EXIT_BUILD" "hash firmware stage incorrect"
fi
python3 - "$TMP_OUT/build-a/lib/ld-musl-aarch64.so.1" <<'PY' || die_code "$EXIT_BUILD" "chargeur musl non ELF AArch64"
import sys
with open(sys.argv[1], 'rb') as fh:
    head = fh.read(20)
if len(head) < 20 or head[:4] != b'\x7fELF' or head[4] != 2 or head[5] != 1 or int.from_bytes(head[18:20], 'little') != 183:
    raise SystemExit(1)
PY
[ "$(grep -c '\.ko' "$TMP_OUT/initramfs-list.txt")" = "0" ] ||
    die_code "$EXIT_BUILD" "module present alors que les pilotes sont =y"
[ "$(awk '$5 ~ /^\// {c++} END {print c+0}' "$TMP_OUT/initramfs-list.txt")" = "0" ] ||
    die_code "$EXIT_BUILD" "chemin absolu dans l'archive"
[ "$(awk '$5 ~ /\.\./ {c++} END {print c+0}' "$TMP_OUT/initramfs-list.txt")" = "0" ] ||
    die_code "$EXIT_BUILD" "traversee '..' dans l'archive"
[ "$(grep -c ' l ' "$TMP_OUT/initramfs-list.txt")" -ge 10 ] ||
    die_code "$EXIT_BUILD" "liens BusyBox insuffisants"
[ "$(grep -c '^0755 0 0 d ' "$TMP_OUT/initramfs-list.txt")" -ge 6 ] ||
    die_code "$EXIT_BUILD" "repertoires de base absents"

grep -q 'switch_root /newroot /sbin/init' "$TMP_OUT/build-a/init" ||
    die_code "$EXIT_BUILD" "/init ne fait pas switch_root"
grep -q 'LABEL=A71ROOT' "$TMP_OUT/build-a/init" ||
    die_code "$EXIT_BUILD" "/init ne gere pas LABEL=A71ROOT"
grep -q 'blkid -L' "$TMP_OUT/build-a/init" ||
    die_code "$EXIT_BUILD" "/init n'utilise pas blkid -L"
grep -q 'rootdelay' "$TMP_OUT/build-a/init" ||
    die_code "$EXIT_BUILD" "/init ne gere pas rootdelay"
if grep -Eq '(^|[[:space:]])(udhcpc|dhcpcd|ifconfig|wget|curl)([[:space:]]|$)' "$TMP_OUT/build-a/init"; then
    die_code "$EXIT_BUILD" "/init demarre un service reseau"
fi
if grep -q 'BEGIN .*PRIVATE KEY' "$TMP_OUT/build-a/init"; then
    die_code "$EXIT_BUILD" "secret dans /init"
fi

# 5) Rapport et publication atomique.
HASH_A=$(sha256sum "$TMP_OUT/initramfs-a.img" | awk '{print $1}')
HASH_B=$(sha256sum "$TMP_OUT/initramfs-b.img" | awk '{print $1}')
[ "$HASH_A" = "$HASH_B" ] || die_code "$EXIT_BUILD" "hashes differents"

cp "$TMP_OUT/initramfs-a.img" "$TMP_OUT/initramfs.img"
{
    printf 'result=OK\n'
    printf 'kernel_release=%s\n' "$KERNEL_RELEASE"
    printf 'source_date_epoch=%s\n' "$EPOCH"
    printf 'archive_format=cpio-newc\n'
    printf 'compression=gzip -n -9\n'
    printf 'module_count=0\n'
    if [ -n "$FIRMWARE" ]; then
        printf 'firmware=lib/firmware/qcom/a630_sqe.fw\n'
        printf 'firmware_size=34188\n'
        printf 'firmware_sha256=%s\n' "$FW_SHA"
    fi
    printf 'busybox_elf=aarch64\n'
    printf 'musl_loader=included\n'
    printf 'musl_elf=aarch64\n'
    printf 'init_mode=0755\n'
    printf 'busybox_mode=0755\n'
    printf 'uid_gid=0:0\n'
    printf 'network=none\n'
    printf 'secrets=none\n'
    printf 'build_a_sha256=%s\n' "$HASH_A"
    printf 'build_b_sha256=%s\n' "$HASH_B"
    printf 'hash_match=yes\n'
    printf 'reproducible=yes\n'
} >"$TMP_OUT/initramfs-summary.txt"
{
    printf '# reproductibilite de initramfs\n'
    printf 'build_a_cpio_sha256=%s\n' "$(sha256sum "$TMP_OUT/initramfs-a.cpio" | awk '{print $1}')"
    printf 'build_b_cpio_sha256=%s\n' "$(sha256sum "$TMP_OUT/initramfs-b.cpio" | awk '{print $1}')"
    printf 'build_a_img_sha256=%s\n' "$HASH_A"
    printf 'build_b_img_sha256=%s\n' "$HASH_B"
    printf 'cpio_match=yes\n'
    printf 'image_match=yes\n'
    printf 'overall_reproducible=yes\n'
} >"$TMP_OUT/reproducibility.txt"
printf '%s  initramfs.img\n' "$HASH_A" >"$TMP_OUT/initramfs.img.sha256"

# Ne publier que les sorties demandees (pas les cpio/check temporaires).
rm -f "$TMP_OUT/initramfs-a.cpio" "$TMP_OUT/initramfs-b.cpio" \
    "$TMP_OUT/initramfs-a.check.cpio" "$TMP_OUT/initramfs-list.txt" \
    "$TMP_OUT/rootfs-validation.txt"

if [ -e "$OUT_DIR" ]; then
    [ "$FORCE" = "1" ] || die_code "$EXIT_OUTPUT" "sortie non vide (--force)"
    BACKUP="${OUT_DIR}.pre-f1"
    [ ! -e "$BACKUP" ] || die_code "$EXIT_OUTPUT" "sauvegarde deja presente : $BACKUP"
    mv "$OUT_DIR" "$BACKUP" || die_code "$EXIT_OUTPUT" "sauvegarde impossible"
    say "ancienne sortie sauvegardee : $BACKUP"
fi
mv "$TMP_OUT" "$OUT_DIR" || die_code "$EXIT_OUTPUT" "publication atomique impossible"
TMP_OUT=""

say "initramfs : $OUT_DIR/initramfs.img"
say "sha256 : $HASH_A"
exit "$EXIT_OK"
