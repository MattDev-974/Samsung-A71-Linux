#!/bin/sh
# usb-gadget.sh - expose the phone as a USB network card (RNDIS + CDC-ECM).
#
# The host operating system gets a new Ethernet interface; the phone answers
# DHCP on 172.16.42.0/24 (RNDIS interface) and 172.16.43.0/24 (ECM interface)
# and runs sshd, so `ssh root@172.16.42.1` works on Linux, macOS and Windows.
set -e

CFS=/sys/kernel/config
G=$CFS/usb_gadget/a71

start() {
    modprobe libcomposite 2>/dev/null || true
    if [ ! -d "$CFS/usb_gadget" ]; then
        mount -t configfs none "$CFS" 2>/dev/null || true
    fi
    [ -d "$CFS/usb_gadget" ] || { echo "configfs/usb_gadget unavailable"; return 1; }

    if [ ! -d "$G" ]; then
        mkdir -p "$G"
        echo 0x1d6b > "$G/idVendor"
        echo 0x0104 > "$G/idProduct"
        echo 0x0100 > "$G/bcdDevice"
        echo 0x0200 > "$G/bcdUSB"
        echo 0xef > "$G/bDeviceClass"
        echo 0x02 > "$G/bDeviceSubClass"
        echo 0x01 > "$G/bDeviceProtocol"

        mkdir -p "$G/strings/0x409"
        echo "Nura" > "$G/strings/0x409/manufacturer"
        echo "Galaxy A71" > "$G/strings/0x409/product"
        echo "a71-0001" > "$G/strings/0x409/serialnumber"

        mkdir -p "$G/configs/c.1/strings/0x409"
        echo "RNDIS + ECM" > "$G/configs/c.1/strings/0x409/configuration"
        echo 250 > "$G/configs/c.1/MaxPower"

        mkdir -p "$G/functions/rndis.usb0"
        echo "02:1a:71:00:00:01" > "$G/functions/rndis.usb0/dev_addr"
        mkdir -p "$G/functions/ecm.usb0"
        echo "02:1a:71:00:00:02" > "$G/functions/ecm.usb0/dev_addr"
        echo "02:1a:71:00:00:03" > "$G/functions/ecm.usb0/host_addr"

        ln -sf "$G/functions/rndis.usb0" "$G/configs/c.1/rndis.usb0"
        ln -sf "$G/functions/ecm.usb0" "$G/configs/c.1/ecm.usb0"
    fi

    udc=""
    for u in /sys/class/udc/*; do
        [ -e "$u" ] && udc=$(basename "$u") && break
    done
    if [ -z "$udc" ]; then
        echo "no UDC found (USB controller missing?)"
        return 1
    fi
    if [ "$(cat "$G/UDC" 2>/dev/null)" != "$udc" ]; then
        echo "$udc" > "$G/UDC"
    fi
    echo "usb gadget bound to $udc"
}

stop() {
    [ -d "$G" ] || return 0
    echo "" > "$G/UDC" 2>/dev/null || true
    echo "usb gadget stopped"
}

case "$1" in
    start) start ;;
    stop) stop ;;
    *) echo "usage: $0 start|stop" ;;
esac
