#!/usr/bin/env bash
# shellcheck shell=bash
#
# audit-boot-artifacts.sh - inventaire lecture seule des artefacts de boot (J2).
#
# Verifie les hashes contre les rapports de build existants. Ne modifie aucun
# artefact. Aucun acces dispositif, aucun boot.img suppose valide.
#
# Codes : 0 ok, 2 usage, 3 entree, 4 hash/format, 5 rapport.

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
WORK=$(cd "$REPO_ROOT/.." && pwd)/work
OUT="$WORK/boot/reports"
PROG=$(basename "$0")

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
fail() { local c=$1; shift; say "$*"; exit "$c"; }

[ -d "$WORK" ] || fail 3 "workspace work absent"
for tool in sha256sum stat file gzip od python3; do
    command -v "$tool" >/dev/null 2>&1 || fail 3 "outil absent : $tool"
done
mkdir -p "$OUT" || fail 5 "rapport impossible"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/a71-boot-audit-XXXXXXXX") || fail 5 "temporaire impossible"
trap 'rm -rf "$TMP"' EXIT

IMAGE="$WORK/kernel-build/artifacts/Image"
DTB="$WORK/kernel-build/artifacts/sm7150-samsung-a715f.dtb"
INITRAMFS="$WORK/initramfs/initramfs.img"
UL="$WORK/uniloader/artifacts/uniLoader"
ULO="$WORK/uniloader/artifacts/uniLoader.o"
ULGZ="$WORK/uniloader/artifacts/uniLoader.gz"
KSUM="$WORK/kernel-build/build-summary.txt"
ISUM="$WORK/initramfs/initramfs-summary.txt"
USUM="$WORK/uniloader/reports/build-a.txt"

for f in "$IMAGE" "$DTB" "$INITRAMFS" "$UL" "$ULO" "$ULGZ" "$KSUM" "$ISUM" "$USUM"; do
    [ -f "$f" ] || fail 3 "artefact/rapport absent : ${f#"$WORK/"}"
    [ ! -L "$f" ] || fail 3 "artefact est un symlink : ${f#"$WORK/"}"
done

hash_of() { sha256sum "$1" | awk '{print $1}'; }
size_of() { stat -c '%s' "$1"; }
expect() {
    local label=$1 file=$2 expected=$3 actual
    actual=$(hash_of "$file")
    [ "$actual" = "$expected" ] ||
        fail 4 "$label : hash $actual != rapport $expected"
    printf 'artifact=%s path=%s size=%s sha256=%s\n' \
        "$label" "${file#"$WORK/"}" "$(size_of "$file")" "$actual" >>"$TMP/artifacts.txt"
}

KERNEL_SHA=$(sed -n 's/^image_sha256=//p' "$KSUM")
DTB_SHA=$(sed -n 's/^dtb_sha256=//p' "$KSUM")
KERNEL_REL=$(sed -n 's/^built_release=//p' "$KSUM")
KERNEL_COMMIT=$(sed -n 's/^kernel_commit=//p' "$KSUM")
INIT_SHA=$(sed -n 's/^build_a_sha256=//p' "$ISUM")
UL_SHA=$(sed -n 's/^uniLoader_sha256=//p' "$USUM")
ULO_SHA=$(sed -n 's/^uniLoader_o_sha256=//p' "$USUM")
ULGZ_SHA=$(sed -n 's/^uniLoader_gz_sha256=//p' "$USUM")
UL_COMMIT=$(sed -n 's/^commit=//p' "$USUM")
for v in KERNEL_SHA DTB_SHA KERNEL_REL KERNEL_COMMIT INIT_SHA UL_SHA ULO_SHA ULGZ_SHA UL_COMMIT; do
    [ -n "${!v}" ] || fail 4 "valeur $v absente du rapport"
done

expect kernel.Image "$IMAGE" "$KERNEL_SHA"
expect kernel.dtb "$DTB" "$DTB_SHA"
expect initramfs "$INITRAMFS" "$INIT_SHA"
expect uniloader.raw "$UL" "$UL_SHA"
expect uniloader.elf "$ULO" "$ULO_SHA"
expect uniloader.gzip "$ULGZ" "$ULGZ_SHA"

# Formats et architectures.
IMAGE_TYPE=$(file -b "$IMAGE")
case "$IMAGE_TYPE" in *"Linux kernel ARM64 boot executable Image"*) ;; *) fail 4 "Image n'est pas un noyau ARM64 Image" ;; esac
[ "$(od -An -tx1 -N4 "$DTB" | tr -d ' \n')" = "d00dfeed" ] ||
    fail 4 "DTB magic invalide"
gzip -t "$INITRAMFS" || fail 4 "initramfs gzip invalide"
gzip -dc "$INITRAMFS" >"$TMP/initramfs.cpio" || fail 4 "decompression initramfs impossible"
[ "$(head -c 6 "$TMP/initramfs.cpio")" = "070701" ] ||
    fail 4 "initramfs n'est pas un cpio newc"
UL_TYPE=$(file -b "$UL")
case "$UL_TYPE" in *"Linux kernel ARM64 boot executable Image"*) ;; *) fail 4 "uniLoader brut n'est pas une Image ARM64" ;; esac
ULO_TYPE=$(file -b "$ULO")
case "$ULO_TYPE" in *"ELF 64-bit"*"ARM aarch64"*) ;; *) fail 4 "uniLoader.o n'est pas ELF AArch64" ;; esac
gzip -t "$ULGZ" || fail 4 "uniLoader.gz invalide"
gzip -dc "$ULGZ" 2>/dev/null | cmp -s - "$UL" ||
    fail 4 "uniLoader.gz ne correspond pas a uniLoader"

[ "$KERNEL_REL" = "6.18.0-rc1-a71+" ] || fail 4 "release noyau inattendue : $KERNEL_REL"
[ "$(sed -n 's/^module_count=//p' "$KSUM")" = "607" ] ||
    fail 4 "module_count != 607"
[ "$(sed -n 's/^overall_reproducible=//p' "$WORK/kernel-build/reports/reproducibility.txt")" = "yes" ] ||
    fail 4 "reproductibilite noyau non verifiee"
[ "$(sed -n 's/^overall_reproducible=//p' "$WORK/initramfs/reproducibility.txt")" = "yes" ] ||
    fail 4 "reproductibilite initramfs non verifiee"
[ "$(sed -n 's/^overall_reproducible=//p' "$WORK/uniloader/reports/reproducibility.txt")" = "yes" ] ||
    fail 4 "reproductibilite uniLoader non verifiee"

CANDIDATE_COUNT=0
if [ -d "$WORK/boot/candidate" ]; then
    CANDIDATE_COUNT=$(find "$WORK/boot/candidate" -maxdepth 1 -name '*.img' | wc -l | tr -d ' ')
fi

{
    printf 'result=OK\n'
    printf 'kernel_commit=%s\n' "$KERNEL_COMMIT"
    printf 'kernel_release=%s\n' "$KERNEL_REL"
    printf 'uniloader_commit=%s\n' "$UL_COMMIT"
    printf 'module_count=607\n'
    printf 'architecture=aarch64\n'
    printf 'kernel_reproducible=yes\n'
    printf 'initramfs_reproducible=yes\n'
    printf 'uniloader_reproducible=yes\n'
    printf 'validated_boot_image_present=no\n'
    printf 'candidate_boot_images=%s\n' "$CANDIDATE_COUNT"
    printf 'input_hashes_unchanged=yes\n'
    cat "$TMP/artifacts.txt"
} >"$TMP/boot-artifacts.txt"

python3 - "$TMP/boot-artifacts.txt" "$TMP/provenance.json" <<'PY' || fail 5 "JSON impossible"
import json, sys
text = open(sys.argv[1], encoding="utf-8").read().splitlines()
values = {}
artifacts = []
for line in text:
    if line.startswith("artifact="):
        fields = dict(item.split("=", 1) for item in line.split())
        artifacts.append(fields)
    elif "=" in line:
        key, val = line.split("=", 1)
        values[key] = val
values["artifacts"] = artifacts
values["path_policy"] = "relative_to_work"
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(values, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

cp "$TMP/boot-artifacts.txt" "$OUT/boot-artifacts.txt" || fail 5 "rapport impossible"
cp "$TMP/provenance.json" "$OUT/provenance.json" || fail 5 "rapport impossible"
say "artefacts verifies ; rapports dans ${OUT#"$WORK/"}"
exit 0
