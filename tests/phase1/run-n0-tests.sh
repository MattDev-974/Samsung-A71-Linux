#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  ECHEC %s (%s)\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "attendu [$2] obtenu [$3]"; }
B="$ROOT/scripts/reproduce-historical-boot.sh"
REF="$ROOT/../work/boot-ipv6.img"; K="$ROOT/../work/uniLoader/uniLoader"
R="$ROOT/../work/empty.cpio.gz"; D="$ROOT/../work/lin.dtb"
[ -f "$REF" ] && [ -f "$K" ] && [ -f "$R" ] && [ -f "$D" ] || { echo 'fixtures N0 absentes'; exit 1; }
EXP=$(sha256sum "$REF" | awk '{print $1}')
"$B" --reference "$REF" --kernel "$K" --ramdisk "$R" --dtb "$D" --output "$TMP/a.img" --expected "$EXP" >/dev/null 2>&1
eq "build A -> 0" 0 "$?"
"$B" --reference "$REF" --kernel "$K" --ramdisk "$R" --dtb "$D" --output "$TMP/b.img" --expected "$EXP" >/dev/null 2>&1
eq "build B -> 0" 0 "$?"
eq "bit identique A" "$EXP" "$(sha256sum "$TMP/a.img" | awk '{print $1}')"
eq "bit identique B" "$EXP" "$(sha256sum "$TMP/b.img" | awk '{print $1}')"
"$B" --reference "$REF" --kernel "$K" --ramdisk "$R" --dtb "$D" --output "$TMP/c.img" --expected 0000 >/dev/null 2>&1
eq "hash attendu incorrect refusé" 4 "$?"
ln -s "$K" "$TMP/kernel-link"
"$B" --reference "$REF" --kernel "$TMP/kernel-link" --ramdisk "$R" --dtb "$D" --output "$TMP/d.img" --expected "$EXP" >/dev/null 2>&1
eq "symlink kernel refusé" 3 "$?"
"$B" --help >/dev/null 2>&1
eq "aide -> 0" 0 "$?"
printf '\nResultat N0 : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
