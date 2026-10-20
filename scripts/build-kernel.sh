#!/usr/bin/env bash
# Cross-compile the mainline kernel (WiiPlayer2/linux-sm7150, branch
# device/samsung-a71) for the Galaxy A71 and copy Image + DTB to out/.
#
# The kernel build system passes CROSS_COMPILE / source paths through
# unquoted shells, so paths must not contain spaces.  This workspace path does
# contain a space, therefore the script re-executes itself inside a private
# mount namespace where the workspace is also reachable as /mnt.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [[ "$ROOT" == *" "* ]]; then
    exec unshare -rm bash -c 'mount --bind "$1" /mnt && exec bash /mnt/scripts/build-kernel.sh' _ "$ROOT"
fi

BUILD="$ROOT/build"
KSRC="$ROOT/src/kernel"
KOUT="$BUILD/kernel-out"
TC="$ROOT/toolchain/aarch64--glibc--stable-2024.05-1/bin/aarch64-buildroot-linux-gnu-"

mkdir -p "$BUILD" "$ROOT/out"

# The kernel's timeconst generation needs `bc`, which is not installed
# everywhere.  Use a prebuilt binary unpacked under build/tools (x86_64 host).
if ! command -v bc >/dev/null 2>&1 && [ ! -x "$ROOT/build/tools/bcroot/usr/bin/bc" ]; then
    echo ">> fetching bc (kernel build dependency)"
    mkdir -p "$ROOT/build/tools/bcroot"
    tmp="$ROOT/build/tools/bc.pkg.tar.zst"
    curl -sSL -o "$tmp" \
        https://archive.archlinux.org/packages/b/bc/bc-1.08.2-1-x86_64.pkg.tar.zst
    tar --zstd -xf "$tmp" -C "$ROOT/build/tools/bcroot"
fi

cd "$KSRC"
export ARCH=arm64 CROSS_COMPILE="$TC"
command -v bc >/dev/null 2>&1 || export PATH="$ROOT/build/tools/bcroot/usr/bin:$PATH"

# Base config: the postmarketOS SM7150 mainline config (known to boot on this
# SoC), then our small extra fragment.
PMOS_CONFIG="$ROOT/src/pmaports/device/testing/linux-postmarketos-qcom-sm7150/config-postmarketos-qcom-sm7150.aarch64"
echo ">> postmarketOS sm7150 config + a71 extras"
mkdir -p "$KOUT"
cp "$PMOS_CONFIG" "$KOUT/.config"
scripts/kconfig/merge_config.sh -m -O "$KOUT" "$KOUT/.config" \
    "$ROOT/configs/a71-extra.config" >/dev/null
make -s O="$KOUT" olddefconfig

echo ">> building Image + dtbs (-j$(nproc))"
make -j"$(nproc)" O="$KOUT" Image qcom/sm7150-samsung-a715f.dtb

# Optional: build the module set too (needed for Wi-Fi/ath10k, panel, etc.).
if [ "${A71_MODULES:-0}" = "1" ]; then
    echo ">> building modules"
    make -j"$(nproc)" O="$KOUT" modules
    rm -rf "$ROOT/build/modroot"
    make -s O="$KOUT" modules_install \
        INSTALL_MOD_PATH="$ROOT/build/modroot" INSTALL_MOD_STRIP=1
    depmod -b "$ROOT/build/modroot" 2>/dev/null || true
    echo ">> modules installed in build/modroot"
fi

cp "$KOUT/arch/arm64/boot/Image" "$ROOT/out/Image"
cp "$KOUT/arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dtb" "$ROOT/out/dtb"
cp "$KOUT/.config" "$ROOT/out/kernel.config"

# Bake the console/misc kernel command line into the device tree as well: the
# uniLoader path ignores the boot.img cmdline (it uses its own embedded DTB).
export PATH="$KOUT/scripts/dtc:$PATH"
python3 "$ROOT/scripts/dtb-bootargs.py" "$ROOT/out/dtb" \
    "console=tty0 console=ttyMSM0,115200n8 consoleblank=0 loglevel=7"
echo ">> done: out/Image out/dtb"
