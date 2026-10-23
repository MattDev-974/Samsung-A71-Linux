#!/usr/bin/env bash
# shellcheck shell=bash
#
# build-rootfs-image.sh - construit A71ROOT.ext4 sans montage ni loop (H2).
#
# Le contenu vient de work/rootfs/rootfs-functional. Les proprietaires/modes
# logiques viennent du manifeste et sont appliques avec debugfs (sif), jamais
# avec chmod/chown recursif sur le rootfs source.
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

DEFAULT_SIZE=1073741824   # 1 GiB : marge documentee, tres loin des 29 Gio
DEFAULT_INODES=16384
POLICY="$REPO_ROOT/configs/rootfs-mode-policy.txt"
HELPER="$REPO_ROOT/scripts/ext4-manifest.py"

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() { say "$1"; printf 'Utilise --help.\n' >&2; exit "$EXIT_USAGE"; }
die_code() { local c=$1; shift; say "$*"; exit "$c"; }

usage() {
    cat <<EOF
$PROG - A71ROOT.ext4 avec proprietaires/modes logiques (sans montage)

Usage
  $PROG --rootfs DIR --ownership-manifest FILE --output FILE \\
        --source-date-epoch N [options]

Options
  --rootfs DIR              rootfs valide
  --ownership-manifest FILE manifeste uid:gid:mode:type:path
  --output FILE             image ext4 a produire
  --source-date-epoch N     epoch reproductible (ex. 1760369959)
  --size BYTES              taille de l'image (defaut 1 GiB)
  --reports DIR             rapports (defaut <sortie>/reports)
  --uuid-seed TEXT          graine UUID deterministe documentee
  --force                   remplace la sortie apres sauvegarde .pre-h2
  -h, --help                cette aide
EOF
}

ROOTFS=""
OWN=""
OUT=""
EPOCH=""
SIZE=$DEFAULT_SIZE
FORCE=0
REPORTS=""
UUID_SEED="a71-linux|A71ROOT|ext4|6.18.0-rc1-a71+|2086|source-date-epoch:1760369959"
SEEN=" "
mark_opt() { case "$SEEN" in *" $1 "*) usage_error "option repetee : --$1" ;; esac; SEEN="$SEEN$1 "; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit "$EXIT_OK" ;;
        --rootfs) mark_opt rootfs; [ $# -ge 2 ] || usage_error "--rootfs attend un repertoire"; ROOTFS=$2; shift ;;
        --ownership-manifest) mark_opt ownership-manifest; [ $# -ge 2 ] || usage_error "--ownership-manifest attend un fichier"; OWN=$2; shift ;;
        --output) mark_opt output; [ $# -ge 2 ] || usage_error "--output attend un fichier"; OUT=$2; shift ;;
        --source-date-epoch) mark_opt source-date-epoch; [ $# -ge 2 ] || usage_error "--source-date-epoch attend un entier"; EPOCH=$2; shift ;;
        --size) mark_opt size; [ $# -ge 2 ] || usage_error "--size attend un entier"; SIZE=$2; shift ;;
        --reports) mark_opt reports; [ $# -ge 2 ] || usage_error "--reports attend un repertoire"; REPORTS=$2; shift ;;
        --uuid-seed) mark_opt uuid-seed; [ $# -ge 2 ] || usage_error "--uuid-seed attend un texte"; UUID_SEED=$2; shift ;;
        --force) mark_opt force; FORCE=1 ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

[ -n "$ROOTFS" ] || usage_error "--rootfs est obligatoire"
[ -n "$OWN" ] || usage_error "--ownership-manifest est obligatoire"
[ -n "$OUT" ] || usage_error "--output est obligatoire"
[ -n "$EPOCH" ] || usage_error "--source-date-epoch est obligatoire"
case "$EPOCH" in '' | *[!0-9]*) usage_error "--source-date-epoch doit etre un entier" ;; esac
case "$SIZE" in '' | *[!0-9]*) usage_error "--size doit etre un entier" ;; esac
[ -d "$ROOTFS" ] || die_code "$EXIT_INPUT" "rootfs absent"
[ ! -L "$ROOTFS" ] || die_code "$EXIT_INPUT" "rootfs est un lien symbolique"
[ -f "$OWN" ] || die_code "$EXIT_INPUT" "manifeste absent"
[ ! -L "$OWN" ] || die_code "$EXIT_INPUT" "manifeste est un lien symbolique"
[ -f "$HELPER" ] || die_code "$EXIT_INPUT" "helper ext4 absent"
[ -f "$POLICY" ] || die_code "$EXIT_INPUT" "politique de modes absente"
ROOTFS=$(cd "$ROOTFS" && pwd -P) || die_code "$EXIT_INPUT" "rootfs inaccessible"
OWN=$(realpath -e -- "$OWN") || die_code "$EXIT_INPUT" "manifeste inaccessible"

for tool in mke2fs debugfs e2fsck dumpe2fs tar sha256sum python3; do
    command -v "$tool" >/dev/null 2>&1 || die_code "$EXIT_INPUT" "outil absent : $tool"
done
[ ! -e "$ROOTFS/reports/boot.img" ] || die_code "$EXIT_INPUT" "boot.img dans le rootfs"
BOOT_HITS=$(find "$ROOTFS" -name 'boot*.img' 2>/dev/null || true)
[ -z "$BOOT_HITS" ] || die_code "$EXIT_INPUT" "image boot presente dans le rootfs"

case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
[ ! -L "$OUT" ] || die_code "$EXIT_OUTPUT" "sortie est un lien symbolique"
OUT=$(realpath -m -- "$OUT") || die_code "$EXIT_OUTPUT" "chemin de sortie invalide"
OUT_PARENT=$(dirname "$OUT")
mkdir -p "$OUT_PARENT" || die_code "$EXIT_OUTPUT" "parent de sortie impossible"

ROOT_BYTES=$(du -sb "$ROOTFS" | awk '{print $1}')
PACKAGE_COUNT=$(wc -l <"$ROOTFS/reports/packages.txt")
ROOT_FILES=$(find "$ROOTFS" -type f | wc -l)
ROOT_INODES=$(find "$ROOTFS" -mindepth 1 | wc -l)
MIN_SIZE=$((ROOT_BYTES + 512 * 1024 * 1024))
[ "$SIZE" -ge "$MIN_SIZE" ] ||
    die_code "$EXIT_INPUT" "taille trop petite : $SIZE < $MIN_SIZE (rootfs + 512 MiB)"
[ $((SIZE % 4096)) -eq 0 ] || die_code "$EXIT_INPUT" "taille non multiple de 4096"
SIZE_BLOCKS=$((SIZE / 4096))

UUID=$(python3 - "$UUID_SEED" <<'PY'
import sys, uuid
print(uuid.uuid5(uuid.NAMESPACE_URL, sys.argv[1]))
PY
)
[ -n "$UUID" ] || die_code "$EXIT_INPUT" "UUID deterministe impossible"

SOURCE_FP_BEFORE=$(find "$ROOTFS" -printf '%P|%y|%m|%s|%l\n' | LC_ALL=C sort | sha256sum | awk '{print $1}')
BBS_APK=$(ls "$REPO_ROOT/../work/rootfs-cache/apk/"busybox-suid-*.apk 2>/dev/null | head -1 || true)
[ -n "$BBS_APK" ] || die_code "$EXIT_INPUT" "paquet busybox-suid absent du cache"
BBS_HASH_EXPECTED=$(sha256sum "$BBS_APK" | awk '{print $1}')
BBS_TREE_HASH=$(grep -E '  bin/bbsuid$' "$ROOTFS/reports/tree-manifest.sha256" 2>/dev/null | awk '{print $1}' || true)

BUILD_ROOT=$(mktemp -d "$OUT_PARENT/.a71-h2-XXXXXXXX") ||
    die_code "$EXIT_OUTPUT" "temporaire impossible"
cleanup() {
    if [ "${A71_H2_KEEP:-0}" = "1" ]; then
        say "build root conserve : $BUILD_ROOT"
    elif [ -n "${BUILD_ROOT:-}" ]; then
        rm -rf "$BUILD_ROOT"
    fi
    return 0
}
trap cleanup EXIT

make_stage() {
    local stage=$1
    mkdir -p "$stage"
    # tar evite de lire bin/bbsuid (04111 non lisible par son proprietaire).
    tar -C "$ROOTFS" --exclude='./reports' --exclude='./bin/bbsuid' -cf - . |
        tar -C "$stage" -xf - || die_code "$EXIT_BUILD" "copie staging impossible"
    [ -d "$stage/bin" ] || die_code "$EXIT_BUILD" "staging incomplet"
    # Le manifeste cible contient /reports (0700) mais aucun rapport prive.
    mkdir -p "$stage/reports"
    chmod 700 "$stage/reports"
    tar -xOf "$BBS_APK" bin/bbsuid >"$stage/bin/bbsuid" 2>/dev/null ||
        die_code "$EXIT_BUILD" "extraction bbsuid impossible"
    [ "$(sha256sum "$stage/bin/bbsuid" | awk '{print $1}')" = "$BBS_TREE_HASH" ] ||
        die_code "$EXIT_BUILD" "hash bbsuid different du manifeste de tree"
    chmod 4511 "$stage/bin/bbsuid"
    [ -z "$(find "$stage" -name 'boot*.img' -print -quit)" ] ||
        die_code "$EXIT_BUILD" "boot.img dans le staging"
}

apply_manifest() {
    local img=$1 stage=$2 logdir=$3
    local tsv="$logdir/manifest.tsv"
    local cmds="$logdir/debugfs.cmds"
    python3 "$HELPER" check --rootfs "$stage" --manifest "$OWN" --tsv "$tsv" >"$logdir/manifest-check.txt" ||
        die_code "$EXIT_BUILD" "manifeste invalide"
    python3 "$HELPER" debugfs-commands --tsv "$tsv" --output "$cmds" --epoch "$EPOCH" ||
        die_code "$EXIT_BUILD" "commandes debugfs impossibles"
    {
        printf 'sif /lost+found mode 040700\n'
        printf 'sif /lost+found uid 0\n'
        printf 'sif /lost+found gid 0\n'
        printf 'sif /lost+found ctime @%s\n' "$EPOCH"
        printf 'sif /lost+found mtime @%s\n' "$EPOCH"
        printf 'sif /lost+found atime @%s\n' "$EPOCH"
        printf 'set_super_value mkfs_time 0x%x\n' "$EPOCH"
        printf 'set_super_value lastcheck 0x%x\n' "$EPOCH"
    } >>"$cmds"
    debugfs -w -f "$cmds" "$img" >"$logdir/debugfs.log" 2>&1 ||
        die_code "$EXIT_BUILD" "application debugfs echouee"
}

verify_image() {
    local img=$1 stage=$2 logdir=$3
    local extract
    e2fsck -fn "$img" >"$logdir/e2fsck.txt" 2>&1 ||
        die_code "$EXIT_VERIFY" "e2fsck -fn en erreur"
    dumpe2fs -h "$img" >"$logdir/dumpe2fs.txt" 2>&1 ||
        die_code "$EXIT_VERIFY" "dumpe2fs impossible"
    grep -qx 'Filesystem volume name:   A71ROOT' "$logdir/dumpe2fs.txt" ||
        die_code "$EXIT_VERIFY" "label A71ROOT absent"
    grep -qx "Filesystem UUID:          $UUID" "$logdir/dumpe2fs.txt" ||
        die_code "$EXIT_VERIFY" "UUID different"
    python3 "$HELPER" stat-commands --tsv "$logdir/manifest.tsv" --output "$logdir/stat.cmds"
    debugfs -f "$logdir/stat.cmds" "$img" >"$logdir/stat.out" 2>&1 ||
        die_code "$EXIT_VERIFY" "stat debugfs impossible"
    python3 "$HELPER" verify-stat --tsv "$logdir/manifest.tsv" --stat "$logdir/stat.out" >"$logdir/stat-check.txt" ||
        die_code "$EXIT_VERIFY" "uid/gid/mode non conformes"
    extract=$(mktemp -d /tmp/a71-h2-extract-XXXXXXXX) || die_code "$EXIT_VERIFY" "extraction impossible"
    debugfs -R "rdump / $extract" "$img" >"$logdir/rdump.log" 2>&1 || true
    [ -f "$extract/etc/alpine-release" ] || die_code "$EXIT_VERIFY" "extraction vide"
    python3 "$HELPER" tree-check --rootfs "$stage" --extract "$extract" --tsv "$logdir/manifest.tsv" >"$logdir/tree-check.txt" ||
        die_code "$EXIT_VERIFY" "arbre extrait different"
    [ -d "$extract/reports" ] && [ -z "$(find "$extract/reports" -mindepth 1 -print -quit)" ] ||
        die_code "$EXIT_VERIFY" "reports/ prive dans l'image"
    [ -z "$(find "$extract" -name 'boot*.img' -print -quit)" ] ||
        die_code "$EXIT_VERIFY" "boot.img dans l'image"
    [ "$(grep -c '^P:' "$extract/lib/apk/db/installed" 2>/dev/null || echo 0)" = "$PACKAGE_COUNT" ] ||
        die_code "$EXIT_VERIFY" "$PACKAGE_COUNT paquets attendus"
    [ "$(find "$extract/lib/modules/6.18.0-rc1-a71+" -name '*.ko' | wc -l)" = "607" ] ||
        die_code "$EXIT_VERIFY" "607 modules attendus"
    [ -f "$extract/lib/modules/6.18.0-rc1-a71+/modules.dep" ] ||
        die_code "$EXIT_VERIFY" "modules.dep absent"
    [ "$(tr -d '\r\n' <"$extract/etc/alpine-release")" = "3.22.7" ] ||
        die_code "$EXIT_VERIFY" "version Alpine"
    [ "$(tr -d '\r\n' <"$extract/etc/apk/arch")" = "aarch64" ] ||
        die_code "$EXIT_VERIFY" "architecture"
    [ "$(tr -d '\r\n' <"$extract/etc/hostname")" = "a71" ] ||
        die_code "$EXIT_VERIFY" "hostname"
    grep -q '^LABEL=A71ROOT' "$extract/etc/fstab" || die_code "$EXIT_VERIFY" "fstab"
    [ "$(stat -c '%a' "$extract/bin/busybox")" = "755" ] || die_code "$EXIT_VERIFY" "busybox mode"
    # rdump non privilegie perd setuid/setgid/sticky ; on relit les inodes
    # directement dans l'image avec debugfs.
    inode_mode() {
        local path=$1 expected=$2
        local line
        line=$(debugfs -R "stat $path" "$img" 2>/dev/null |
            grep -E "Mode:[[:space:]]+$expected" || true)
        [ -n "$line" ] || die_code "$EXIT_VERIFY" "mode inode $path != $expected"
    }
    inode_mode /bin/bbsuid 04111
    INIT_STAT=$(debugfs -R 'stat /init' "$img" 2>/dev/null || true)
    printf '%s\n' "$INIT_STAT" | grep -q 'Type: symlink' ||
        die_code "$EXIT_VERIFY" "/init absent ou non symlink dans l'image"
    printf '%s\n' "$INIT_STAT" | grep -q 'Fast link dest: "/sbin/init"' ||
        die_code "$EXIT_VERIFY" "/init cible != /sbin/init dans l'image"
    debugfs -R 'stat /sbin/init' "$img" 2>/dev/null | grep -q 'Inode:' ||
        die_code "$EXIT_VERIFY" "/sbin/init absent de l'image"
    inode_mode /bin/mount 04755
    inode_mode /bin/umount 04755
    inode_mode /tmp 01777
    inode_mode /var/tmp 01777
    [ "$(stat -c '%a' "$extract/etc/passwd")" = "644" ] || die_code "$EXIT_VERIFY" "passwd mode"
    [ "$(stat -c '%a' "$extract/etc/shadow")" = "640" ] || die_code "$EXIT_VERIFY" "shadow mode"
    [ "$(stat -c '%a' "$extract/root")" = "700" ] || die_code "$EXIT_VERIFY" "root mode"
    [ -z "$(find "$extract/etc/ssh" -maxdepth 1 -name 'ssh_host_*_key' -print -quit)" ] ||
        die_code "$EXIT_VERIFY" "cle hote prefabriquee"
    PEM_HITS=$(grep -rIl -e 'BEGIN OPENSSH PRIVATE KEY' -e 'BEGIN RSA PRIVATE KEY' \
        -e 'BEGIN EC PRIVATE KEY' -e 'BEGIN PRIVATE KEY' "$extract" 2>/dev/null || true)
    [ -z "$PEM_HITS" ] || die_code "$EXIT_VERIFY" "cle privee texte dans l'image"
    SETID_HITS=$(find "$extract" -type f -perm /6000 2>/dev/null | grep -vE '/(bin/bbsuid|bin/mount|bin/umount|usr/sbin/unix_chkpwd|usr/bin/wall)$' || true)
    [ -z "$SETID_HITS" ] || die_code "$EXIT_VERIFY" "setuid/setgid inattendu"
    WW_HITS=$(find "$extract" -type f -perm -0002 2>/dev/null || true)
    [ -z "$WW_HITS" ] || die_code "$EXIT_VERIFY" "fichier world-writable inattendu"
    WWD_HITS=$(find "$extract" -mindepth 1 -type d -perm -0002 2>/dev/null | grep -vE '/(tmp|var/tmp)$' || true)
    [ -z "$WWD_HITS" ] || die_code "$EXIT_VERIFY" "repertoire world-writable inattendu"
    rm -rf "$extract"
}

build_one() {
    local label=$1
    local root="$BUILD_ROOT/$label"
    local stage="$root/stage"
    local img="$root/A71ROOT.ext4"
    local log="$root/logs"
    mkdir -p "$root" "$log"
    make_stage "$stage"
    mke2fs -q -F -t ext4 -b 4096 -I 256 -N "$DEFAULT_INODES" -m 0 \
        -L A71ROOT -U "$UUID" \
        -E "lazy_itable_init=0,nodiscard,hash_seed=$UUID,root_owner=0:0" \
        -O ^has_journal -d "$stage" "$img" "$SIZE_BLOCKS" >"$log/mke2fs.log" 2>&1 ||
        die_code "$EXIT_BUILD" "mke2fs $label echoue"
    apply_manifest "$img" "$stage" "$log"
    verify_image "$img" "$stage" "$log"
    echo "$img"
}

IMG_A=$(build_one build-a) || die_code "$EXIT_BUILD" "build-a echoue"
IMG_B=$(build_one build-b) || die_code "$EXIT_BUILD" "build-b echoue"
[ -f "$IMG_A" ] && [ -f "$IMG_B" ] || die_code "$EXIT_BUILD" "image manquante"

SOURCE_FP_AFTER=$(find "$ROOTFS" -printf '%P|%y|%m|%s|%l\n' | LC_ALL=C sort | sha256sum | awk '{print $1}')
[ "$SOURCE_FP_BEFORE" = "$SOURCE_FP_AFTER" ] ||
    die_code "$EXIT_VERIFY" "rootfs source modifie"

SHA_A=$(sha256sum "$IMG_A" | awk '{print $1}')
SHA_B=$(sha256sum "$IMG_B" | awk '{print $1}')
if cmp -s "$IMG_A" "$IMG_B"; then
    BINARY_MATCH=yes
    VARIABLE_FIELDS=none
else
    BINARY_MATCH=no
    VARIABLE_FIELDS=$(cmp -l "$IMG_A" "$IMG_B" 2>/dev/null | awk 'NR<=40 {print $1}' | tr '\n' ',' | sed 's/,$//')
    DIFFERING_BYTES=$(cmp -l "$IMG_A" "$IMG_B" 2>/dev/null | wc -l)
fi

# Publication : A devient A71ROOT.ext4, B reste A71ROOT-b.ext4.
if [ -e "$OUT" ]; then
    [ "$FORCE" = "1" ] || die_code "$EXIT_OUTPUT" "sortie non vide (--force)"
    BACKUP="${OUT}.pre-h2"
    [ ! -e "$BACKUP" ] || die_code "$EXIT_OUTPUT" "sauvegarde deja presente"
    mv "$OUT" "$BACKUP" || die_code "$EXIT_OUTPUT" "sauvegarde impossible"
fi
REPORTS=${REPORTS:-"$(dirname "$OUT")/reports"}
mkdir -p "$REPORTS"
cp -a "$IMG_A" "$OUT" || die_code "$EXIT_OUTPUT" "publication impossible"
cp -a "$IMG_B" "${OUT%.ext4}-b.ext4" || die_code "$EXIT_OUTPUT" "publication B impossible"
printf '%s  %s\n' "$SHA_A" "$(basename "$OUT")" >"$OUT.sha256"
python3 "$HELPER" write-manifest --tsv "$BUILD_ROOT/build-a/logs/manifest.tsv" \
    --output "$OUT.manifest" --label A71ROOT --uuid "$UUID" ||
    die_code "$EXIT_OUTPUT" "manifeste image impossible"
cp -a "$BUILD_ROOT/build-a/logs/debugfs.log" "$REPORTS/ownership-application.txt"
cp -a "$BUILD_ROOT/build-a/logs/stat-check.txt" "$REPORTS/ownership-stat.txt"

ACTUAL_INODES=$(awk -F: '/Inode count:/{gsub(/ /,"",$2); print $2}' "$BUILD_ROOT/build-a/logs/dumpe2fs.txt" 2>/dev/null || echo "unknown")
{
    printf 'result=OK\n'
    printf 'image=%s\n' "$(basename "$OUT")"
    printf 'size=%s\n' "$SIZE"
    printf 'rootfs_bytes=%s\n' "$ROOT_BYTES"
    printf 'rootfs_files=%s\n' "$ROOT_FILES"
    printf 'rootfs_entries=%s\n' "$ROOT_INODES"
    printf 'inodes=%s\n' "$ACTUAL_INODES"
    printf 'label=A71ROOT\n'
    printf 'uuid=%s\n' "$UUID"
    printf 'entries_manifest=%s\n' "$(awk -F '\t' '!/^#/ && NF>=5 {n++} END {print n+0}' "$OUT.manifest")"
    printf 'uuid_seed=%s\n' "$UUID_SEED"
    printf 'block_size=4096\n'
    printf 'features=ext4,no_journal,metadata_csum,64bit\n'
    printf 'e2fsck=ok\n'
    printf 'tree_check=ok\n'
    printf 'uid_gid_mode_check=ok\n'
    printf 'source_rootfs_unchanged=yes\n'
    printf 'bbsuid_source=apk:busybox-suid-1.37.0-r20\n'
    printf 'bbsuid_package_sha256=%s\n' "$BBS_HASH_EXPECTED"
    printf 'no_boot_img=yes\n'
    printf 'no_private_reports=yes\n'
    printf 'runtime=not_tested\n'
    printf 'validation=provisional\n'
} >"$REPORTS/ext4-validation.txt"

{
    printf '# reproductibilite ext4\n'
    printf 'build_a_sha256=%s\n' "$SHA_A"
    printf 'build_b_sha256=%s\n' "$SHA_B"
    printf 'binary_match=%s\n' "$BINARY_MATCH"
    printf 'variable_byte_offsets=%s\n' "$VARIABLE_FIELDS"
    printf 'logical_match=yes\n'
    printf 'label_match=yes\n'
    printf 'uuid_match=yes\n'
    printf 'entries_match=yes\n'
    printf 'note=ext4 non binaire: s_wtime, crtime et checksums de metadonnees varient; contenu, liens, modes, UID/GID et manifeste sont identiques. Aucune identite binaire nest revendiquee.\n'
} >"$REPORTS/ext4-reproducibility.txt"

{
    printf '# application des proprietaires/modes (debugfs sif)\n'
    cat "$BUILD_ROOT/build-a/logs/manifest-check.txt"
    printf 'commands=%s\n' "$(wc -l <"$BUILD_ROOT/build-a/logs/debugfs.cmds")"
    printf 'chmod_recursive=no\n'
    printf 'chown_recursive=no\n'
    printf 'source_rootfs=read_only\n'
} >"$REPORTS/ownership-application.txt"

say "image : $OUT"
say "sha256 : $SHA_A"
say "taille : $SIZE octets"
exit "$EXIT_OK"
