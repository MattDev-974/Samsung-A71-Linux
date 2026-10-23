#!/usr/bin/env bash
# shellcheck shell=bash
#
# package-boot-candidate.sh - packager conditionnel UNTESTED (J5), sans flash.
#
# Ne produit une image que si check-boot-contract.sh retourne exactement
# READY_TO_PACKAGE. Le mot "flashable" n'est jamais utilise.
#
# Codes : 0 candidat cree, 1 contrat non READY, 2 usage, 3 entree,
#         4 construction, 5 verification, 6 sortie.

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
WORK=$(cd "$REPO_ROOT/.." && pwd)/work
PROG=$(basename "$0")

STOCK="$WORK/input/stock-boot.img"
ANALYSIS="$WORK/boot/stock"
UNILOADER="$WORK/uniloader/artifacts/uniLoader"
MANIFEST="$REPO_ROOT/manifest.yaml"
PART_SIZE=""
OUT="$WORK/boot/candidate/boot-a71-UNTESTED.img"
ANDROID_DTB_SHA=""
VENDOR_STATUS=unknown
INIT_STATUS=unknown
FORCE=0
REPORT_DIR=""

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() { say "$1"; exit 2; }
die() { local c=$1; shift; say "$*"; exit "$c"; }

usage() {
    cat <<EOF
$PROG - candidat boot UNTESTED, conditionne au contrat J4

Usage
  $PROG --boot-partition-size N [options]

Options
  --stock-boot FILE, --analysis-dir DIR, --uniloader FILE, --manifest FILE
  --android-dtb-sha256 SHA, --vendor-boot STATUS, --init-boot STATUS
  --output FILE (defaut work/boot/candidate/boot-a71-UNTESTED.img)
  --force
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --stock-boot) [ $# -ge 2 ] || usage_error "--stock-boot"; STOCK=$2; shift ;;
        --analysis-dir) [ $# -ge 2 ] || usage_error "--analysis-dir"; ANALYSIS=$2; shift ;;
        --uniloader) [ $# -ge 2 ] || usage_error "--uniloader"; UNILOADER=$2; shift ;;
        --manifest) [ $# -ge 2 ] || usage_error "--manifest"; MANIFEST=$2; shift ;;
        --boot-partition-size) [ $# -ge 2 ] || usage_error "--boot-partition-size"; PART_SIZE=$2; shift ;;
        --android-dtb-sha256) [ $# -ge 2 ] || usage_error "--android-dtb-sha256"; ANDROID_DTB_SHA=$2; shift ;;
        --vendor-boot) [ $# -ge 2 ] || usage_error "--vendor-boot"; VENDOR_STATUS=$2; shift ;;
        --init-boot) [ $# -ge 2 ] || usage_error "--init-boot"; INIT_STATUS=$2; shift ;;
        --output) [ $# -ge 2 ] || usage_error "--output"; OUT=$2; shift ;;
        --force) FORCE=1 ;;
        --report-dir) [ $# -ge 2 ] || usage_error "--report-dir"; REPORT_DIR=$2; shift ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

REPORT_DIR=${REPORT_DIR:-"$WORK/boot/reports"}
mkdir -p "$REPORT_DIR" "$(dirname "$OUT")" || die 6 "sortie impossible"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/a71-package-XXXXXXXX") || die 6 "temporaire impossible"
trap 'rm -rf "$TMP"' EXIT

"$REPO_ROOT/scripts/check-boot-contract.sh" \
    --stock-boot "$STOCK" --analysis-dir "$ANALYSIS" \
    --uniloader "$UNILOADER" --manifest "$MANIFEST" \
    --boot-partition-size "${PART_SIZE:-0}" \
    --android-dtb-sha256 "$ANDROID_DTB_SHA" \
    --vendor-boot "$VENDOR_STATUS" --init-boot "$INIT_STATUS" \
    --report "$TMP/contract.txt" >"$TMP/contract.out" 2>&1 || true
STATUS=$(sed -n 's/^status=//p' "$TMP/contract.txt" | head -1)
{
    printf 'status=%s\n' "${STATUS:-BLOCKED_UNPROVEN_PARAMETER}"
    printf 'candidate_created=no\n'
    printf 'candidate=%s\n' "$(basename "$OUT")"
} >"$REPORT_DIR/package-status.txt"
[ "$STATUS" = "READY_TO_PACKAGE" ] || {
    say "contrat non READY : ${STATUS:-inconnu} ; aucun candidat cree"
    exit 1
}
[ -n "$PART_SIZE" ] || die 3 "taille de partition absente"
[ -f "$STOCK" ] && [ ! -L "$STOCK" ] || die 3 "stock boot absent"
[ -f "$UNILOADER" ] && [ ! -L "$UNILOADER" ] || die 3 "uniLoader absent"

if [ -e "$OUT" ]; then
    [ "$FORCE" = 1 ] || die 6 "candidat deja present (--force)"
    BACKUP="$OUT.pre-j5"
    [ ! -e "$BACKUP" ] || die 6 "sauvegarde deja presente"
    mv "$OUT" "$BACKUP" || die 6 "sauvegarde impossible"
fi
python3 "$REPO_ROOT/scripts/package_boot.py" "$STOCK" "$UNILOADER" "$OUT" ||
    die 4 "construction candidate impossible"
[ -f "$OUT" ] && [ ! -L "$OUT" ] || die 4 "candidat non regulier"
[ "$(stat -c '%s' "$OUT")" -le "$PART_SIZE" ] || die 5 "candidat > partition"

"$REPO_ROOT/scripts/analyze-stock-boot.sh" --input "$OUT" --output "$TMP/candidate-analysis" --force \
    >/dev/null 2>&1 || die 5 "reanalyse candidate impossible"
CA="$TMP/candidate-analysis/stock-boot-analysis.txt"
SA="$ANALYSIS/stock-boot-analysis.txt"
for key in header_version page_size kernel_addr ramdisk_size ramdisk_addr second_size second_addr tags_addr dtb_size dtb_addr name cmdline os_version avb_footer_present; do
    a=$(sed -n "s/^$key=//p" "$SA" | head -1)
    b=$(sed -n "s/^$key=//p" "$CA" | head -1)
    [ "$a" = "$b" ] || die 5 "champ $key modifie : $a -> $b"
done
CAND_SHA=$(sha256sum "$OUT" | awk '{print $1}')
CAND_SIZE=$(stat -c '%s' "$OUT")
{
    printf 'result=OK\n'
    printf 'name=%s\n' "$(basename "$OUT")"
    printf 'status=UNTESTED\n'
    printf 'candidate_size=%s\n' "$CAND_SIZE"
    printf 'candidate_sha256=%s\n' "$CAND_SHA"
    printf 'boot_partition_size=%s\n' "$PART_SIZE"
    printf 'stock_sha256=%s\n' "$(sha256sum "$STOCK" | awk '{print $1}')"
    printf 'uniloader_sha256=%s\n' "$(sha256sum "$UNILOADER" | awk '{print $1}')"
    printf 'structural_fields=identical\n'
    printf 'flashable=no\n'
    printf 'runtime_status=not_tested\n'
    printf 'validation_status=provisional\n'
} >"$REPORT_DIR/candidate.txt"
{
    printf 'status=%s\n' "$STATUS"
    printf 'candidate_created=yes\n'
    printf 'candidate=%s\n' "$(basename "$OUT")"
} >"$REPORT_DIR/package-status.txt"
say "candidat UNTESTED cree : $OUT"
say "sha256 : $CAND_SHA"
exit 0
