#!/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /mnt/sd

ok=0
i=0
while [ $i -lt 60 ]; do
    for d in /dev/mmcblk1p1 /dev/mmcblk1 /dev/mmcblk0p1 /dev/mmcblk0 /dev/mmcblk2p1 /dev/mmcblk2 /dev/sda1 /dev/sda; do
        [ -b "$d" ] || continue
        mount "$d" /mnt/sd 2>/dev/null || \
        mount -t vfat "$d" /mnt/sd 2>/dev/null || \
        mount -t ext4 "$d" /mnt/sd 2>/dev/null || continue
        if echo "a71 probe" > /mnt/sd/a71-test.txt 2>/dev/null; then
            ok=1
            echo "mounted $d" > /dev/kmsg
            break
        fi
        umount /mnt/sd 2>/dev/null
    done
    [ $ok = 1 ] && break
    i=$((i + 1))
    sleep 1
done

if [ $ok = 1 ]; then
    {
        echo "== devices =="
        ls -l /dev/mmcblk* 2>/dev/null
        echo "== udc =="
        ls /sys/class/udc 2>/dev/null
        echo "== fb =="
        cat /sys/class/graphics/fb0/virtual_size 2>/dev/null
        cat /sys/class/graphics/fb0/stride 2>/dev/null
        echo "=== dmesg ==="
        dmesg
    } > /mnt/sd/a71-dmesg.txt 2>/dev/null
    for f in /sys/fs/pstore/*; do
        [ -f "$f" ] && cat "$f" > "/mnt/sd/$(basename $f)" 2>/dev/null
    done
    sync
    echo "SD OK" > /dev/kmsg
    sleep 3600
fi
# no card: reboot so the failure is unmistakable
echo "SD FAIL" > /dev/kmsg
sync
reboot -f
