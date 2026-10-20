#!/usr/bin/env bash
# Quick iteration helper: build a uniLoader boot image that the Samsung
# bootloader accepts (LineageOS dtb in the boot.img header) but which boots
# the mainline kernel with its own A71 device tree and a mini initramfs.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ "$ROOT" == *" "* ]]; then
    exec unshare -rm bash -c 'mount --bind "$1" /mnt && exec bash /mnt/scripts/build-test-uni.sh' _ "$ROOT"
fi
TC="$ROOT/toolchain/aarch64--glibc--stable-2024.05-1/bin/aarch64-buildroot-linux-gnu-"
U="$ROOT/build/uniloader2"

[ -f "$ROOT/build/lin.dtb" ] || { echo "missing build/lin.dtb"; exit 1; }
[ -f "$ROOT/build/mini2.cpio.gz" ] || { echo "missing build/mini2.cpio.gz"; exit 1; }

rm -rf "$U"
cp -a "$ROOT/src/uniLoader" "$U"
cp "$ROOT/out/Image" "$U/blob/Image"
cp "$ROOT/out/dtb" "$U/blob/dtb"
cp "$ROOT/build/mini2.cpio.gz" "$U/blob/ramdisk"
cd "$U"
make -s ARCH=aarch64 CROSS_COMPILE="$TC" a71_defconfig
make -s -j"$(nproc)" ARCH=aarch64 CROSS_COMPILE="$TC"
cd "$ROOT"
python3 scripts/mkbootimg.py --kernel "$U/uniLoader" \
    --ramdisk build/empty.cpio.gz --dtb build/lin.dtb \
    --output build/boot-test.img \
    --cmdline "console=tty0 console=ttyMSM0,115200n8 loglevel=7"
python3 - "$ROOT/build/boot-test.img" <<'EOF'
import sys
p=sys.argv[1]; d=open(p,'rb').read(); size=64*1024*1024
open(p,'wb').write(d + b'\0'*max(0,size-len(d)))
print('padded to 64MiB:', p, len(d))
EOF
ls -lh "$ROOT/build/boot-test.img"
