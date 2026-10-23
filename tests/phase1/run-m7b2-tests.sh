#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  ECHEC %s (%s)\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "attendu [$2] obtenu [$3]"; }
FW="$ROOT/rootfs/lib/firmware/qcom/a630_sqe.fw"
INIT="$ROOT/../work/initramfs-m7b2/build-a/initramfs.img"
CFG="$ROOT/../work/config/final.config"
ROOTFS="$ROOT/../work/rootfs/rootfs-functional-usb-c"
eq "firmware source hash" 1c21b527d9183487cc550dabbb3f43e555df5a977a461934fc61f0635a9aa90c "$(sha256sum "$FW" | awk '{print $1}')"
eq "initramfs hash" 92945f85b10b8090024a254446ae2f0f66d2dd0e84eaf80f0aacba95045a55a2 "$(sha256sum "$INIT" | awk '{print $1}')"
gzip -t "$INIT" 2>/dev/null
eq "gzip valide" 0 "$?"
gzip -dc "$INIT" >"$TMP/cpio"
python3 "$ROOT/scripts/mkcpio.py" list --input "$TMP/cpio" >"$TMP/list"
eq "firmware une fois" 1 "$(grep -c '^0644 0 0 f lib/firmware/qcom/a630_sqe.fw$' "$TMP/list")"
eq "aucun autre firmware" 1 "$(awk '$4=="f" && $5 ~ /^lib\/firmware\// {c++} END{print c+0}' "$TMP/list")"
python3 - "$TMP/cpio" <<'PY'
import sys,hashlib
d=open(sys.argv[1],'rb').read(); off=0
while off+110<=len(d):
    f=[int(d[off+6+8*i:off+6+8*(i+1)],16) for i in range(13)]
    name=d[off+110:off+110+f[11]-1].decode(); pos=off+110+f[11]; pos+=(4-pos%4)%4
    if name=='lib/firmware/qcom/a630_sqe.fw':
        print(hashlib.sha256(d[pos:pos+f[6]]).hexdigest()); break
    off=pos+f[6]; off+=(4-off%4)%4
PY
eq "firmware bytes hash" 1c21b527d9183487cc550dabbb3f43e555df5a977a461934fc61f0635a9aa90c "$(python3 - "$TMP/cpio" <<'PY'
import sys,hashlib
d=open(sys.argv[1],'rb').read(); off=0
while off+110<=len(d):
    f=[int(d[off+6+8*i:off+6+8*(i+1)],16) for i in range(13)]
    name=d[off+110:off+110+f[11]-1].decode(); pos=off+110+f[11]; pos+=(4-pos%4)%4
    if name=='lib/firmware/qcom/a630_sqe.fw':
        print(hashlib.sha256(d[pos:pos+f[6]]).hexdigest()); break
    off=pos+f[6]; off+=(4-off%4)%4
PY
)"
truncate -s 34188 "$TMP/bad.fw"
"$ROOT/scripts/build-initramfs.sh" --rootfs "$ROOTFS" --kernel-config "$CFG" --kernel-release '6.18.0-rc1-a71+' --output "$TMP/bad-out" --source-date-epoch 1760369959 --firmware "$TMP/bad.fw" >/dev/null 2>&1
eq "mauvais hash firmware refusé" 3 "$?"
ln -s "$FW" "$TMP/fw-link"
"$ROOT/scripts/build-initramfs.sh" --rootfs "$ROOTFS" --kernel-config "$CFG" --kernel-release '6.18.0-rc1-a71+' --output "$TMP/link-out" --source-date-epoch 1760369959 --firmware "$TMP/fw-link" >/dev/null 2>&1
eq "symlink firmware refusé" 3 "$?"
"$ROOT/scripts/build-initramfs.sh" --rootfs "$ROOTFS" --kernel-config "$CFG" --kernel-release '6.18.0-rc1-a71+' --output "$TMP/missing-out" --source-date-epoch 1760369959 --firmware "$TMP/absent.fw" >/dev/null 2>&1
eq "firmware absent refusé" 3 "$?"
[ ! -e "$ROOT/../work/boot-candidates/m7b2/boot-gpu-fw-UNTESTED.img" ]
eq "aucun boot candidat non prouvé" 0 "$?"
"$ROOT/scripts/build-uniloader.sh" --source "$ROOT/../work/uniloader-src" --toolchain-root "$TMP/no-tc" --kernel-image "$ROOT/../work/uniLoader/blob/Image" --initramfs "$INIT" --dtb "$ROOT/../work/uniLoader/blob/dtb" --output "$TMP/u-out" >/dev/null 2>&1
eq "uniLoader sans toolchain fermé" 3 "$?"
eq "N0 référence inchangée" 04dfd20221f4d27cba545c1034720b672d5afd7c8069126bd200cb53ca63526e "$(sha256sum "$ROOT/../work/boot-ipv6.img" | awk '{print $1}')"
printf '\nResultat M7B.2 : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
