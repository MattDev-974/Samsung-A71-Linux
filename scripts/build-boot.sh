#!/usr/bin/env bash
# Assemble the flashable images:
#   out/uniLoader.img        raw uniLoader binary (kernel + dtb + initramfs)
#   out/boot-uniloader.img   AOSP boot image v2 whose kernel is uniLoader
#   out/boot-direct.img      AOSP boot image v2 with Image + initramfs + dtb
#   out/initramfs.cpio.gz    the root filesystem (already built)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [[ "$ROOT" == *" "* ]]; then
    exec unshare -rm bash -c 'mount --bind "$1" /mnt && exec bash /mnt/scripts/build-boot.sh' _ "$ROOT"
fi

TC="$ROOT/toolchain/aarch64--glibc--stable-2024.05-1/bin/aarch64-buildroot-linux-gnu-"
U="$ROOT/build/uniloader"

for f in out/Image out/dtb out/initramfs.cpio.gz; do
    [ -f "$ROOT/$f" ] || { echo "missing $f - run the earlier build steps" >&2; exit 1; }
done

echo ">> building uniLoader (a71_defconfig)"
rm -rf "$U"
cp -a "$ROOT/src/uniLoader" "$U"
cp "$ROOT/out/Image" "$U/blob/Image"
cp "$ROOT/out/dtb" "$U/blob/dtb"
cp "$ROOT/out/initramfs.cpio.gz" "$U/blob/ramdisk"

cd "$U"
make -s ARCH=aarch64 CROSS_COMPILE="$TC" a71_defconfig
make -s -j"$(nproc)" ARCH=aarch64 CROSS_COMPILE="$TC"
cp "$U/uniLoader" "$ROOT/out/uniLoader.img"

# minimal valid (empty) cpio.gz for the boot.img ramdisk slot
mkdir -p "$ROOT/build/empty"
( cd "$ROOT/build/empty" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) \
    > "$ROOT/build/empty.cpio.gz"

echo ">> creating boot images"
python3 "$ROOT/scripts/mkbootimg.py" \
    --kernel "$ROOT/out/uniLoader.img" \
    --ramdisk "$ROOT/build/empty.cpio.gz" \
    --dtb "$ROOT/out/dtb" \
    --output "$ROOT/out/boot-uniloader.img" \
    --seandroid

python3 "$ROOT/scripts/mkbootimg.py" \
    --kernel "$ROOT/out/Image" \
    --ramdisk "$ROOT/out/initramfs.cpio.gz" \
    --dtb "$ROOT/out/dtb" \
    --output "$ROOT/out/boot-direct.img" \
    --seandroid

( cd "$ROOT/out" && sha256sum Image dtb initramfs.cpio.gz uniLoader.img \
    boot-uniloader.img boot-direct.img > SHA256SUMS )
ls -lh "$ROOT"/out
