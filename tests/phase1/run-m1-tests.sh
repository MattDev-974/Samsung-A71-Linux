#!/usr/bin/env bash
# run-m1-tests.sh - M1: services USB/reseau/SSH, provisioning, fixtures ConfigFS.
# Aucun root, aucun /sys reel, aucun peripherique, aucune carte.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK="$ROOT/../work"
TMP=$(mktemp -d) || { echo "temporaire impossible" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ECHEC %s (%s)\n' "$1" "$2"; }
eq() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "attendu [$2] obtenu [$3]"; }
section() { printf '\n%s\n' "$1"; }

REAL="$WORK/rootfs/rootfs-functional-usb-c"
VALIDATE="$ROOT/scripts/validate-rootfs.sh"
GADGET="$ROOT/rootfs/usr/local/sbin/a71-usb-gadget"
PROV="$ROOT/scripts/provision-ssh-key.sh"

section "M1 : scripts statiques"
for f in "$GADGET" "$ROOT/rootfs/etc/init.d/a71-usb" "$ROOT/rootfs/etc/init.d/a71-net" \
         "$ROOT/rootfs/etc/init.d/a71-ssh-keys" "$ROOT/rootfs/etc/init.d/a71-bootlog"; do
    /bin/sh -n "$f" && ok "sh -n $(basename "$f")" || bad "sh -n $(basename "$f")" "syntaxe"
done
grep -q '0x1d6b' "$GADGET" && grep -q '0x0104' "$GADGET" && ok "VID/PID" || bad "VID/PID" "absent"
grep -qi rndis "$GADGET" && grep -qi ecm "$GADGET" && ok "RNDIS/ECM" || bad "RNDIS/ECM" "absent"
grep -q 'a600000.usb' "$GADGET" && ok "fallback UDC" || bad "fallback UDC" "absent"
grep -q 'provide net' "$ROOT/rootfs/etc/init.d/a71-net" && ok "a71-net provide net" || bad "a71-net provide net" "absent"
grep -q 'provide net' "$ROOT/rootfs/etc/init.d/a71-usb" && bad "a71-usb no provide net" "present" || ok "a71-usb no provide net"
grep -q 'blacklist ipv6' "$ROOT/rootfs/etc/modprobe.d/a71-historical-kernel.conf" && ok "blacklist ipv6" || bad "blacklist ipv6" "absent"

section "M1 : rootfs reel"
if [ -d "$REAL" ]; then
    "$VALIDATE" --rootfs "$REAL" --manifest "$ROOT/manifest.yaml" \
        --ownership-manifest "$REAL/reports/ownership-manifest.txt" \
        --report "$TMP/e1.txt" >/dev/null 2>&1
    eq "E1 USB -> 0" 0 "$?"
    eq "E1 checks 112" 112 "$(sed -n 's/^checks=//p' "$TMP/e1.txt")"
    eq "paquets 100" 100 "$(grep -c '^P:' "$REAL/lib/apk/db/installed")"
    eq "/init" /sbin/init "$(readlink "$REAL/init")"
    eq "no usb0 dhcp" 0 "$(grep -c 'iface usb0 inet dhcp' "$REAL/etc/network/interfaces" || true)"
    eq "authorized_keys absent" 0 "$([ -e "$REAL/root/.ssh/authorized_keys" ] && echo 1 || echo 0)"
    eq "host keys absentes" 0 "$(find "$REAL/etc/ssh" -maxdepth 1 -name 'ssh_host_*_key' | wc -l | tr -d ' ')"
else
    bad "rootfs USB reel" "absent"
fi

section "M1 : simulation ConfigFS"
CFS="$TMP/cfs"; UDC="$TMP/udc"; mkdir -p "$CFS/usb_gadget" "$UDC/a600000.usb" "$CFS/usb_gadget/other"
cat >"$TMP/bb" <<'EOB'
#!/bin/sh
exec "$@"
EOB
chmod 755 "$TMP/bb"
g_env() { env A71_CONFIGFS_ROOT="$CFS" A71_UDC_ROOT="$UDC" A71_TEST_BB="$TMP/bb" "$@"; }
g_env "$GADGET" start >/dev/null 2>&1
eq "gadget start -> 0" 0 "$?"
eq "VID" 0x1d6b "$(cat "$CFS/usb_gadget/a71/idVendor")"
eq "PID" 0x0104 "$(cat "$CFS/usb_gadget/a71/idProduct")"
eq "UDC" a600000.usb "$(cat "$CFS/usb_gadget/a71/UDC")"
eq "rndis link" "$CFS/usb_gadget/a71/functions/rndis.usb0" "$(readlink "$CFS/usb_gadget/a71/configs/c.1/rndis.usb0")"
eq "ecm link" "$CFS/usb_gadget/a71/functions/ecm.usb0" "$(readlink "$CFS/usb_gadget/a71/configs/c.1/ecm.usb0")"
g_env "$GADGET" start >/dev/null 2>&1
eq "gadget start idempotent" 0 "$?"
g_env "$GADGET" status >/dev/null 2>&1
eq "gadget status" 0 "$?"
g_env "$GADGET" stop >/dev/null 2>&1
eq "gadget stop" 0 "$?"
eq "gadget a71 supprime" 0 "$([ -e "$CFS/usb_gadget/a71" ] && echo 1 || echo 0)"
eq "autre gadget conserve" 1 "$([ -d "$CFS/usb_gadget/other" ] && echo 1 || echo 0)"
mkdir -p "$TMP/udc2/a" "$TMP/udc2/b"
env A71_CONFIGFS_ROOT="$CFS" A71_UDC_ROOT="$TMP/udc2" A71_TEST_BB="$TMP/bb" A71_UDC_WAIT=0 "$GADGET" start >/dev/null 2>&1
eq "UDC multiple sans a600 -> echec" 1 "$?"
mkdir -p "$TMP/udc3/a600000.usb" "$TMP/udc3/z"
env A71_CONFIGFS_ROOT="$CFS" A71_UDC_ROOT="$TMP/udc3" A71_TEST_BB="$TMP/bb" "$GADGET" start >/dev/null 2>&1
eq "UDC multiple avec a600 -> 0" 0 "$?"
eq "UDC choisie" a600000.usb "$(cat "$CFS/usb_gadget/a71/UDC")"
env A71_CONFIGFS_ROOT="$CFS" A71_UDC_ROOT="$TMP/udc3" A71_TEST_BB="$TMP/bb" "$GADGET" stop >/dev/null 2>&1

section "M3 : fixture M2 — liens manquants et UDC tardif"
CFS2="$TMP/cfs-partial"; UDC2="$TMP/udc-partial"
mkdir -p "$CFS2/usb_gadget/a71/functions/rndis.usb0" "$CFS2/usb_gadget/a71/functions/ecm.usb0"          "$CFS2/usb_gadget/a71/configs/c.1" "$CFS2/usb_gadget/a71/strings/0x409" "$UDC2/a600000.usb"
env A71_CONFIGFS_ROOT="$CFS2" A71_UDC_ROOT="$UDC2" A71_TEST_BB="$TMP/bb" A71_UDC_WAIT=2 "$GADGET" start >/dev/null 2>&1
eq "état partiel M2 réparé -> 0" 0 "$?"
eq "lien RNDIS absolu" "$CFS2/usb_gadget/a71/functions/rndis.usb0" "$(readlink "$CFS2/usb_gadget/a71/configs/c.1/rndis.usb0")"
eq "lien ECM absolu" "$CFS2/usb_gadget/a71/functions/ecm.usb0" "$(readlink "$CFS2/usb_gadget/a71/configs/c.1/ecm.usb0")"
eq "UDC liée" a600000.usb "$(cat "$CFS2/usb_gadget/a71/UDC")"
env A71_CONFIGFS_ROOT="$CFS2" A71_UDC_ROOT="$UDC2" A71_TEST_BB="$TMP/bb" "$GADGET" stop >/dev/null 2>&1
# Fixture ConfigFS réelle : les liens relatifs sont refusés comme sur l'appareil.
cat >"$TMP/bb-configfs" <<'EOB'
#!/bin/sh
if [ "$1" = "ln" ] && [ "$2" = "-s" ]; then
    case "$3" in ../*) exit 1 ;; esac
fi
exec "$@"
EOB
chmod 755 "$TMP/bb-configfs"
CFS4="$TMP/cfs-reject"; UDC4="$TMP/udc-reject"
mkdir -p "$CFS4/usb_gadget" "$UDC4/a600000.usb"
env A71_CONFIGFS_ROOT="$CFS4" A71_UDC_ROOT="$UDC4" A71_TEST_BB="$TMP/bb-configfs" A71_UDC_WAIT=1     "$WORK/card-comparison/m2-before-fix/card-files/usr/local/sbin/a71-usb-gadget" start >/dev/null 2>&1
eq "ancien script M2 avec ConfigFS strict -> échec" 1 "$?"
eq "aucun lien relatif accepté" 0 "$([ -e "$CFS4/usb_gadget/a71/configs/c.1/rndis.usb0" ] && echo 1 || echo 0)"
env A71_CONFIGFS_ROOT="$CFS4" A71_UDC_ROOT="$UDC4" A71_TEST_BB="$TMP/bb-configfs" A71_UDC_WAIT=1 "$GADGET" start >/dev/null 2>&1
eq "script corrigé sur même état -> 0" 0 "$?"
eq "lien absolu après correction" "$CFS4/usb_gadget/a71/functions/rndis.usb0" "$(readlink "$CFS4/usb_gadget/a71/configs/c.1/rndis.usb0")"
env A71_CONFIGFS_ROOT="$CFS4" A71_UDC_ROOT="$UDC4" A71_TEST_BB="$TMP/bb-configfs" "$GADGET" stop >/dev/null 2>&1
CFS3="$TMP/cfs-delay"; UDC3="$TMP/udc-delay"; mkdir -p "$CFS3/usb_gadget" "$UDC3"
( /bin/sleep 1; mkdir -p "$UDC3/a600000.usb" ) &
env A71_CONFIGFS_ROOT="$CFS3" A71_UDC_ROOT="$UDC3" A71_TEST_BB="$TMP/bb" A71_UDC_WAIT=5 "$GADGET" start >/dev/null 2>&1
eq "UDC tardif attendu -> 0" 0 "$?"
eq "UDC tardif liée" a600000.usb "$(cat "$CFS3/usb_gadget/a71/UDC")"
env A71_CONFIGFS_ROOT="$CFS3" A71_UDC_ROOT="$UDC3" A71_TEST_BB="$TMP/bb" "$GADGET" stop >/dev/null 2>&1

section "M1 : provisionnement SSH"
FIX="$TMP/rootfs"; python3 "$ROOT/tests/phase1/fixtures/rootfs-validate/make-rootfs.py" --out "$FIX" >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$TMP/client" >/dev/null 2>&1
PUB="$TMP/client.pub"
"$PROV" --rootfs "$FIX" --public-key "$PUB" >"$TMP/prov.out" 2>"$TMP/prov.err"
eq "provision valide -> 0" 0 "$?"
eq "authorized_keys mode 600" 600 "$(stat -c '%a' "$FIX/root/.ssh/authorized_keys")"
eq "authorized_keys une ligne" 1 "$(wc -l <"$FIX/root/.ssh/authorized_keys")"
eq "permit root prohibit" 1 "$(grep -c '^PermitRootLogin prohibit-password$' "$FIX/etc/ssh/sshd_config")"
eq "manifeste .ssh" 1 "$(grep -c '^0:0:0700:d:/root/.ssh$' "$FIX/reports/ownership-manifest.txt")"
eq "manifeste authorized" 1 "$(grep -c '^0:0:0600:f:/root/.ssh/authorized_keys$' "$FIX/reports/ownership-manifest.txt")"
eq "cle publique non affichee" 0 "$(grep -F -h -c "$(cat "$PUB")" "$TMP/prov.out" "$TMP/prov.err" 2>/dev/null | awk '{s+=$1} END{print s+0}')"

python3 "$ROOT/tests/phase1/fixtures/rootfs-validate/make-rootfs.py" --out "$TMP/fix2" >/dev/null
printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'secret' >"$TMP/priv"
"$PROV" --rootfs "$TMP/fix2" --public-key "$TMP/priv" >/dev/null 2>&1
eq "cle privee refusee" 1 "$?"
ln -s "$PUB" "$TMP/pub-link"
"$PROV" --rootfs "$TMP/fix2" --public-key "$TMP/pub-link" >/dev/null 2>&1
eq "cle symlink refusee" 1 "$?"
printf '%s\n%s\n' "$(cat "$PUB")" "$(cat "$PUB")" >"$TMP/two"
"$PROV" --rootfs "$TMP/fix2" --public-key "$TMP/two" >/dev/null 2>&1
eq "deux cles refusees" 1 "$?"
"$PROV" --rootfs "$TMP/nope" --public-key "$PUB" >/dev/null 2>&1
eq "rootfs absent refuse" 1 "$?"
python3 "$ROOT/tests/phase1/fixtures/rootfs-validate/make-rootfs.py" --out "$TMP/fix3" >/dev/null
mkdir -p "$TMP/fix3/root/.ssh"; printf 'ssh-ed25519 AAAA old\n' >"$TMP/fix3/root/.ssh/authorized_keys"
"$PROV" --rootfs "$TMP/fix3" --public-key "$PUB" >/dev/null 2>&1
eq "authorized_keys existant refuse" 1 "$?"

printf '\n---------------------------------------------\n'
printf 'Resultat M1 : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
