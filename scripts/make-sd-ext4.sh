#!/bin/sh
# make-sd-ext4.sh - prepare an SD card as a *direct* ext4 root filesystem
# for the Galaxy A71.
#
# Run on the PC with root:
#
#   sudo ./scripts/make-sd-ext4.sh /dev/sdX rootfs.tar.gz
#
# The whole card becomes one ext4 filesystem: the selector in the initramfs
# detects it and boots straight from it (no loop device, full capacity).
set -e

DEV=${1:?usage: make-sd-ext4.sh <device> <rootfs.tar.gz>}
TAR=${2:?usage: make-sd-ext4.sh <device> <rootfs.tar.gz>}

case "$DEV" in
    /dev/mmcblk*|/dev/sd*) ;;
    *) echo "refusing to touch $DEV" >&2; exit 1 ;;
esac

echo ">> all data on $DEV will be destroyed; Ctrl-C in 5 s..."
sleep 5

umount "${DEV}"* 2>/dev/null || true
wipefs -a "$DEV"
mkfs.ext4 -q -L a71root "$DEV"

MNT=$(mktemp -d)
mount "$DEV" "$MNT"
tar -xzf "$TAR" -C "$MNT"
sync
umount "$MNT"
rmdir "$MNT"
echo ">> done: $DEV is ready (ext4, label a71root)"
