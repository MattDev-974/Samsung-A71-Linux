#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  ECHEC %s (%s)\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "attendu [$2] obtenu [$3]"; }
ARCH="$ROOT/../work/toolchain-cache/downloads/sha256/b0fad860eb94b503a56d66ca8b9ba06d2d4826943e37ebd1d7217423f6ea5bb2"
eq "archive toolchain hash" b0fad860eb94b503a56d66ca8b9ba06d2d4826943e37ebd1d7217423f6ea5bb2 "$(sha256sum "$ARCH" | awk '{print $1}')"
eq "archive taille" 83754052 "$(stat -c '%s' "$ARCH")"
CC="$ROOT/../work/toolchain/toolchain-root/bin/aarch64-buildroot-linux-gnu-gcc"
eq "gcc 13.3.0" 1 "$("$CC" --version | head -1 | grep -c '13\.3\.0')"
eq "cible buildroot" aarch64-buildroot-linux-gnu "$("$CC" -dumpmachine)"
U="$ROOT/../work/uniloader-m7b3/artifacts/uniLoader"
eq "uniLoader A/B" "$(sha256sum "$ROOT/../work/uniloader-m7b3/build-a/uniLoader" | awk '{print $1}')" "$(sha256sum "$ROOT/../work/uniloader-m7b3/build-b/uniLoader" | awk '{print $1}')"
C="$ROOT/../work/boot-candidates/m7b3/boot-gpu-fw-UNTESTED.img"
eq "candidat sha" 3e67fc0e01d17f79096766837073b1063d8267979781fabd91bbc6f94f7ae816 "$(sha256sum "$C" | awk '{print $1}')"
eq "candidat taille" 67108864 "$(stat -c '%s' "$C")"
python3 - "$C" "$U" <<'PY'
import struct,hashlib,sys
c=open(sys.argv[1],'rb').read(); u=open(sys.argv[2],'rb').read()
ks,ka,rs,ra,ss,sa,ta,ps,hv,osv=struct.unpack_from('<10I',c,8)
print('hdr',hv,ps,ks,rs,struct.unpack_from('<I',c,1648)[0])
print('kernel_match',hashlib.sha256(c[ps:ps+ks]).hexdigest()==hashlib.sha256(u).hexdigest())
print('no_avb',b'AVB0' not in c)
PY
eq "header v2" 2 "$(python3 - "$C" <<'PY'
import struct,sys
print(struct.unpack_from('<I',open(sys.argv[1],'rb').read(),8+8*4)[0])
PY
)"
eq "page 4096" 4096 "$(python3 - "$C" <<'PY'
import struct,sys
print(struct.unpack_from('<I',open(sys.argv[1],'rb').read(),8+7*4)[0])
PY
)"
# packager refuse implicit kernel-size change
"$ROOT/scripts/reproduce-historical-boot.sh" --reference "$ROOT/../work/boot-ipv6.img" --kernel "$U" --ramdisk "$ROOT/../work/empty.cpio.gz" --dtb "$ROOT/../work/lin.dtb" --output "$TMP/noallow.img" --expected 0000 >/dev/null 2>&1
eq "taille kernel non autorisée refusée" 1 "$?"
# packager candidate with allow but wrong expected
"$ROOT/scripts/reproduce-historical-boot.sh" --reference "$ROOT/../work/boot-ipv6.img" --kernel "$U" --ramdisk "$ROOT/../work/empty.cpio.gz" --dtb "$ROOT/../work/lin.dtb" --output "$TMP/wrong.img" --expected 0000 --allow-kernel-size-change >/dev/null 2>&1
eq "hash candidat incorrect refusé" 4 "$?"
eq "N0 inchangé" 04dfd20221f4d27cba545c1034720b672d5afd7c8069126bd200cb53ca63526e "$(sha256sum "$ROOT/../work/boot-ipv6.img" | awk '{print $1}')"
printf '\nResultat M7B.3 : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
