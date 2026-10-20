#!/usr/bin/env bash
# Flash a built image to the Galaxy A71 with heimdall.
#
#   ./scripts/flash.sh out/boot-uniloader.img
#
# The bootloader must be unlocked ("OEM unlocking" enabled in developer
# options, device wiped once).  Put the phone in Download Mode first:
# power it off, then hold Volume Up + Volume Down and plug the USB cable.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=${1:-$ROOT/out/boot-uniloader.img}

[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }

if ! command -v heimdall >/dev/null; then
    cat >&2 <<'EOF'
heimdall is not installed.  On Arch:   sudo pacman -S heimdall
                             Debian:   sudo apt install heimdall-flash
EOF
    exit 1
fi

echo ">> device detection"
heimdall detect || {
    echo "no device in Download Mode (Vol Up + Vol Down + USB cable)" >&2
    exit 1
}

echo ">> partitions (look for BOOT)"
heimdall print-pit --no-reboot 2>/dev/null | grep -iE 'Partition Name|BOOT' | head -20 || true

echo
echo "About to flash: $IMG"
echo "This replaces the boot partition.  Keep a stock firmware around:"
echo "  samloader / samfirm can download A715FXXU... firmware if you need to restore."
read -r -p "Continue? [y/N] " ans
[ "$ans" = y ] || [ "$ans" = Y ] || exit 1

heimdall flash --BOOT "$IMG" --no-reboot
echo ">> flashed. Unplug, then hold Power ~10 s to boot."
