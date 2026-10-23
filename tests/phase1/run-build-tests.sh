#!/usr/bin/env bash
# shellcheck shell=bash
#
# run-build-tests.sh - non-regression G1 (uniLoader), H2 (ext4), H3 (image SD).
# Aucun build lourd n'est relance : les artefacts sont verifies, et les scripts
# sont testes sur leurs gardes d'entree.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK="$ROOT/../work"
TMP=$(mktemp -d) || { echo "temporaire impossible" >&2; exit 1; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

PASS=0
FAIL=0
check_eq() {
    local desc=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf '  ok    %s\n' "$desc"
    else
        FAIL=$((FAIL + 1)); printf '  ECHEC %s (attendu [%s], obtenu [%s])\n' "$desc" "$expected" "$actual"
    fi
}
section() { printf '\n%s\n' "$*"; }

G1="$WORK/uniloader"
H2="$WORK/sdcard/A71ROOT-usb.ext4"
H3="$WORK/sdcard/a71-sd-usb.img"
SRC="$WORK/uniloader-src"

section "G1 : uniLoader epingle"
if [ -d "$G1" ]; then
    check_eq "uniLoader present" 1 "$([ -s "$G1/artifacts/uniLoader" ] && echo 1 || echo 0)"
    check_eq "format ARM64 Image" 1 "$(file "$G1/artifacts/uniLoader" | grep -c 'Linux kernel ARM64 boot executable Image')"
    check_eq "ELF .o AArch64" 1 "$(file "$G1/artifacts/uniLoader.o" | grep -c 'ELF 64-bit.*ARM aarch64')"
    check_eq "gzip valide" 0 "$(gzip -t "$G1/artifacts/uniLoader.gz" 2>/dev/null; echo $?)"
    check_eq "builds identiques" 0 "$(cmp -s "$G1/build-a/uniLoader" "$G1/build-b/uniLoader"; echo $?)"
    check_eq "aucun boot.img" 0 "$(find "$G1" -name 'boot*.img' | wc -l | tr -d ' ')"
    check_eq "commit epingle" 1 "$(grep -c '^commit=4c626a73cc38308227b5c28e75558b3da574312b$' "$G1/reports/build-a.txt")"
    check_eq "reproductibilite G1" yes "$(awk -F= '/^overall_reproducible=/{print $2}' "$G1/reports/reproducibility.txt")"
    check_eq "provenance json valide" 0 "$(python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$G1/reports/provenance.json" 2>/dev/null; echo $?)"
else
    printf '  (ignore) work/uniloader absent\n'
fi
if [ -d "$SRC" ]; then
    check_eq "mauvais commit -> 3" 3 "$("$ROOT/scripts/build-uniloader.sh" --source "$WORK/uniLoader" --toolchain-root "$WORK/toolchain/toolchain-root" --kernel-image "$WORK/kernel-build/artifacts/Image" --initramfs "$WORK/initramfs/initramfs.img" --output "$TMP/g1-wrong" --jobs 2 >/dev/null 2>&1; echo $?)"
    check_eq "jobs invalide -> 2" 2 "$("$ROOT/scripts/build-uniloader.sh" --source "$SRC" --toolchain-root "$WORK/toolchain/toolchain-root" --kernel-image "$WORK/kernel-build/artifacts/Image" --initramfs "$WORK/initramfs/initramfs.img" --output "$TMP/g1-jobs" --jobs 0 >/dev/null 2>&1; echo $?)"
    check_eq "Image absente -> 3" 3 "$("$ROOT/scripts/build-uniloader.sh" --source "$SRC" --toolchain-root "$WORK/toolchain/toolchain-root" --kernel-image "$TMP/nope" --initramfs "$WORK/initramfs/initramfs.img" --output "$TMP/g1-img" --jobs 2 >/dev/null 2>&1; echo $?)"
    check_eq "mauvaise toolchain -> 3" 3 "$("$ROOT/scripts/build-uniloader.sh" --source "$SRC" --toolchain-root /usr --kernel-image "$WORK/kernel-build/artifacts/Image" --initramfs "$WORK/initramfs/initramfs.img" --output "$TMP/g1-tc" --jobs 2 >/dev/null 2>&1; echo $?)"
    cp -a "$SRC" "$TMP/src-no-defconfig"
    rm -f "$TMP/src-no-defconfig/configs/a71_defconfig"
    check_eq "defconfig absent -> 3" 3 "$("$ROOT/scripts/build-uniloader.sh" --source "$TMP/src-no-defconfig" --toolchain-root "$WORK/toolchain/toolchain-root" --kernel-image "$WORK/kernel-build/artifacts/Image" --initramfs "$WORK/initramfs/initramfs.img" --output "$TMP/g1-def" --jobs 2 >/dev/null 2>&1; echo $?)"
    cp -a "$SRC" "$TMP/src-dirty"
    printf '\n# dirty\n' >>"$TMP/src-dirty/README.md"
    check_eq "source sale -> 3" 3 "$("$ROOT/scripts/build-uniloader.sh" --source "$TMP/src-dirty" --toolchain-root "$WORK/toolchain/toolchain-root" --kernel-image "$WORK/kernel-build/artifacts/Image" --initramfs "$WORK/initramfs/initramfs.img" --output "$TMP/g1-dirty" --jobs 2 >/dev/null 2>&1; echo $?)"
fi

section "H2 : A71ROOT.ext4"
if [ -f "$H2" ]; then
    check_eq "taille 1 Gio" 1073741824 "$(stat -c '%s' "$H2")"
    check_eq "hash conforme" 0 "$(cd "$(dirname "$H2")" && sha256sum -c "$(basename "$H2").sha256" >/dev/null 2>&1; echo $?)"
    check_eq "e2fsck -fn" 0 "$(e2fsck -fn "$H2" >/dev/null 2>&1; echo $?)"
    check_eq "label A71ROOT" 1 "$(dumpe2fs -h "$H2" 2>/dev/null | grep -c '^Filesystem volume name:   A71ROOT$')"
    check_eq "manifeste 2106" 1 "$(grep -c '^entries=2106$' "$H2.manifest")"
    check_eq "/init symlink image" 1 "$(debugfs -R 'stat /init' "$H2" 2>/dev/null | grep -c 'Fast link dest: "/sbin/init"')"
    check_eq "/sbin/init present image" 1 "$(debugfs -R 'stat /sbin/init' "$H2" 2>/dev/null | grep -c 'Inode:')"
    check_eq "a71-usb 0755 image" 1 "$(debugfs -R 'stat /etc/init.d/a71-usb' "$H2" 2>/dev/null | grep -c 'Mode:  0755')"
    check_eq "a71-net link image" 1 "$(debugfs -R 'stat /etc/runlevels/default/a71-net' "$H2" 2>/dev/null | grep -c 'Fast link dest: "/etc/init.d/a71-net"')"
    check_eq "bbsuid 04111" 1 "$(debugfs -R 'stat /bin/bbsuid' "$H2" 2>/dev/null | grep -c 'Mode:  04111')"
    check_eq "busybox 0755" 1 "$(debugfs -R 'stat /bin/busybox' "$H2" 2>/dev/null | grep -c 'Mode:  0755')"
    check_eq "reproductibilite logique" yes "$(awk -F= '/^logical_match=/{print $2}' "$WORK/sdcard/reports-usb/ext4-reproducibility.txt")"
else
    printf '  (ignore) A71ROOT.ext4 absent\n'
fi
check_eq "taille trop petite -> 3" 3 "$("$ROOT/scripts/build-rootfs-image.sh" --rootfs "$WORK/rootfs/rootfs-functional-usb-c" --ownership-manifest "$WORK/rootfs/rootfs-functional-usb-c/reports/ownership-manifest.txt" --output "$TMP/h2-small.ext4" --source-date-epoch 1760369959 --size 1048576 >/dev/null 2>&1; echo $?)"
check_eq "manifeste absent -> 3" 3 "$("$ROOT/scripts/build-rootfs-image.sh" --rootfs "$WORK/rootfs/rootfs-functional-init-a" --ownership-manifest "$TMP/nope" --output "$TMP/h2-noman.ext4" --source-date-epoch 1760369959 >/dev/null 2>&1; echo $?)"

section "H3 : a71-sd.img"
if [ -f "$H3" ]; then
    check_eq "taille 1 074 790 400" 1074790400 "$(stat -c '%s' "$H3")"
    check_eq "hash conforme" 0 "$(cd "$(dirname "$H3")" && sha256sum -c "$(basename "$H3").sha256" >/dev/null 2>&1; echo $?)"
    check_eq "une partition" 1 "$(sfdisk -d "$H3" 2>/dev/null | grep -c ' : start=')"
    check_eq "partition 2048/2097152/83" 1 "$(sfdisk -d "$H3" 2>/dev/null | grep -c 'start= *2048, size= *2097152, type=83')"
    PART="$TMP/h3-part.ext4"
    dd if="$H3" of="$PART" bs=512 skip=2048 count=2097152 status=none
    check_eq "/init symlink extrait" 1 "$(debugfs -R 'stat /init' "$PART" 2>/dev/null | grep -c 'Fast link dest: "/sbin/init"')"
    check_eq "/sbin/init extrait" 1 "$(debugfs -R 'stat /sbin/init' "$PART" 2>/dev/null | grep -c 'Inode:')"
    check_eq "a71-usb extrait" 1 "$(debugfs -R 'stat /etc/init.d/a71-usb' "$PART" 2>/dev/null | grep -c 'Mode:  0755')"
    check_eq "paquets extraits 100" 100 "$(debugfs -R 'cat /lib/apk/db/installed' "$PART" 2>/dev/null | grep -c '^P:')"
    check_eq "image < 30.9 Go" 1 "$([ "$(stat -c '%s' "$H3")" -lt 30979129344 ] && echo 1 || echo 0)"
    check_eq "reproductibilite binaire H3" yes "$(awk -F= '/^binary_match=/{print $2}' "$WORK/sdcard/reports-usb/image-reproducibility.txt")"
else
    printf '  (ignore) a71-sd.img absent\n'
fi
check_eq "image rootfs absente -> 3" 3 "$("$ROOT/scripts/build-sd-image.sh" --rootfs-image "$TMP/nope.ext4" --output "$TMP/no.img" >/dev/null 2>&1; echo $?)"

section "L : rapports et anciennes images"
check_eq "rapports init sans chemin prive" 0 "$(grep -RIl --binary-files=without-match '/home/mattheo\|/Users/' "$WORK/sdcard/reports-init" "$WORK/rootfs/rootfs-functional-init-a/reports" 2>/dev/null | wc -l | tr -d ' ')"
check_eq "ancienne ext4 inchangee" 3b60a7cb14aaacf4782330b46995c273d0f7505490d8fd04f8d464525e3fbd2e "$(sha256sum "$WORK/sdcard/A71ROOT.ext4" | awk '{print $1}')"
check_eq "ancienne image SD inchangee" 2a42768f5d81046bb96da5d0ad3447a1ddc77ef258207314d55e7a7631aeef9d "$(sha256sum "$WORK/sdcard/a71-sd.img" | awk '{print $1}')"

printf '\n%s\n' "---------------------------------------------"
printf 'Resultat build G1/H2/H3 : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
