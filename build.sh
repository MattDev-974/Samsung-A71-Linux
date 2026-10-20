#!/usr/bin/env bash
# Build everything for the Galaxy A71 "minimum syndical" Linux image:
#   out/Image, out/dtb, out/initramfs.cpio.gz, out/boot-*.img
#
# Requirements: bash, make, gcc, bison, flex, openssl, cpio, gzip, python3,
# curl, and an unprivileged user namespace (unshare -r works on most distros).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$ROOT/out" "$ROOT/build"

echo "=== 1/3 kernel ==="
"$ROOT/scripts/build-kernel.sh"

echo "=== 2/3 root filesystem ==="
"$ROOT/scripts/build-rootfs.sh"

echo "=== 3/3 boot images ==="
"$ROOT/scripts/build-boot.sh"

echo "=== done ==="
ls -lh "$ROOT/out"
