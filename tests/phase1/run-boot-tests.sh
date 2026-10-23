#!/usr/bin/env bash
# shellcheck shell=bash
#
# run-boot-tests.sh - J1/J2/J3/J4/J5, fixtures synthetiques uniquement.
# Aucun telephone, peripherique bloc, flash, montage ou sudo.

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

MAKE="$ROOT/tests/phase1/fixtures/android-boot/make-boot.py"
ANALYZE="$ROOT/scripts/analyze-stock-boot.sh"
CONTRACT="$ROOT/scripts/check-boot-contract.sh"
PACKAGE="$ROOT/scripts/package-boot-candidate.sh"
UL="$WORK/uniloader/artifacts/uniLoader"

make_manifest() {
    local out=$1 hv=$2 page=$3 size=${4:-67108864}
    cat >"$out" <<EOF
project:
  name: test
boot_image:
  validation_status: validated
  validated:
    header_version: $hv
    page_size: $page
    kernel_addr: 0x8000
    ramdisk_addr: 0x1000000
    tags_addr: 0x100
    dtb_addr: 0x1f00000
    cmdline: console=ttyMSM0,115200n8
    boot_partition_size: $size
EOF
}

section "J1 : écriture microSD consignée"
check_eq "document présent" 1 "$([ -f "$ROOT/docs/SDCARD-WRITE-RESULT.md" ] && echo 1 || echo 0)"
check_eq "hash source consigné" 2 "$(grep -c '2a42768f5d81046bb96da5d0ad3447a1ddc77ef258207314d55e7a7631aeef9d' "$ROOT/docs/SDCARD-WRITE-RESULT.md")"
check_eq "pas de chemin privé" 0 "$(grep -c '/home/mattheo' "$ROOT/docs/SDCARD-WRITE-RESULT.md")"

section "J2 : inventaire des artefacts"
if [ -x "$ROOT/scripts/audit-boot-artifacts.sh" ]; then
    "$ROOT/scripts/audit-boot-artifacts.sh" >/dev/null 2>&1
    check_eq "audit J2 -> 0" 0 "$?"
    check_eq "rapport artefacts" 1 "$(grep -c '^result=OK$' "$WORK/boot/reports/boot-artifacts.txt")"
    check_eq "provenance JSON" 0 "$(python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$WORK/boot/reports/provenance.json" 2>/dev/null; echo $?)"
    check_eq "aucun boot.img validé" 1 "$(grep -c '^validated_boot_image_present=no$' "$WORK/boot/reports/boot-artifacts.txt")"
fi

section "J3 : analyse boot Android v0-v4"
for v in 0 1 2 3 4; do
    python3 "$MAKE" --out "$TMP/boot$v.img" --version "$v" >/dev/null
    "$ANALYZE" --input "$TMP/boot$v.img" --output "$TMP/an$v" >/dev/null 2>&1
    check_eq "v$v analysé" 0 "$?"
    check_eq "v$v header_version" "$v" "$(sed -n 's/^header_version=//p' "$TMP/an$v/stock-boot-analysis.txt")"
    check_eq "v$v composant kernel" 1 "$([ -f "$TMP/an$v/components/kernel.bin" ] && echo 1 || echo 0)"
done
check_eq "v2 DTB présent" 64 "$(sed -n 's/^dtb_size=//p' "$TMP/an2/stock-boot-analysis.txt")"
check_eq "v3 page_size not_present" not_present "$(sed -n 's/^page_size=//p' "$TMP/an3/stock-boot-analysis.txt")"
python3 "$MAKE" --out "$TMP/avb.img" --version 2 --avb >/dev/null
"$ANALYZE" --input "$TMP/avb.img" --output "$TMP/anavb" >/dev/null 2>&1
check_eq "AVB détecté" yes "$(sed -n 's/^avb_footer_present=//p' "$TMP/anavb/stock-boot-analysis.txt")"

python3 "$MAKE" --out "$TMP/badmagic.img" --version 2 >/dev/null
printf 'XXXX' | dd of="$TMP/badmagic.img" bs=1 conv=notrunc status=none
check_eq "magic incorrect -> 4" 4 "$("$ANALYZE" --input "$TMP/badmagic.img" --output "$TMP/bm" >/dev/null 2>&1; echo $?)"
python3 "$MAKE" --out "$TMP/trunc.img" --version 2 >/dev/null
head -c 100 "$TMP/trunc.img" >"$TMP/trunc2.img"
check_eq "image tronquée -> 4" 4 "$("$ANALYZE" --input "$TMP/trunc2.img" --output "$TMP/tr" >/dev/null 2>&1; echo $?)"
python3 "$MAKE" --out "$TMP/off.img" --version 2 >/dev/null
python3 - "$TMP/off.img" <<'PY'
import struct,sys
p=sys.argv[1]; d=bytearray(open(p,'rb').read()); struct.pack_into('<I',d,8,0x7fffffff); open(p,'wb').write(d)
PY
check_eq "offset hors fichier -> 4" 4 "$("$ANALYZE" --input "$TMP/off.img" --output "$TMP/of" >/dev/null 2>&1; echo $?)"
python3 "$MAKE" --out "$TMP/over.img" --version 2 >/dev/null
python3 - "$TMP/over.img" <<'PY2'
import struct,sys
p=sys.argv[1]; d=bytearray(open(p,'rb').read()); struct.pack_into('<I',d,8,0xffffffff); open(p,'wb').write(d)
PY2
check_eq "taille débordante -> 4" 4 "$("$ANALYZE" --input "$TMP/over.img" --output "$TMP/ov" >/dev/null 2>&1; echo $?)"
python3 "$MAKE" --out "$TMP/cmd.img" --version 2 >/dev/null
python3 - "$TMP/cmd.img" <<'PY'
import sys
p=sys.argv[1]; d=bytearray(open(p,'rb').read()); d[64:576]=b'A'*512; open(p,'wb').write(d)
PY
check_eq "cmdline non terminée -> 4" 4 "$("$ANALYZE" --input "$TMP/cmd.img" --output "$TMP/cm" >/dev/null 2>&1; echo $?)"
python3 "$MAKE" --out "$TMP/hv.img" --version 2 >/dev/null
python3 - "$TMP/hv.img" <<'PY'
import struct,sys
p=sys.argv[1]; d=bytearray(open(p,'rb').read()); struct.pack_into('<I',d,40,9); open(p,'wb').write(d)
PY
check_eq "header inconnu -> 4" 4 "$("$ANALYZE" --input "$TMP/hv.img" --output "$TMP/hv" >/dev/null 2>&1; echo $?)"
ln -s "$TMP/boot2.img" "$TMP/link.img"
check_eq "entrée symlink -> 3" 3 "$("$ANALYZE" --input "$TMP/link.img" --output "$TMP/linkout" >/dev/null 2>&1; echo $?)"
mkdir -p "$TMP/nonempty"; touch "$TMP/nonempty/x"
check_eq "sortie non vide -> 5" 5 "$("$ANALYZE" --input "$TMP/boot2.img" --output "$TMP/nonempty" >/dev/null 2>&1; echo $?)"
cp "$TMP/boot2.img" "$TMP/mut.img"
A71_ANALYZE_TEST_MUTATE=1 "$ANALYZE" --input "$TMP/mut.img" --output "$TMP/mutout" >/dev/null 2>&1
check_eq "modification concurrente -> 6" 6 "$?"

section "J4 : contrat boot"
check_eq "stock absent -> BLOCKED_MISSING_STOCK_BOOT" 1 "$("$CONTRACT" --stock-boot "$TMP/absent.img" --boot-partition-size 67108864 --report "$TMP/c1.txt" >/dev/null 2>&1; grep -c '^status=BLOCKED_MISSING_STOCK_BOOT$' "$TMP/c1.txt")"
check_eq "taille absente -> BLOCKED_MISSING_PARTITION_SIZE" 1 "$("$CONTRACT" --stock-boot "$TMP/boot2.img" --analysis-dir "$TMP/an2" --report "$TMP/c2.txt" >/dev/null 2>&1; grep -c '^status=BLOCKED_MISSING_PARTITION_SIZE$' "$TMP/c2.txt")"
make_manifest "$TMP/manifest.yaml" 2 4096
DTB=$(sed -n 's/^dtb_sha256=//p' "$TMP/an2/stock-boot-analysis.txt")
"$CONTRACT" --stock-boot "$TMP/boot2.img" --analysis-dir "$TMP/an2" --manifest "$TMP/manifest.yaml" \
    --boot-partition-size 67108864 --android-dtb-sha256 "$DTB" \
    --vendor-boot not_required --init-boot not_required --report "$TMP/c3.txt" >/dev/null 2>&1
check_eq "contrat READY synthétique" 1 "$(grep -c '^status=READY_TO_PACKAGE$' "$TMP/c3.txt")"
"$CONTRACT" --stock-boot "$TMP/avb.img" --analysis-dir "$TMP/anavb" --manifest "$TMP/manifest.yaml" \
    --boot-partition-size 67108864 --android-dtb-sha256 "$DTB" \
    --vendor-boot not_required --init-boot not_required --report "$TMP/c4.txt" >/dev/null 2>&1
check_eq "AVB -> BLOCKED_AVB" 1 "$(grep -c '^status=BLOCKED_AVB$' "$TMP/c4.txt")"
"$CONTRACT" --stock-boot "$TMP/boot3.img" --analysis-dir "$TMP/an3" --manifest "$TMP/manifest.yaml" \
    --boot-partition-size 67108864 --android-dtb-sha256 "$DTB" \
    --vendor-boot not_required --init-boot not_required --report "$TMP/c5.txt" >/dev/null 2>&1
check_eq "header v3 -> BLOCKED_UNSUPPORTED_HEADER" 1 "$(grep -c '^status=BLOCKED_UNSUPPORTED_HEADER$' "$TMP/c5.txt")"
make_manifest "$TMP/manifest-small.yaml" 2 4096 1024
"$CONTRACT" --stock-boot "$TMP/boot2.img" --analysis-dir "$TMP/an2" --manifest "$TMP/manifest-small.yaml" \
    --boot-partition-size 1024 --android-dtb-sha256 "$DTB" \
    --vendor-boot not_required --init-boot not_required --report "$TMP/c6.txt" >/dev/null 2>&1
check_eq "partition trop petite -> BLOCKED_SIZE" 1 "$(grep -c '^status=BLOCKED_SIZE$' "$TMP/c6.txt")"
"$CONTRACT" --stock-boot "$TMP/boot2.img" --analysis-dir "$TMP/an2" --manifest "$ROOT/manifest.yaml" \
    --boot-partition-size 67108864 --android-dtb-sha256 "$DTB" \
    --vendor-boot not_required --init-boot not_required --report "$TMP/c7.txt" >/dev/null 2>&1
check_eq "manifeste TODO -> BLOCKED_UNPROVEN_PARAMETER" 1 "$(grep -c '^status=BLOCKED_UNPROVEN_PARAMETER$' "$TMP/c7.txt")"
"$CONTRACT" --stock-boot "$TMP/boot2.img" --analysis-dir "$TMP/an2" --manifest "$TMP/manifest.yaml" \
    --boot-partition-size 67108864 --android-dtb-sha256 deadbeef \
    --vendor-boot not_required --init-boot not_required --report "$TMP/c8.txt" >/dev/null 2>&1
check_eq "DTB non concordant -> BLOCKED_UNPROVEN_PARAMETER" 1 "$(grep -c '^status=BLOCKED_UNPROVEN_PARAMETER$' "$TMP/c8.txt")"

section "J5 : packager conditionnel"
mkdir -p "$TMP/pkg-empty"
"$PACKAGE" --stock-boot "$TMP/absent.img" --analysis-dir "$TMP/an2" --manifest "$TMP/manifest.yaml" \
    --boot-partition-size 67108864 --android-dtb-sha256 "$DTB" --vendor-boot not_required \
    --init-boot not_required --output "$TMP/pkg-empty/boot-a71-UNTESTED.img" --report-dir "$TMP/pkg-rep" >/dev/null 2>&1
check_eq "stock absent: aucun candidat -> 1" 1 "$?"
check_eq "stock absent: rapport no" 1 "$(grep -c '^candidate_created=no$' "$TMP/pkg-rep/package-status.txt")"
mkdir -p "$TMP/pkg-ok"
"$PACKAGE" --stock-boot "$TMP/boot2.img" --analysis-dir "$TMP/an2" --manifest "$TMP/manifest.yaml" \
    --boot-partition-size 67108864 --android-dtb-sha256 "$DTB" --vendor-boot not_required \
    --init-boot not_required --output "$TMP/pkg-ok/boot-a71-UNTESTED.img" --report-dir "$TMP/pkg-ok/rep" >/dev/null 2>&1
check_eq "candidat UNTESTED créé -> 0" 0 "$?"
check_eq "candidat présent" 1 "$([ -s "$TMP/pkg-ok/boot-a71-UNTESTED.img" ] && echo 1 || echo 0)"
check_eq "statut UNTESTED" 1 "$(grep -c '^status=UNTESTED$' "$TMP/pkg-ok/rep/candidate.txt")"
check_eq "jamais flashable" 1 "$(grep -c '^flashable=no$' "$TMP/pkg-ok/rep/candidate.txt")"
check_eq "structure conservée" 1 "$(grep -c '^structural_fields=identical$' "$TMP/pkg-ok/rep/candidate.txt")"

printf '\n%s\n' "---------------------------------------------"
printf 'Resultat boot J1-J5 : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
