#!/usr/bin/env bash
# shellcheck shell=bash
#
# build-uniloader.sh - compile uniLoader epingle, deux fois, sans boot.img (G1).
#
# Contrat reel observe dans les sources (commit 4c626a73) :
#   * le noyau, le DTB et l'initramfs sont des blobs d'entree du linker :
#       blob/Image, blob/dtb, blob/ramdisk
#     (CONFIG_KERNEL_PATH / CONFIG_DT_PATH / CONFIG_RAMDISK_PATH) ;
#   * ils sont emballes dans la sortie brute `uniLoader` (section .kernel,
#     .dtb, .ramdisk), puis copies en RAM par arch/aarch64/load-kernel.c ;
#   * la sortie `uniLoader` porte l'en-tete Linux ARM64 Image
#     (CONFIG_LINUX_KRNL_HEADER_IMG=y) ; `uniLoader.gz` est sa compression ;
#   * aucun argument separe noyau/initramfs n'est accepte par uniLoader :
#     l'integration se fait par les blobs du linker.
#
# Aucun montage, chroot, sudo, QEMU, loop device, flash ni boot.img.
#
# Codes : 0 ok, 2 usage, 3 entree, 4 contrat/build, 5 verification,
#         6 sortie.

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

EXPECTED_COMMIT=4c626a73cc38308227b5c28e75558b3da574312b
PR_HEAD=b253dc48f9d297786df60d4389552752ccfb65da
REPOSITORY=https://github.com/ivoszbg/uniLoader
SOURCE_DATE_EPOCH_FIXED=1760369959

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() { say "$1"; printf 'Utilise --help.\n' >&2; exit "$EXIT_USAGE"; }
die_code() { local c=$1; shift; say "$*"; exit "$c"; }

usage() {
    cat <<EOF
$PROG - compilation uniLoader epinglee (deux builds, sans boot.img)

Usage
  $PROG --source DIR --toolchain-root DIR --kernel-image FILE \\
        --initramfs FILE --output DIR [options]

Options
  --source DIR           arbre Git uniLoader au commit 4c626a73
  --toolchain-root DIR   toolchain AArch64 validee (racine contenant bin/)
  --kernel-image FILE    Image Linux ARM64 (fichier regulier)
  --initramfs FILE       initramfs cpio.gz (fichier regulier)
  --dtb FILE             DTB mainline (defaut : a cote de l'Image)
  --output DIR           sortie work/uniloader
  --jobs N               parallelisme (1..128)
  --force                remplace la sortie apres sauvegarde .pre-g1
  -h, --help             cette aide

Le commit est verifie exact ; l'arbre doit etre propre. Les builds se font
dans des copies temporaires sans espace, puis sont publies atomiquement.
EOF
}

SOURCE=""
TOOLCHAIN=""
KERNEL_IMAGE=""
INITRAMFS=""
DTB=""
OUT_DIR=""
JOBS=12
FORCE=0
SEEN=" "
mark_opt() { case "$SEEN" in *" $1 "*) usage_error "option repetee : --$1" ;; esac; SEEN="$SEEN$1 "; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit "$EXIT_OK" ;;
        --source) mark_opt source; [ $# -ge 2 ] || usage_error "--source attend un repertoire"; SOURCE=$2; shift ;;
        --toolchain-root) mark_opt toolchain-root; [ $# -ge 2 ] || usage_error "--toolchain-root attend un repertoire"; TOOLCHAIN=$2; shift ;;
        --kernel-image) mark_opt kernel-image; [ $# -ge 2 ] || usage_error "--kernel-image attend un fichier"; KERNEL_IMAGE=$2; shift ;;
        --initramfs) mark_opt initramfs; [ $# -ge 2 ] || usage_error "--initramfs attend un fichier"; INITRAMFS=$2; shift ;;
        --dtb) mark_opt dtb; [ $# -ge 2 ] || usage_error "--dtb attend un fichier"; DTB=$2; shift ;;
        --output) mark_opt output; [ $# -ge 2 ] || usage_error "--output attend un repertoire"; OUT_DIR=$2; shift ;;
        --jobs) mark_opt jobs; [ $# -ge 2 ] || usage_error "--jobs attend un entier"; JOBS=$2; shift ;;
        --force) mark_opt force; FORCE=1 ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

[ -n "$SOURCE" ] || usage_error "--source est obligatoire"
[ -n "$TOOLCHAIN" ] || usage_error "--toolchain-root est obligatoire"
[ -n "$KERNEL_IMAGE" ] || usage_error "--kernel-image est obligatoire"
[ -n "$INITRAMFS" ] || usage_error "--initramfs est obligatoire"
[ -n "$OUT_DIR" ] || usage_error "--output est obligatoire"
case "$JOBS" in '' | *[!0-9]*) usage_error "--jobs doit etre un entier" ;; esac
[ "$JOBS" -ge 1 ] && [ "$JOBS" -le 128 ] || usage_error "--jobs hors limites"

[ -d "$SOURCE" ] || die_code "$EXIT_INPUT" "source absente"
[ -d "$SOURCE/.git" ] || die_code "$EXIT_INPUT" "source n'est pas un depot Git"
[ -d "$TOOLCHAIN/bin" ] || die_code "$EXIT_INPUT" "toolchain/bin absent"
[ -f "$KERNEL_IMAGE" ] || die_code "$EXIT_INPUT" "Image absente"
[ ! -L "$KERNEL_IMAGE" ] || die_code "$EXIT_INPUT" "Image est un lien symbolique"
[ -f "$INITRAMFS" ] || die_code "$EXIT_INPUT" "initramfs absent"
[ ! -L "$INITRAMFS" ] || die_code "$EXIT_INPUT" "initramfs est un lien symbolique"
if [ -z "$DTB" ]; then
    DTB="$(dirname "$KERNEL_IMAGE")/sm7150-samsung-a715f.dtb"
fi
[ -f "$DTB" ] || die_code "$EXIT_INPUT" "DTB absent"
[ ! -L "$DTB" ] || die_code "$EXIT_INPUT" "DTB est un lien symbolique"

SOURCE=$(cd "$SOURCE" && pwd -P) || die_code "$EXIT_INPUT" "source inaccessible"
TOOLCHAIN=$(cd "$TOOLCHAIN" && pwd -P) || die_code "$EXIT_INPUT" "toolchain inaccessible"
KERNEL_IMAGE=$(realpath -e -- "$KERNEL_IMAGE") || die_code "$EXIT_INPUT" "Image inaccessible"
INITRAMFS=$(realpath -e -- "$INITRAMFS") || die_code "$EXIT_INPUT" "initramfs inaccessible"
DTB=$(realpath -e -- "$DTB") || die_code "$EXIT_INPUT" "DTB inaccessible"

# --- Gardes Git / contrat -------------------------------------------------
HEAD=$(git -C "$SOURCE" rev-parse HEAD 2>/dev/null) || die_code "$EXIT_INPUT" "HEAD illisible"
[ "$HEAD" = "$EXPECTED_COMMIT" ] ||
    die_code "$EXIT_INPUT" "commit inattendu : $HEAD (attendu $EXPECTED_COMMIT)"
git -C "$SOURCE" merge-base --is-ancestor "$HEAD" refs/remotes/origin/master ||
    die_code "$EXIT_INPUT" "commit non atteignable depuis origin/master"
[ -z "$(git -C "$SOURCE" status --porcelain)" ] ||
    die_code "$EXIT_INPUT" "arbre source sale"
[ -f "$SOURCE/configs/a71_defconfig" ] || die_code "$EXIT_INPUT" "defconfig absent"
[ -f "$SOURCE/board/samsung/board-a71.c" ] || die_code "$EXIT_INPUT" "board file absent"

# Contrat verifie dans les sources (pas suppose).
grep -q 'CONFIG_LINUX_KRNL_HEADER_IMG=y' "$SOURCE/.config" 2>/dev/null ||
    grep -q 'CONFIG_LINUX_KRNL_HEADER_IMG=y' "$SOURCE/configs/a71_defconfig" ||
    die_code "$EXIT_INPUT" "en-tete Linux Image non active dans la defconfig"
for token in 'INPUT(KERNEL_PATH)' 'INPUT(DTB_PATH)' 'INPUT(RAMDISK_PATH)'; do
    grep -qF "$token" "$SOURCE/arch/aarch64/linker.lds.S" ||
        die_code "$EXIT_INPUT" "contrat linker absent : $token"
done
grep -q 'CONFIG_KERNEL_PATH' "$SOURCE/Makefile" ||
    die_code "$EXIT_INPUT" "variable KERNEL_PATH absente du Makefile"
grep -q 'CONFIG_RAMDISK_NO_COPY' "$SOURCE/configs/a71_defconfig" &&
    die_code "$EXIT_INPUT" "defconfig RAMDISK_NO_COPY incompatible avec un initramfs"

# --- Toolchain ------------------------------------------------------------
CC=""
for candidate in "$TOOLCHAIN/bin/"*-gcc; do
    [ -x "$candidate" ] || continue
    if "$candidate" -dumpmachine 2>/dev/null | grep -q '^aarch64'; then
        CC=$candidate
        break
    fi
done
[ -n "$CC" ] || die_code "$EXIT_INPUT" "compilateur AArch64 absent"
PREFIX=$(basename "$CC")
PREFIX=${PREFIX%gcc}
[ -x "$TOOLCHAIN/bin/${PREFIX}ld" ] || die_code "$EXIT_INPUT" "linker AArch64 absent"
"$CC" -dumpmachine | grep -q '^aarch64-buildroot-linux-gnu$' ||
    die_code "$EXIT_INPUT" "cible toolchain inattendue : $("$CC" -dumpmachine)"

# --- Chemins sans espace + sortie ----------------------------------------
case "$OUT_DIR" in /*) ;; *) OUT_DIR="$PWD/$OUT_DIR" ;; esac
[ ! -L "$OUT_DIR" ] || die_code "$EXIT_OUTPUT" "sortie est un lien symbolique"
OUT_DIR=$(realpath -m -- "$OUT_DIR") || die_code "$EXIT_OUTPUT" "chemin de sortie invalide"
OUT_PARENT=$(dirname "$OUT_DIR")
mkdir -p "$OUT_PARENT" || die_code "$EXIT_OUTPUT" "parent de sortie impossible"

BUILD_ROOT=$(mktemp -d /tmp/a71-uniloader-XXXXXXXX) ||
    die_code "$EXIT_OUTPUT" "temporaire sans espace impossible"
cleanup() {
    if [ -n "${BUILD_ROOT:-}" ]; then rm -rf "$BUILD_ROOT"; fi
    return 0
}
trap cleanup EXIT

TC_BUILD="$BUILD_ROOT/tc"
cp -a "$TOOLCHAIN" "$TC_BUILD" || die_code "$EXIT_BUILD" "copie toolchain impossible"
CROSS="$TC_BUILD/bin/$PREFIX"
"$CROSS"gcc -dumpmachine >/dev/null 2>&1 ||
    die_code "$EXIT_BUILD" "toolchain copiee inutilisable"

BUILD_DATE=$(date -u -d "@$SOURCE_DATE_EPOCH_FIXED" '+%Y-%m-%d %H:%M:%S') ||
    die_code "$EXIT_BUILD" "date reproductible impossible"

hash_of() { sha256sum "$1" | awk '{print $1}'; }
size_of() { stat -c '%s' "$1"; }

INPUT_IMAGE_SHA=$(hash_of "$KERNEL_IMAGE")
INPUT_INITRAMFS_SHA=$(hash_of "$INITRAMFS")
INPUT_DTB_SHA=$(hash_of "$DTB")

build_one() {
    local label=$1
    local root="$BUILD_ROOT/$label"
    local src="$root/src"
    local log="$root"
    mkdir -p "$src" "$log"
    cp -a "$SOURCE/." "$src/" || die_code "$EXIT_BUILD" "copie source $label impossible"
    mkdir -p "$src/blob"
    cp "$KERNEL_IMAGE" "$src/blob/Image" || die_code "$EXIT_BUILD" "copie Image impossible"
    cp "$DTB" "$src/blob/dtb" || die_code "$EXIT_BUILD" "copie DTB impossible"
    cp "$INITRAMFS" "$src/blob/ramdisk" || die_code "$EXIT_BUILD" "copie initramfs impossible"

    ( cd "$src" && env -i PATH="$TC_BUILD/bin:/usr/bin:/bin" LC_ALL=C TZ=UTC \
        SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH_FIXED" \
        KBUILD_BUILD_USER=a71-builder KBUILD_BUILD_HOST=a71-build \
        GZIP='-n -9' \
        make ARCH=aarch64 CROSS_COMPILE="$CROSS" a71_defconfig ) >"$log/config.log" 2>&1 ||
        die_code "$EXIT_BUILD" "defconfig $label echouee"

    ( cd "$src" && env -i PATH="$TC_BUILD/bin:/usr/bin:/bin" LC_ALL=C TZ=UTC \
        SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH_FIXED" \
        KBUILD_BUILD_USER=a71-builder KBUILD_BUILD_HOST=a71-build \
        GZIP='-n -9' \
        make ARCH=aarch64 CROSS_COMPILE="$CROSS" -j"$JOBS" \
        BUILD_DATE="$BUILD_DATE" ) >"$log/build.log" 2>&1 ||
        die_code "$EXIT_BUILD" "build $label echoue"

    [ -f "$src/uniLoader" ] || die_code "$EXIT_BUILD" "uniLoader absent ($label)"
    [ -f "$src/uniLoader.o" ] || die_code "$EXIT_BUILD" "uniLoader.o absent ($label)"
    # gzip du Makefile garde le mtime : on le normalise explicitement.
    gzip -n -9 -c "$src/uniLoader" >"$log/uniLoader.gz" ||
        die_code "$EXIT_BUILD" "compression deterministe impossible ($label)"
    cp "$src/uniLoader" "$log/uniLoader"
    cp "$src/uniLoader.o" "$log/uniLoader.o"
    [ -z "$(git -C "$src" status --porcelain)" ] ||
        die_code "$EXIT_VERIFY" "source modifiee pendant le build ($label)"
}

build_one build-a
build_one build-b

# --- Verifications de sortie ---------------------------------------------
for label in build-a build-b; do
    dir="$BUILD_ROOT/$label"
    [ -f "$dir/uniLoader" ] && [ ! -L "$dir/uniLoader" ] ||
        die_code "$EXIT_VERIFY" "sortie non reguliere ($label)"
    [ -f "$dir/uniLoader.o" ] && [ ! -L "$dir/uniLoader.o" ] ||
        die_code "$EXIT_VERIFY" "uniLoader.o non regulier ($label)"
    file "$dir/uniLoader" | grep -q 'Linux kernel ARM64 boot executable Image' ||
        die_code "$EXIT_VERIFY" "format brut inattendu ($label)"
    file "$dir/uniLoader.o" | grep -q 'ELF 64-bit.*ARM aarch64' ||
        die_code "$EXIT_VERIFY" "uniLoader.o non ELF AArch64 ($label)"
    gzip -t "$dir/uniLoader.gz" || die_code "$EXIT_VERIFY" "gzip invalide ($label)"
    gzip -dc "$dir/uniLoader.gz" | cmp -s - "$dir/uniLoader" ||
        die_code "$EXIT_VERIFY" "gzip != uniLoader ($label)"
    [ "$(find "$dir" -maxdepth 1 -name 'boot*.img' | wc -l)" = "0" ] ||
        die_code "$EXIT_VERIFY" "boot.img produit ($label)"
done

for pair in 'uniLoader' 'uniLoader.o' 'uniLoader.gz'; do
    cmp -s "$BUILD_ROOT/build-a/$pair" "$BUILD_ROOT/build-b/$pair" ||
        die_code "$EXIT_VERIFY" "divergence entre les deux builds : $pair"
done

[ "$(hash_of "$KERNEL_IMAGE")" = "$INPUT_IMAGE_SHA" ] ||
    die_code "$EXIT_VERIFY" "Image modifiee pendant le build"
[ "$(hash_of "$INITRAMFS")" = "$INPUT_INITRAMFS_SHA" ] ||
    die_code "$EXIT_VERIFY" "initramfs modifie pendant le build"
[ "$(hash_of "$DTB")" = "$INPUT_DTB_SHA" ] ||
    die_code "$EXIT_VERIFY" "DTB modifie pendant le build"

# --- Publication ----------------------------------------------------------
if [ -e "$OUT_DIR" ]; then
    [ "$FORCE" = "1" ] || die_code "$EXIT_OUTPUT" "sortie non vide (--force)"
    BACKUP="${OUT_DIR}.pre-g1"
    [ ! -e "$BACKUP" ] || die_code "$EXIT_OUTPUT" "sauvegarde deja presente : $BACKUP"
    mv "$OUT_DIR" "$BACKUP" || die_code "$EXIT_OUTPUT" "sauvegarde impossible"
fi
mkdir -p "$OUT_DIR/artifacts" "$OUT_DIR/reports"
for label in build-a build-b; do
    mkdir -p "$OUT_DIR/$label"
    cp -a "$BUILD_ROOT/$label/uniLoader" "$OUT_DIR/$label/uniLoader"
    cp -a "$BUILD_ROOT/$label/uniLoader.o" "$OUT_DIR/$label/uniLoader.o"
    cp -a "$BUILD_ROOT/$label/uniLoader.gz" "$OUT_DIR/$label/uniLoader.gz"
    cp -a "$BUILD_ROOT/$label/config.log" "$OUT_DIR/$label/config.log"
    cp -a "$BUILD_ROOT/$label/build.log" "$OUT_DIR/$label/build.log"
done
cp -a "$BUILD_ROOT/build-a/uniLoader" "$OUT_DIR/artifacts/uniLoader"
cp -a "$BUILD_ROOT/build-a/uniLoader.o" "$OUT_DIR/artifacts/uniLoader.o"
cp -a "$BUILD_ROOT/build-a/uniLoader.gz" "$OUT_DIR/artifacts/uniLoader.gz"

OUT_SHA=$(hash_of "$OUT_DIR/artifacts/uniLoader")
OUT_GZ_SHA=$(hash_of "$OUT_DIR/artifacts/uniLoader.gz")
OUT_O_SHA=$(hash_of "$OUT_DIR/artifacts/uniLoader.o")
OUT_SIZE=$(size_of "$OUT_DIR/artifacts/uniLoader")
OUT_GZ_SIZE=$(size_of "$OUT_DIR/artifacts/uniLoader.gz")

for label in build-a build-b; do
    d="$OUT_DIR/$label"
    {
        printf 'result=OK\n'
        printf 'repository=%s\n' "$REPOSITORY"
        printf 'commit=%s\n' "$EXPECTED_COMMIT"
        printf 'pr_head=%s\n' "$PR_HEAD"
        printf 'defconfig=configs/a71_defconfig\n'
        printf 'board=board/samsung/board-a71.c\n'
        printf 'toolchain_target=%s\n' "$("$CC" -dumpmachine)"
        printf 'compiler=%s\n' "$(basename "$CC")"
        printf 'source_date_epoch=%s\n' "$SOURCE_DATE_EPOCH_FIXED"
        printf 'build_date=%s\n' "$BUILD_DATE"
        printf 'jobs=%s\n' "$JOBS"
        printf 'kernel_image_sha256=%s\n' "$INPUT_IMAGE_SHA"
        printf 'dtb_sha256=%s\n' "$INPUT_DTB_SHA"
        printf 'initramfs_sha256=%s\n' "$INPUT_INITRAMFS_SHA"
        printf 'uniLoader_size=%s\n' "$(size_of "$d/uniLoader")"
        printf 'uniLoader_sha256=%s\n' "$(hash_of "$d/uniLoader")"
        printf 'uniLoader_o_sha256=%s\n' "$(hash_of "$d/uniLoader.o")"
        printf 'uniLoader_gz_sha256=%s\n' "$(hash_of "$d/uniLoader.gz")"
        printf 'format=%s\n' "$(file -b "$d/uniLoader")"
        printf 'boot_img=no\n'
        printf 'validation=provisional\n'
    } >"$OUT_DIR/reports/$label.txt"
done
{
    printf '# reproductibilite uniLoader\n'
    printf 'build_a_sha256=%s\n' "$(hash_of "$OUT_DIR/build-a/uniLoader")"
    printf 'build_b_sha256=%s\n' "$(hash_of "$OUT_DIR/build-b/uniLoader")"
    printf 'build_a_gz_sha256=%s\n' "$(hash_of "$OUT_DIR/build-a/uniLoader.gz")"
    printf 'build_b_gz_sha256=%s\n' "$(hash_of "$OUT_DIR/build-b/uniLoader.gz")"
    printf 'build_a_o_sha256=%s\n' "$(hash_of "$OUT_DIR/build-a/uniLoader.o")"
    printf 'build_b_o_sha256=%s\n' "$(hash_of "$OUT_DIR/build-b/uniLoader.o")"
    printf 'raw_match=yes\n'
    printf 'elf_match=yes\n'
    printf 'gz_match=yes\n'
    printf 'overall_reproducible=yes\n'
    printf 'gzip_normalized=gzip -n -9\n'
} >"$OUT_DIR/reports/reproducibility.txt"
cat >"$OUT_DIR/reports/provenance.json" <<EOF
{
  "repository": "$REPOSITORY",
  "commit": "$EXPECTED_COMMIT",
  "pr_head": "$PR_HEAD",
  "defconfig": "configs/a71_defconfig",
  "board_file": "board/samsung/board-a71.c",
  "signature_status": "unsigned",
  "license_reported": "GPL-2.0",
  "license_spdx_status": "TODO_VERIFIER",
  "validation_status": "provisional",
  "input_contract": "blob/Image + blob/dtb + blob/ramdisk via linker INPUT",
  "output_format": "raw ARM64 Image header + gzip",
  "boot_image_created": false,
  "chroot_used": false,
  "mount_used": false,
  "qemu_used": false,
  "sudo_used": false
}
EOF
{
    printf 'uniLoader %s  artifacts/uniLoader\n' "$OUT_SHA"
    printf 'uniLoader.gz %s  artifacts/uniLoader.gz\n' "$OUT_GZ_SHA"
} >"$OUT_DIR/artifacts/SHA256SUMS"

say "uniLoader : $OUT_DIR/artifacts/uniLoader"
say "sha256 : $OUT_SHA"
say "taille : $OUT_SIZE octets ; gz : $OUT_GZ_SIZE octets"
exit "$EXIT_OK"
