#!/usr/bin/env bash
# shellcheck shell=bash
#
# check-runtime-contract.sh - verificateur statique RAM/SD/USB/SSH (lot K).
#
# Lecture seule, aucun binaire cible execute, aucun peripherique ouvert.
# Les resultats appartiennent uniquement a la liste du lot K.

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
WORK=$(cd "$REPO_ROOT/.." && pwd)/work
PROG=$(basename "$0")

ROOTFS="$WORK/rootfs/rootfs-functional-init-a"
CARD="$WORK/sdcard/A71ROOT-init.ext4"
INITRAMFS="$REPO_ROOT/initramfs"
BASE="$REPO_ROOT/base"
BOOT_IMAGE="$WORK/boot-ipv6.img"
HISTORICAL="$WORK/compat/ir-ipv6"
REPORTS="$WORK/compat/reports"
ANDROID_DTB="$REPO_ROOT/artifacts/android.dtb"
ANALYSIS_DIR="$WORK/compat/boot-analysis/boot-ipv6"

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() { say "$1"; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            cat <<EOF
$PROG - contrat runtime RAM/SD/USB/SSH (lecture seule)
  --rootfs DIR --card FILE --initramfs DIR --base DIR
  --boot-image FILE --historical DIR --reports DIR
  --android-dtb FILE --analysis DIR
EOF
            exit 0
            ;;
        --rootfs) [ $# -ge 2 ] || usage_error "--rootfs"; ROOTFS=$2; shift ;;
        --card) [ $# -ge 2 ] || usage_error "--card"; CARD=$2; shift ;;
        --initramfs) [ $# -ge 2 ] || usage_error "--initramfs"; INITRAMFS=$2; shift ;;
        --base) [ $# -ge 2 ] || usage_error "--base"; BASE=$2; shift ;;
        --boot-image) [ $# -ge 2 ] || usage_error "--boot-image"; BOOT_IMAGE=$2; shift ;;
        --historical) [ $# -ge 2 ] || usage_error "--historical"; HISTORICAL=$2; shift ;;
        --android-dtb) [ $# -ge 2 ] || usage_error "--android-dtb"; ANDROID_DTB=$2; shift ;;
        --analysis) [ $# -ge 2 ] || usage_error "--analysis"; ANALYSIS_DIR=$2; shift ;;
        --reports) [ $# -ge 2 ] || usage_error "--reports"; REPORTS=$2; shift ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

[ -d "$INITRAMFS" ] || { say "initramfs absent"; exit 3; }
[ -f "$INITRAMFS/init" ] || { say "selecteur /init absent"; exit 3; }
mkdir -p "$REPORTS" || exit 5

RESULTS=()
DETAILS=()
add() { RESULTS+=("$1"); DETAILS+=("$2"); }
FIELD=()

# 1. Deux modes implementes dans le selecteur.
MODES=0
grep -q 'a71\.mode' "$INITRAMFS/init" && MODES=$((MODES + 1))
grep -q 'switch_root /newroot /init' "$INITRAMFS/init" && MODES=$((MODES + 1))
grep -q 'exec /sbin/a71-system' "$INITRAMFS/init" && MODES=$((MODES + 1))
FIELD+=("modes_selector=$MODES/3")
for doc in BOOT-MODES.md USB-SSH.md; do
    [ -f "$REPO_ROOT/docs/$doc" ] || add "NEEDS_MANUAL_EVIDENCE" "documentation $doc absente"
done
if ! grep -q 'a71\.mode' "$REPO_ROOT/docs/BOOT-MODES.md" 2>/dev/null ||
   ! grep -qi 'RAM' "$REPO_ROOT/docs/BOOT-MODES.md" 2>/dev/null; then
    add "NEEDS_MANUAL_EVIDENCE" "documentation des modes RAM/SD incomplete"
fi
[ "$MODES" -eq 3 ] || add "NEEDS_MANUAL_EVIDENCE" "selecteur incomplet ($MODES/3)"

# 2. Mode RAM historique.
RAM_OK=1
[ -x "$BASE/sbin/a71-system" ] || RAM_OK=0
[ -x "$BASE/usr/local/sbin/usb-gadget.sh" ] || RAM_OK=0
grep -q 'exec /sbin/a71-system' "$INITRAMFS/init" || RAM_OK=0
if [ "$RAM_OK" = 1 ]; then
    add "READY_FOR_RAM_MODE_TEST" "selecteur + a71-system + gadget historique"
else
    add "NEEDS_MANUAL_EVIDENCE" "mode RAM incomplet"
fi

# 3. Identifiant root / handoff.
CARD_LABEL=""
if [ -f "$CARD" ]; then
    CARD_LABEL=$(dumpe2fs -h "$CARD" 2>/dev/null | sed -n 's/^Filesystem volume name: *//p' || true)
fi
FIELD+=("card_label=${CARD_LABEL:-unknown}")
if [ -z "$CARD_LABEL" ] || [ "$CARD_LABEL" != "A71ROOT" ]; then
    add "ROOT_IDENTIFIER_MISMATCH" "label carte '${CARD_LABEL:-absent}' != A71ROOT"
fi
if [ -f "$CARD" ]; then
    CARD_INIT=$(debugfs -R 'stat /init' "$CARD" 2>/dev/null || true)
    printf '%s\n' "$CARD_INIT" | grep -q 'Fast link dest: "/sbin/init"' ||
        add "ROOT_IDENTIFIER_MISMATCH" "carte sans /init -> /sbin/init"
fi
if [ ! -x "$ROOTFS/init" ]; then
    add "ROOT_IDENTIFIER_MISMATCH" "rootfs cible sans /init ; selecteur exige /newroot/init"
    SD_READY=0
else
    add "READY_FOR_SD_MODE_TEST" "rootfs cible contient /init"
    SD_READY=1
fi

# 4. USB : historique complet, cible sans serveur DHCP.
USB_HIST=1
grep -q '172\.16\.42\.1' "$BASE/sbin/a71-system" || USB_HIST=0
grep -q '172\.16\.43\.1' "$BASE/sbin/a71-system" || USB_HIST=0
grep -q 'dnsmasq' "$BASE/etc/init.d/a71-net" || USB_HIST=0
grep -q 'rndis\|ecm' "$BASE/usr/local/sbin/usb-gadget.sh" || USB_HIST=0
FIELD+=("usb_historical=$([ "$USB_HIST" = 1 ] && echo complete || echo incomplete)")
if grep -q 'dhcp-range' "$BASE/etc/init.d/a71-net" 2>/dev/null; then
    FIELD+=("usb_addressing=dhcp")
else
    FIELD+=("usb_addressing=static_or_unknown")
fi
KCONF="$REPO_ROOT/artifacts/kernel.config"
if [ -f "$KCONF" ] && grep -q '^CONFIG_USB_CONFIGFS_RNDIS=[ym]' "$KCONF" &&
   grep -q '^CONFIG_USB_CONFIGFS_ECM=[ym]' "$KCONF"; then
    FIELD+=("kernel_usb_config=ok")
else
    FIELD+=("kernel_usb_config=missing")
    add "USB_NETWORK_INCOMPLETE" "config noyau sans RNDIS/ECM"
fi
if [ -d "$ROOTFS" ] && [ ! -x "$ROOTFS/etc/init.d/a71-net" ] &&
   ! grep -q 'dnsmasq' "$ROOTFS/etc/apk/world" 2>/dev/null; then
    add "USB_NETWORK_INCOMPLETE" "rootfs cible sans serveur a71-net/dnsmasq"
    FIELD+=("usb_target=incomplete")
else
    FIELD+=("usb_target=complete")
fi

# 5. SSH historique et cible.
SSH_HIST=0
grep -q 'sshd' "$BASE/sbin/a71-system" && SSH_HIST=1
if [ -d "$HISTORICAL" ] && [ -f "$HISTORICAL/root/.ssh/authorized_keys" ]; then
    SSH_HIST=1
fi
FIELD+=("ssh_historical=$([ "$SSH_HIST" = 1 ] && echo complete || echo incomplete)")
SSH_TARGET=1
[ -f "$ROOTFS/root/.ssh/authorized_keys" ] || SSH_TARGET=0
if find "$ROOTFS/home" -path '*/.ssh/authorized_keys' -type f 2>/dev/null | grep -q .; then
    SSH_TARGET=1
fi
if grep -q '^PermitRootLogin no' "$ROOTFS/etc/ssh/sshd_config" 2>/dev/null; then
    SSH_TARGET=0
fi
FIELD+=("ssh_target=$([ "$SSH_TARGET" = 1 ] && echo complete || echo incomplete)")
[ "$SSH_TARGET" = 1 ] || add "SSH_INCOMPLETE" "rootfs cible sans root distant ni authorized_keys"
if [ ! -x "$ROOTFS/usr/sbin/sshd" ] || [ ! -x "$ROOTFS/bin/busybox" ] ||
   { [ ! -e "$ROOTFS/sbin/init" ] && [ ! -L "$ROOTFS/sbin/init" ]; }; then
    add "NEEDS_MANUAL_EVIDENCE" "binaires de base absents du rootfs cible"
fi
if [ ! -e "$ROOTFS/etc/runlevels/default/sshd" ] && [ ! -L "$ROOTFS/etc/runlevels/default/sshd" ]; then
    add "SSH_INCOMPLETE" "service sshd absent du runlevel default"
fi

# 6. Secrets : cible et artefacts historiques.
SECRETS_TARGET=0
if [ -d "$ROOTFS" ]; then
    find "$ROOTFS" -type f -name 'ssh_host_*_key' 2>/dev/null | grep -q . && SECRETS_TARGET=1
    grep -rIl -e 'BEGIN OPENSSH PRIVATE KEY' -e 'BEGIN RSA PRIVATE KEY' \
        -e 'BEGIN EC PRIVATE KEY' -e 'BEGIN PRIVATE KEY' "$ROOTFS" 2>/dev/null |
        grep -q . && SECRETS_TARGET=1
fi
FIELD+=("secrets_target=$([ "$SECRETS_TARGET" = 1 ] && echo present || echo absent)")
if [ "$SECRETS_TARGET" = 1 ]; then
    add "SECRET_FOUND" "cle privee dans le rootfs cible"
fi
SECRETS_HIST=0
if [ -d "$HISTORICAL" ] && find "$HISTORICAL" -type f -name 'ssh_host_*_key' 2>/dev/null | grep -q .; then
    SECRETS_HIST=1
fi
FIELD+=("secrets_historical=$([ "$SECRETS_HIST" = 1 ] && echo present || echo absent)")
if [ "$SECRETS_HIST" = 1 ]; then
    add "SECRET_FOUND" "clés hôtes privées dans l'initramfs historique (chemins/hash uniquement)"
fi

# 7. DTB historique.
DTB_STATE="unknown"
if [ -f "$ANDROID_DTB" ]; then
    ANDROID_SHA=$(sha256sum "$ANDROID_DTB" | awk '{print $1}')
    ANALYSIS="$ANALYSIS_DIR/stock-boot-analysis.txt"
    if [ -f "$ANALYSIS" ]; then
        BOOT_SHA=$(sed -n 's/^dtb_sha256=//p' "$ANALYSIS")
        [ "$ANDROID_SHA" = "$BOOT_SHA" ] && DTB_STATE="known"
    fi
fi
FIELD+=("dtb_patch=$DTB_STATE")
[ "$DTB_STATE" = "known" ] || add "FUNCTIONAL_DTB_PATCH_UNKNOWN" "DTB Android non concordant"

# 8. Release/modules et firstboot.
if [ -d "$ROOTFS/lib/modules/6.18.0-rc1-a71+" ]; then
    FIELD+=("modules_release=6.18.0-rc1-a71+")
else
    FIELD+=("modules_release=absent")
    add "NEEDS_MANUAL_EVIDENCE" "modules 6.18.0-rc1-a71+ absents"
fi
FIELD+=("firstboot=$([ -f "$ROOTFS/etc/local.d/firstboot.start" ] && echo present || echo absent)")
if [ -f "$CARD" ] && [ -x "$ROOTFS/init" ]; then
    MODE_LINE=$(debugfs -R 'stat /init' "$CARD" 2>/dev/null | grep -m1 'Mode:' || true)
    FIELD+=("init_mode=${MODE_LINE:-unknown}")
fi

# 9. Image boot historique exacte non prouvee.
FIELD+=("installed_boot=unknown")
add "NEEDS_MANUAL_EVIDENCE" "image boot exactement installee non prouvable depuis le workspace"

{
    printf 'result=OK\n'
    for i in "${!RESULTS[@]}"; do
        printf 'result_%d=%s\n' "$((i + 1))" "${RESULTS[$i]}"
        printf 'detail_%d=%s\n' "$((i + 1))" "${DETAILS[$i]}"
    done
    for f in "${FIELD[@]}"; do printf '%s\n' "$f"; done
    printf 'rootfs=%s\n' "$(basename "$ROOTFS")"
    printf 'initramfs_sha256=%s\n' "$(sha256sum "$INITRAMFS/init" | awk '{print $1}')"
    printf 'runtime_status=not_tested\n'
    printf 'validation_status=provisional\n'
} >"$REPORTS/runtime-contract.txt"

python3 - "$REPORTS/runtime-contract.txt" "$REPORTS/runtime-contract.json" <<'PY' || exit 5
import json, sys
rows = {}
for line in open(sys.argv[1], encoding="utf-8"):
    if "=" in line:
        k, v = line.rstrip("\n").split("=", 1)
        rows[k] = v
results = []
i = 1
while "result_%d" % i in rows:
    results.append({"result": rows["result_%d" % i], "detail": rows.get("detail_%d" % i, "")})
    i += 1
rows["results"] = results
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(rows, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

for i in "${!RESULTS[@]}"; do printf '%s : %s\n' "${RESULTS[$i]}" "${DETAILS[$i]}"; done
say "rapports : ${REPORTS#"$WORK/"}/runtime-contract.{txt,json}"
exit 0
