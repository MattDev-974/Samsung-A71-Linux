#!/bin/sh
# Audit hors appareil des firmwares WCN3990 du rootfs du depot.
# Aucun acces telephone, aucun module charge, aucun scan.
set -eu
ROOT=rootfs
usage() { echo "usage: $0 [--root DIR] [--help]"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --root) [ $# -ge 2 ] || { usage; exit 2; }; ROOT=$2; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac; shift
done
D="$ROOT/lib/firmware/ath10k/WCN3990/hw1.0"
fail() { echo "audit-wifi-firmware: $*" >&2; exit 4; }
[ -d "$D" ] || fail "repertoire WCN3990 absent"
for d in "$ROOT/lib/firmware" "$ROOT/lib/firmware/ath10k" "$ROOT/lib/firmware/ath10k/WCN3990" "$D"; do
    [ -d "$d" ] && [ ! -L "$d" ] || fail "repertoire invalide: $d"
    [ "$(stat -c '%a' "$d")" = 755 ] || fail "mode repertoire != 0755: $d"
done
check() {
    name=$1; size=$2; hash=$3
    f="$D/$name"
    [ -f "$f" ] && [ ! -L "$f" ] || fail "fichier absent/symlink: $f"
    [ "$(stat -c '%s' "$f")" = "$size" ] || fail "taille incorrecte: $name"
    [ "$(stat -c '%a' "$f")" = 644 ] || fail "mode != 0644: $name"
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$hash" ] || fail "sha256 incorrect: $name"
}
check board-2.bin 893528 c49d2f1894de6edc0ab0c8c9a17ca0328703747c49b6e9428f1de501c2c02c1d
check firmware-5.bin 60 fef6539e0127579536bc977be57a90d018b83f2931fedc3a8870fbe38d6c4127
check wlanmdsp.mbn 3725044 92e1501254e6de78c0f2e2cf091507d488b608d07e53acd14813a82744823ec2
check notice.txt_wlanmdsp 27005 d7a42cb726d992c427fc130b60b076c5536297aafceecdb053b1b5de17f7d5fa
echo "wifi_firmware_audit=ok files=4 root=$ROOT"
