#!/usr/bin/env bash
# shellcheck shell=bash
#
# run-rootfs-tests.sh - non-regression D1 (modes) et E1 (validateur).
#
# Ne telecharge rien, ne compile rien, ne monte rien. Les fixtures sont creees
# dans un repertoire temporaire. Le rootfs reel n'est jamais modifie : E1 est
# strictement en lecture seule.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK="$ROOT/../work"
TMP=$(mktemp -d) || { echo "temporaire impossible" >&2; exit 1; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

PASS=0
FAIL=0
check_eq() {
    local desc=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf '  ok    %s\n' "$desc"
    else
        FAIL=$((FAIL + 1)); printf '  ECHEC %s (attendu [%s], obtenu [%s])\n' "$desc" "$expected" "$actual"
    fi
}
section() { printf '\n%s\n' "$*"; }

FIX="$TMP/fixture"
GEN="$ROOT/tests/phase1/fixtures/rootfs-validate/make-rootfs.py"
VALIDATE="$ROOT/scripts/validate-rootfs.sh"
REAL="$WORK/rootfs/rootfs-functional-usb-c"
[ -d "$REAL" ] || REAL="$WORK/rootfs/rootfs-functional-init-a"
REAL_OWN="$REAL/reports/ownership-manifest.txt"

new_fixture() {
    rm -rf "$FIX"
    python3 "$GEN" --out "$FIX" >/dev/null || return 1
}

vrun() {
    "$VALIDATE" --rootfs "$FIX" --manifest "$ROOT/manifest.yaml" \
        --ownership-manifest "$FIX/reports/ownership-manifest.txt" \
        --report "$TMP/report.txt" >/dev/null 2>&1
    echo $?
}

section "25. D1 : politique de modes et rootfs corrige"
check_eq "politique versionnee" 1 "$([ -f "$ROOT/configs/rootfs-mode-policy.txt" ] && echo 1 || echo 0)"
check_eq "politique sans doublon" 0 "$(python3 - "$ROOT/configs/rootfs-mode-policy.txt" <<'PY'
import sys
seen = set()
for line in open(sys.argv[1]):
    if not line.strip() or line.lstrip().startswith('#'):
        continue
    fields = line.split(None, 5)
    if len(fields) != 6:
        print(1); raise SystemExit
    if fields[4] in seen:
        print(1); raise SystemExit
    seen.add(fields[4])
print(0)
PY
)"
check_eq "aucun chmod recursif dans le build" 0 "$(grep -c 'chmod -R' "$ROOT/scripts/build-rootfs-functional.sh")"
check_eq "helper de modes present" 1 "$([ -x "$ROOT/scripts/rootfs-modes.py" ] && echo 1 || echo 0)"
if [ -d "$REAL" ]; then
    check_eq "bbsuid mode exact" 4111 "$(stat -c '%a' "$REAL/bin/bbsuid")"
    check_eq "busybox executable par tous" 755 "$(stat -c '%a' "$REAL/bin/busybox")"
    check_eq "passwd lisible" 644 "$(stat -c '%a' "$REAL/etc/passwd")"
    check_eq "group lisible" 644 "$(stat -c '%a' "$REAL/etc/group")"
    check_eq "shadow non lisible par les autres" 640 "$(stat -c '%a' "$REAL/etc/shadow")"
    check_eq "firstboot executable" 755 "$(stat -c '%a' "$REAL/etc/local.d/firstboot.start")"
    check_eq "root en 0700" 700 "$(stat -c '%a' "$REAL/root")"
    check_eq "tmp sticky" 1777 "$(stat -c '%a' "$REAL/tmp")"
    check_eq "var/tmp sticky" 1777 "$(stat -c '%a' "$REAL/var/tmp")"
    check_eq "manifeste: bbsuid 4111" 1 "$(grep -c '^0:0:4111:f:/bin/bbsuid$' "$REAL_OWN")"
    check_eq "manifeste: passwd 0644" 1 "$(grep -c '^0:0:0644:f:/etc/passwd$' "$REAL_OWN")"
    check_eq "manifeste: shadow 0640" 1 "$(grep -c '^0:0:0640:f:/etc/shadow$' "$REAL_OWN")"
    check_eq "manifeste: tmp 1777" 1 "$(grep -c '^0:0:1777:d:/tmp$' "$REAL_OWN")"
    check_eq "reproductibilite D1" yes "$(awk -F= '/^overall_reproducible=/{print $2}' "$WORK/runtime-analysis/rootfs-usb-final-reproducibility.txt")"
else
    printf '  (ignore) rootfs-functional absent\n'
fi

section "26. E1 : validateur rootfs"
new_fixture || { echo "fixture impossible" >&2; exit 1; }
check_eq "fixture valide -> 0" 0 "$(vrun)"
check_eq "rapport RESULTAT=OK" 1 "$(grep -c '^RESULTAT=OK$' "$TMP/report.txt")"
"$VALIDATE" --rootfs "$TMP/absent" --manifest "$ROOT/manifest.yaml" \
    --ownership-manifest "$TMP/absent.txt" --report "$TMP/r.txt" >/dev/null 2>&1
check_eq "rootfs absent -> 3" 3 "$?"
"$VALIDATE" --rootfs "$FIX" --manifest "$TMP/absent.yaml" \
    --ownership-manifest "$FIX/reports/ownership-manifest.txt" --report "$TMP/r.txt" >/dev/null 2>&1
check_eq "manifeste absent -> 3" 3 "$?"
if [ -d "$REAL" ]; then
    "$VALIDATE" --rootfs "$REAL" --manifest "$ROOT/manifest.yaml" \
        --ownership-manifest "$REAL_OWN" --report "$TMP/real.txt" >/dev/null 2>&1
    check_eq "rootfs reel -> 0" 0 "$?"
    check_eq "rootfs reel RESULTAT=OK" 1 "$(grep -c '^RESULTAT=OK$' "$TMP/real.txt")"
fi

# M5 : console ttyMSM0 absente et correction idempotente.
new_fixture
check_eq "inittab commenté accepté" 0 "$(vrun)"
new_fixture
sed -i 's/^#ttyMSM0/ttyMSM0/' "$FIX/etc/inittab"
check_eq "ttyMSM0 actif refusé" 1 "$(vrun)"
check_eq "motif ttyMSM0 actif" 1 "$(grep -c '^FAIL no_active_ttyMSM0' "$TMP/report.txt" || true)"
new_fixture
sed -i '/^tty0::respawn:/d' "$FIX/etc/inittab"
check_eq "tty0 absent refusé" 1 "$(vrun)"
check_eq "motif tty0 absent" 1 "$(grep -c '^FAIL tty0_console' "$TMP/report.txt" || true)"
new_fixture
printf '#!/bin/sh\necho test >/dev/ttyMSM0\n' >"$FIX/etc/init.d/a71-bad"
chmod 755 "$FIX/etc/init.d/a71-bad"
check_eq "redirection service ttyMSM0 refusée" 1 "$(vrun)"
check_eq "motif redirection service" 1 "$(grep -c '^FAIL no_service_ttyMSM0' "$TMP/report.txt" || true)"
new_fixture
awk '{if ($0 ~ /^[[:space:]]*ttyMSM0::respawn:/) print "#" $0; else print}' "$FIX/etc/inittab" >"$TMP/it1"
awk '{if ($0 ~ /^[[:space:]]*ttyMSM0::respawn:/) print "#" $0; else print}' "$TMP/it1" >"$TMP/it2"
check_eq "correction inittab idempotente" 0 "$(cmp -s "$TMP/it1" "$TMP/it2"; echo $?)"
check_eq "aucune entrée active après correction" 0 "$(grep -Ec '^[[:space:]]*ttyMSM0::respawn:' "$TMP/it2" || true)"

# Chaque cas repart d'une fixture neuve.
new_fixture; printf '3.22.6\n' >"$FIX/etc/alpine-release"
check_eq "mauvaise version -> 1" 1 "$(vrun)"
new_fixture; printf 'a72\n' >"$FIX/etc/hostname"
check_eq "mauvais hostname -> 1" 1 "$(vrun)"
new_fixture; rm -f "$FIX"/lib/modules/6.18.0-rc1-a71+/kernel/module0000.ko
check_eq "module manquant -> 1" 1 "$(vrun)"
new_fixture; rm -f "$FIX"/lib/modules/6.18.0-rc1-a71+/modules.dep
check_eq "modules.dep absent -> 1" 1 "$(vrun)"
new_fixture; sed -i 's/^root:\*:/root:$6$abc$def:/' "$FIX/etc/shadow"
check_eq "root non verrouille -> 1" 1 "$(vrun)"
new_fixture; printf 'user::0:0:user:/home/user:/bin/sh\n' >>"$FIX/etc/shadow"
check_eq "mot de passe vide -> 1" 1 "$(vrun)"
new_fixture; printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'secret' '-----END OPENSSH PRIVATE KEY-----' >"$FIX/root/leak.txt"
check_eq "vraie cle privee texte -> 1" 1 "$(vrun)"
new_fixture; printf '\n-----BEGIN RSA PRIVATE KEY-----\n' >>"$FIX/bin/busybox"
check_eq "PEM dans un ELF ignore -> 0" 0 "$(vrun)"
new_fixture; printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' >"$FIX/etc/ssh/ssh_host_ed25519_key"
check_eq "cle hote prefabriquee -> 1" 1 "$(vrun)"
new_fixture; chmod 600 "$FIX/etc/passwd"
check_eq "mauvais mode passwd -> 1" 1 "$(vrun)"
new_fixture; chmod 644 "$FIX/etc/shadow"
check_eq "mauvais mode shadow -> 1" 1 "$(vrun)"
new_fixture; chmod 700 "$FIX/bin/busybox"
check_eq "BusyBox 0700 refuse -> 1" 1 "$(vrun)"
new_fixture; chmod 777 "$FIX/tmp"
check_eq "tmp sans sticky refuse -> 1" 1 "$(vrun)"
new_fixture; rm -f "$FIX/init"
check_eq "init absent -> 1" 1 "$(vrun)"
new_fixture; rm -f "$FIX/init"; printf '#!/bin/sh\n' >"$FIX/init"
check_eq "init fichier regulier -> 1" 1 "$(vrun)"
new_fixture; ln -sfn /bin/sh "$FIX/init"
check_eq "init mauvaise cible -> 1" 1 "$(vrun)"
new_fixture; ln -sfn sbin/init "$FIX/init"
check_eq "init cible relative -> 1" 1 "$(vrun)"
new_fixture; rm -f "$FIX/sbin/init"
check_eq "init cible absente -> 1" 1 "$(vrun)"
new_fixture; chmod 644 "$FIX/bin/busybox"
check_eq "init cible non executable -> 1" 1 "$(vrun)"
new_fixture; ln -sfn ../../outside "$FIX/init"
check_eq "init cible sortante -> 1" 1 "$(vrun)"
new_fixture; ln -sfn /init "$FIX/sbin/init"
check_eq "init boucle -> 1" 1 "$(vrun)"
new_fixture; rm -f "$FIX/etc/init.d/a71-usb"
check_eq "a71-usb absent -> 1" 1 "$(vrun)"
new_fixture; printf 'provide net\n' >>"$FIX/etc/init.d/a71-usb"
check_eq "a71-usb provide net -> 1" 1 "$(vrun)"
new_fixture; sed -i 's/ provide net//' "$FIX/etc/init.d/a71-net"
check_eq "a71-net sans provide net -> 1" 1 "$(vrun)"
new_fixture; sed -i 's/10\.71\.0\.2/10.71.99.2/' "$FIX/etc/init.d/a71-net"
check_eq "a71-net mauvaise IPv4 -> 1" 1 "$(vrun)"
new_fixture; rm -f "$FIX/etc/modprobe.d/a71-historical-kernel.conf"
check_eq "blacklist ipv6 absente -> 1" 1 "$(vrun)"
new_fixture; printf 'modprobe ipv6\n' >"$FIX/etc/load-ipv6.conf"
check_eq "chargement ipv6 explicite -> 1" 1 "$(vrun)"
new_fixture; printf 'ssh-ed25519 AAAA test\n' >"$FIX/root/.ssh/authorized_keys"
check_eq "authorized_keys historique -> 1" 1 "$(vrun)"
new_fixture; rm -f "$FIX/etc/runlevels/default/a71-usb"
check_eq "runlevel a71-usb absent -> 1" 1 "$(vrun)"
new_fixture; chmod 755 "$FIX/root/.ssh"
check_eq "root/.ssh mode trop large -> 1" 1 "$(vrun)"

new_fixture; printf 'x\n' >"$FIX/usr/bin/su"; chmod 4755 "$FIX/usr/bin/su"
check_eq "setuid inattendu refuse -> 1" 1 "$(vrun)"
new_fixture; chmod 666 "$FIX/etc/hosts"
check_eq "world-writable inattendu refuse -> 1" 1 "$(vrun)"
new_fixture; head -1 "$FIX/reports/ownership-manifest.txt" >>"$FIX/reports/ownership-manifest.txt"
check_eq "doublon du manifeste -> 1" 1 "$(vrun)"
new_fixture; printf '0:0:0644:f:/../etc/passwd\n' >>"$FIX/reports/ownership-manifest.txt"
check_eq "traversal -> 1" 1 "$(vrun)"
new_fixture; ln -s "$TMP/report-target" "$TMP/report-link"
"$VALIDATE" --rootfs "$FIX" --manifest "$ROOT/manifest.yaml" \
    --ownership-manifest "$FIX/reports/ownership-manifest.txt" \
    --report "$TMP/report-link" >/dev/null 2>&1
check_eq "rapport symlink refuse -> 4" 4 "$?"

section "27. F1 : initramfs reproductible"
F1="$WORK/initramfs"
if [ -d "$F1" ]; then
    check_eq "image presente" 1 "$([ -s "$F1/initramfs.img" ] && echo 1 || echo 0)"
    check_eq "sha256 verifie" 0 "$(cd "$F1" && sha256sum -c initramfs.img.sha256 >/dev/null 2>&1; echo $?)"
    check_eq "summary result OK" 1 "$(grep -c '^result=OK$' "$F1/initramfs-summary.txt")"
    check_eq "reproductibilite F1" yes "$(awk -F= '/^overall_reproducible=/{print $2}' "$F1/reproducibility.txt")"
    check_eq "build-a = build-b" 0 "$(cmp -s "$F1/initramfs-a.img" "$F1/initramfs-b.img"; echo $?)"
    check_eq "gzip valide" 0 "$(gzip -t "$F1/initramfs.img" 2>/dev/null; echo $?)"
    check_eq "aucun module dans l'initramfs" 0 "$(gzip -dc "$F1/initramfs.img" | python3 "$ROOT/scripts/mkcpio.py" list --input /dev/stdin 2>/dev/null | grep -c '\.ko')"
    check_eq "chargeur musl present" 1 "$(gzip -dc "$F1/initramfs.img" | python3 "$ROOT/scripts/mkcpio.py" list --input /dev/stdin 2>/dev/null | grep -c 'f lib/ld-musl-aarch64.so.1')"
    check_eq "/init executable" 1 "$(gzip -dc "$F1/initramfs.img" | python3 "$ROOT/scripts/mkcpio.py" list --input /dev/stdin 2>/dev/null | grep -c '^0755 0 0 f init$')"
    check_eq "busybox AArch64" 1 "$(python3 - "$F1/build-a/bin/busybox" <<'PY'
import sys
h=open(sys.argv[1],'rb').read(20)
print(1 if len(h)>=20 and h[:4]==b'\x7fELF' and h[4]==2 and h[5]==1 and int.from_bytes(h[18:20],'little')==183 else 0)
PY
)"
    check_eq "/init ne demarre pas le reseau" 0 "$(grep -Ec '(^|[[:space:]])(udhcpc|dhcpcd|ifconfig|wget|curl)([[:space:]]|$)' "$F1/build-a/init")"
    check_eq "/init fait switch_root" 1 "$(grep -c 'switch_root /newroot /sbin/init' "$F1/build-a/init")"
    check_eq "aucun fichier temporaire publie" 0 "$(find "$F1" -maxdepth 1 \( -name '*.cpio' -o -name '*.check*' \) | wc -l | tr -d ' ')"
    "$ROOT/scripts/build-initramfs.sh" --rootfs "$REAL" --kernel-config "$WORK/config/final.config" \
        --kernel-release 6.18.0-rc1-a71+ --output "$TMP/f1-rerun" --source-date-epoch 1760369959 >/dev/null 2>&1
    check_eq "reconstruction independante -> 0" 0 "$?"
    check_eq "meme SHA-256" "$(sha256sum "$F1/initramfs.img" | awk '{print $1}')" "$(sha256sum "$TMP/f1-rerun/initramfs.img" | awk '{print $1}')"
else
    printf '  (ignore) work/initramfs absent\n'
fi

# Config negative : pilote critique en module -> refus.
if [ -d "$REAL" ] && [ -f "$WORK/config/final.config" ]; then
sed 's/^CONFIG_EXT4_FS=y$/CONFIG_EXT4_FS=m/' "$WORK/config/final.config" >"$TMP/bad.config"
"$ROOT/scripts/build-initramfs.sh" --rootfs "$REAL" --kernel-config "$TMP/bad.config" \
    --kernel-release 6.18.0-rc1-a71+ --output "$TMP/f1-bad" --source-date-epoch 1760369959 >/dev/null 2>&1
check_eq "EXT4_FS=m refuse -> 4" 4 "$?"
"$ROOT/scripts/build-initramfs.sh" --rootfs "$REAL" --kernel-config "$WORK/config/final.config" \
    --kernel-release 6.18.0-rc1-a71+ --output "$TMP/f1-bad" --source-date-epoch abc >/dev/null 2>&1
check_eq "epoch invalide -> 2" 2 "$?"
"$ROOT/scripts/build-initramfs.sh" --rootfs "$TMP/absent" --kernel-config "$WORK/config/final.config" \
    --kernel-release 6.18.0-rc1-a71+ --output "$TMP/f1-bad" --source-date-epoch 1760369959 >/dev/null 2>&1
check_eq "rootfs absent -> 3" 3 "$?"
fi

printf '\n%s\n' "---------------------------------------------"
printf 'Resultat rootfs : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
