#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  ECHEC %s (%s)\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "attendu [$2] obtenu [$3]"; }
"$ROOT/scripts/audit-wifi-firmware.sh" --root "$ROOT/rootfs" >/dev/null 2>&1
eq "audit firmware WCN3990" 0 "$?"
# Copie locale pour les cas negatifs
mkdir -p "$TMP/root"
cp -a "$ROOT/rootfs/lib" "$TMP/root/"
D="$TMP/root/lib/firmware/ath10k/WCN3990/hw1.0"
rm "$D/board-2.bin"
"$ROOT/scripts/audit-wifi-firmware.sh" --root "$TMP/root" >/dev/null 2>&1
[ "$?" -ne 0 ]; eq "fichier absent refusé" 0 "$?"
cp "$ROOT/rootfs/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin" "$D/board-2.bin"
printf x >> "$D/board-2.bin"
"$ROOT/scripts/audit-wifi-firmware.sh" --root "$TMP/root" >/dev/null 2>&1
[ "$?" -ne 0 ]; eq "mauvais hash refusé" 0 "$?"
cp "$ROOT/rootfs/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin" "$D/board-2.bin"
chmod 600 "$D/board-2.bin"
"$ROOT/scripts/audit-wifi-firmware.sh" --root "$TMP/root" >/dev/null 2>&1
[ "$?" -ne 0 ]; eq "mauvais mode refusé" 0 "$?"
rm -f "$D/board-2.bin"; ln -s /dev/null "$D/board-2.bin"
"$ROOT/scripts/audit-wifi-firmware.sh" --root "$TMP/root" >/dev/null 2>&1
[ "$?" -ne 0 ]; eq "symlink refusé" 0 "$?"
# Contrats statiques noyau/DT
grep -qx 'CONFIG_ATH10K=m' "$ROOT/artifacts/kernel.config"
eq "CONFIG_ATH10K=m" 0 "$?"
grep -qx 'CONFIG_ATH10K_SNOC=m' "$ROOT/artifacts/kernel.config"
eq "CONFIG_ATH10K_SNOC=m" 0 "$?"
grep -q 'qcom,wcn3990-wifi' "$ROOT/../work/kernel/arch/arm64/boot/dts/qcom/sm7150.dtsi"
eq "DT compatible WCN3990" 0 "$?"
python3 - "$ROOT/../work/uniLoader/blob/dtb" <<'PY'
import subprocess,sys
s=subprocess.check_output(['dtc','-I','dtb','-O','dts',sys.argv[1]],stderr=subprocess.DEVNULL,text=True)
i=s.find('wifi@18800000 {'); block=s[i:i+2500]
assert 'qcom,wcn3990-wifi' in block and 'status = "okay"' in block
PY
eq "DTB wifi status okay" 0 "$?"
MOD="$ROOT/../work/rootfs/rootfs-functional-usb-c/lib/modules/6.18.0-rc1-a71+/kernel/drivers/net/wireless/ath/ath10k/ath10k_snoc.ko"
modinfo -F vermagic "$MOD" | grep -qx '6.18.0-rc1-a71+ SMP preempt mod_unload aarch64'
eq "vermagic ath10k_snoc" 0 "$?"
truncate -s 64 "$TMP/bad.ko"
modinfo "$TMP/bad.ko" >/dev/null 2>&1
[ "$?" -ne 0 ]; eq "module incompatible/truncated refusé" 0 "$?"
dtc -I dtb -O dts "$TMP/absent.dtb" >/dev/null 2>&1
[ "$?" -ne 0 ]; eq "DTB absent refusé" 0 "$?"
printf '\nResultat M9A : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
