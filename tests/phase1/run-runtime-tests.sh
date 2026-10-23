#!/usr/bin/env bash
# shellcheck shell=bash
#
# run-runtime-tests.sh - K4/K8, fixtures synthetiques uniquement.
# Aucun telephone, aucun peripherique bloc, aucun montage, aucun sudo.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK="$ROOT/../work"
TMP=$(mktemp -d) || { echo "temporaire impossible" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM
CHECK="$ROOT/scripts/check-runtime-contract.sh"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ECHEC %s (%s)\n' "$1" "$2"; }
has() { grep -q "^result_[0-9]*=$2$" "$1" && ok "$3" || bad "$3" "absent $2"; }
hasnot() { grep -q "^result_[0-9]*=$2$" "$1" && bad "$3" "present $2" || ok "$3"; }
field() { grep -q "^$2$" "$1" && ok "$3" || bad "$3" "champ $2 absent"; }

make_initramfs() {
    local d=$1 mode=$2
    mkdir -p "$d"
    : >"$d/init"
    if [ "$mode" = yes ]; then
        cat >"$d/init" <<'EOF'
#!/bin/sh
mode=$(cat /mnt/sd/a71.mode 2>/dev/null)
exec switch_root /newroot /init
exec /sbin/a71-system
EOF
    fi
}

make_base() {
    local d=$1 complete=$2
    mkdir -p "$d/sbin" "$d/usr/local/sbin" "$d/etc/init.d"
    if [ "$complete" = yes ]; then
        cat >"$d/sbin/a71-system" <<'EOF'
#!/bin/sh
/usr/sbin/sshd -e
ip addr add 172.16.42.1/24 dev usb0
ip addr add 172.16.43.1/24 dev usb1
EOF
        printf '#!/bin/sh\n# rndis ecm\n' >"$d/usr/local/sbin/usb-gadget.sh"
        printf '#!/bin/sh\n# dnsmasq\ndhcp-range=usb0,172.16.42.100,172.16.42.150\n' >"$d/etc/init.d/a71-net"
    else
        printf '#!/bin/sh\n' >"$d/sbin/a71-system"
        printf '#!/bin/sh\n' >"$d/usr/local/sbin/usb-gadget.sh"
        printf '#!/bin/sh\n' >"$d/etc/init.d/a71-net"
    fi
    chmod 755 "$d/sbin/a71-system" "$d/usr/local/sbin/usb-gadget.sh" "$d/etc/init.d/a71-net"
}

make_rootfs() {
    local d=$1 mode=$2
    mkdir -p "$d/etc/ssh" "$d/root/.ssh" "$d/etc/init.d" \
        "$d/lib/modules/6.18.0-rc1-a71+" "$d/etc/local.d" "$d/bin" "$d/usr/sbin" "$d/etc/runlevels/default"
    if [ "$mode" = good ]; then
        printf '#!/bin/sh\nexec /sbin/init\n' >"$d/init"
        chmod 755 "$d/init"
        printf 'PermitRootLogin yes\n' >"$d/etc/ssh/sshd_config"
        printf 'ssh-ed25519 AAAA test\n' >"$d/root/.ssh/authorized_keys"
        printf '#!/bin/sh\n# dnsmasq\ndhcp-range=usb0,172.16.42.100,172.16.42.150\n' >"$d/etc/init.d/a71-net"
        chmod 755 "$d/etc/init.d/a71-net"
        printf '#!/bin/sh\n# firstboot\n' >"$d/etc/local.d/firstboot.start"
        chmod 755 "$d/etc/local.d/firstboot.start"
        printf '#!/bin/sh\n' >"$d/bin/busybox"; chmod 755 "$d/bin/busybox"
        printf '#!/bin/sh\n' >"$d/usr/sbin/sshd"; chmod 755 "$d/usr/sbin/sshd"
        ln -sf /bin/busybox "$d/sbin/init"
        ln -sf /etc/init.d/sshd "$d/etc/runlevels/default/sshd"
    else
        printf 'PermitRootLogin no\n' >"$d/etc/ssh/sshd_config"
    fi
}

make_card() {
    local image=$1 label=$2
    local empty="$TMP/empty-$$"
    mkdir -p "$empty"
    mke2fs -q -t ext4 -L "$label" -d "$empty" "$image" 8M 2>/dev/null
}

# Fixtures de base.
make_initramfs "$TMP/ir-good" yes
make_initramfs "$TMP/ir-bad" no
make_base "$TMP/base-good" yes
make_base "$TMP/base-bad" no
make_rootfs "$TMP/root-good" good
make_rootfs "$TMP/root-bad" bad
mkdir -p "$TMP/hist-clean" "$TMP/hist-key/etc/ssh"
printf 'dummy' >"$TMP/hist-key/etc/ssh/ssh_host_ed25519_key"
mkdir -p "$TMP/card-stage/sbin"
printf '#!/bin/sh\n' >"$TMP/card-stage/sbin/init"
chmod 755 "$TMP/card-stage/sbin/init"
ln -s /sbin/init "$TMP/card-stage/init"
mke2fs -q -t ext4 -L A71ROOT -d "$TMP/card-stage" "$TMP/card-good.img" 8M 2>/dev/null
make_card "$TMP/card-other.img" OTHER

run() {
    local out=$1 root=$2 ir=$3 base=$4 card=$5 hist=$6 extra=${7:-}
    mkdir -p "$out"
    # shellcheck disable=SC2086
    "$CHECK" --rootfs "$root" --initramfs "$ir" --base "$base" \
        --card "$card" --historical "$hist" --reports "$out" $extra >/dev/null 2>&1
}

echo "K4 : contrat runtime (état réel)"
run "$TMP/rep-real" "$WORK/rootfs/rootfs-functional-init-a" "$ROOT/initramfs" "$ROOT/base" \
    "$WORK/sdcard/A71ROOT-init.ext4" "$WORK/compat/ir-ipv6"
R="$TMP/rep-real/runtime-contract.txt"
has "$R" READY_FOR_RAM_MODE_TEST "mode RAM prêt"
has "$R" READY_FOR_SD_MODE_TEST "mode SD prêt après correction /init"
has "$R" USB_NETWORK_INCOMPLETE "réseau USB cible incomplet"
has "$R" SSH_INCOMPLETE "SSH cible incomplet"
has "$R" SECRET_FOUND "clés hôte historiques signalées"

echo "K8 : fixtures synthétiques"
run "$TMP/rep-good" "$TMP/root-good" "$TMP/ir-good" "$TMP/base-good" \
    "$TMP/card-good.img" "$TMP/hist-clean"
R="$TMP/rep-good/runtime-contract.txt"
has "$R" READY_FOR_RAM_MODE_TEST "fixture RAM prête"
has "$R" READY_FOR_SD_MODE_TEST "fixture SD prête"
hasnot "$R" ROOT_IDENTIFIER_MISMATCH "fixture SD sans mismatch"
field "$R" "card_label=A71ROOT" "label A71ROOT"
field "$R" "usb_historical=complete" "USB historique complet"
field "$R" "ssh_target=complete" "SSH cible complet"
field "$R" "modules_release=6.18.0-rc1-a71+" "release modules"

run "$TMP/rep-bad" "$TMP/root-bad" "$TMP/ir-good" "$TMP/base-good" \
    "$TMP/card-good.img" "$TMP/hist-clean"
R="$TMP/rep-bad/runtime-contract.txt"
has "$R" ROOT_IDENTIFIER_MISMATCH "rootfs sans /init"
has "$R" USB_NETWORK_INCOMPLETE "rootfs sans réseau"
has "$R" SSH_INCOMPLETE "rootfs sans SSH"
has "$R" NEEDS_MANUAL_EVIDENCE "modules absents"
hasnot "$R" READY_FOR_SD_MODE_TEST "pas de SD prêt"

run "$TMP/rep-card" "$TMP/root-good" "$TMP/ir-good" "$TMP/base-good" \
    "$TMP/card-other.img" "$TMP/hist-clean"
has "$TMP/rep-card/runtime-contract.txt" ROOT_IDENTIFIER_MISMATCH "mauvais label carte"

run "$TMP/rep-secret" "$TMP/root-good" "$TMP/ir-good" "$TMP/base-good" \
    "$TMP/card-good.img" "$TMP/hist-key"
has "$TMP/rep-secret/runtime-contract.txt" SECRET_FOUND "clé hôte historique"

mkdir -p "$TMP/root-hostkey/etc/ssh" "$TMP/root-hostkey/lib/modules/6.18.0-rc1-a71+"
cp -a "$TMP/root-good/." "$TMP/root-hostkey/"
printf 'dummy' >"$TMP/root-hostkey/etc/ssh/ssh_host_ed25519_key"
run "$TMP/rep-targetsecret" "$TMP/root-hostkey" "$TMP/ir-good" "$TMP/base-good" \
    "$TMP/card-good.img" "$TMP/hist-clean"
has "$TMP/rep-targetsecret/runtime-contract.txt" SECRET_FOUND "clé hôte dans la cible"

run "$TMP/rep-modes" "$TMP/root-good" "$TMP/ir-bad" "$TMP/base-good" \
    "$TMP/card-good.img" "$TMP/hist-clean"
has "$TMP/rep-modes/runtime-contract.txt" NEEDS_MANUAL_EVIDENCE "sélecteur incomplet"

run "$TMP/rep-basebad" "$TMP/root-good" "$TMP/ir-good" "$TMP/base-bad" \
    "$TMP/card-good.img" "$TMP/hist-clean"
field "$TMP/rep-basebad/runtime-contract.txt" "usb_historical=incomplete" "USB historique incomplet"
cp -a "$TMP/base-good" "$TMP/base-rndis"
sed -i 's/172\.16\.43\.1/172.16.99.1/' "$TMP/base-rndis/sbin/a71-system"
run "$TMP/rep-rndis" "$TMP/root-good" "$TMP/ir-good" "$TMP/base-rndis" \
    "$TMP/card-good.img" "$TMP/hist-clean"
field "$TMP/rep-rndis/runtime-contract.txt" "usb_historical=incomplete" "RNDIS sans ECM incomplet"
field "$TMP/rep-good/runtime-contract.txt" "usb_addressing=dhcp" "adressage DHCP"
cp -a "$TMP/base-good" "$TMP/base-static"
sed -i '/dhcp-range/d' "$TMP/base-static/etc/init.d/a71-net"
run "$TMP/rep-static" "$TMP/root-good" "$TMP/ir-good" "$TMP/base-static" \
    "$TMP/card-good.img" "$TMP/hist-clean"
field "$TMP/rep-static/runtime-contract.txt" "usb_addressing=static_or_unknown" "adressage statique"
mkdir -p "$TMP/root-wrong/lib/modules/6.17.0-test"
cp -a "$TMP/root-good/." "$TMP/root-wrong/"
rm -rf "$TMP/root-wrong/lib/modules/6.18.0-rc1-a71+"
run "$TMP/rep-release" "$TMP/root-wrong" "$TMP/ir-good" "$TMP/base-good" \
    "$TMP/card-good.img" "$TMP/hist-clean"
field "$TMP/rep-release/runtime-contract.txt" "modules_release=absent" "release modules différente"

run "$TMP/rep-dtb" "$TMP/root-good" "$TMP/ir-good" "$TMP/base-good" \
    "$TMP/card-good.img" "$TMP/hist-clean" "--analysis $TMP/absent"
has "$TMP/rep-dtb/runtime-contract.txt" FUNCTIONAL_DTB_PATCH_UNKNOWN "DTB inconnu sans analyse"

printf 'K8 : rapports sans chemins privés et JSON\n'
for r in "$TMP"/rep-*/runtime-contract.txt; do
    if grep -Eq '/home/|/Users/|BEGIN (OPENSSH|RSA|EC) PRIVATE KEY' "$r"; then
        bad "rapport sans secret/chemin privé" "$r"
    else
        ok "rapport sans secret/chemin privé"
    fi
done
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP/rep-good/runtime-contract.json" 2>/dev/null &&
    ok "JSON valide" || bad "JSON valide" "parse"

printf '\n---------------------------------------------\n'
printf 'Resultat runtime K4/K8 : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
