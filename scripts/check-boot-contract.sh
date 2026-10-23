#!/usr/bin/env bash
# shellcheck shell=bash
#
# check-boot-contract.sh - validateur fail-closed du contrat boot (J4).
#
# Compare le boot.img stock analyse, uniLoader, le manifeste et la taille de
# partition fournie par l'utilisateur. N'invente aucun parametre.
#
# Resultats : READY_TO_PACKAGE, BLOCKED_MISSING_STOCK_BOOT,
# BLOCKED_MISSING_PARTITION_SIZE, BLOCKED_UNSUPPORTED_HEADER, BLOCKED_AVB,
# BLOCKED_SIZE, BLOCKED_INCOMPATIBLE_FORMAT, BLOCKED_UNPROVEN_PARAMETER.
#
# Codes : 0 statut produit, 2 usage, 3 erreur interne, 5 rapport impossible.

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
REPORT="$WORK/boot/reports/boot-contract.txt"
ANDROID_DTB_SHA=""
VENDOR_STATUS="unknown"
INIT_STATUS="unknown"

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() { say "$1"; exit 2; }

usage() {
    cat <<EOF
$PROG - contrat boot (lecture seule)

Usage
  $PROG [--stock-boot FILE] [--analysis-dir DIR] [--uniloader FILE]
        [--manifest FILE] [--boot-partition-size N] [--report FILE]
        [--android-dtb-sha256 SHA] [--vendor-boot STATUS] [--init-boot STATUS]

La taille de partition boot est obligatoire pour un resultat READY.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --stock-boot) [ $# -ge 2 ] || usage_error "--stock-boot attend un fichier"; STOCK=$2; shift ;;
        --analysis-dir) [ $# -ge 2 ] || usage_error "--analysis-dir attend un repertoire"; ANALYSIS=$2; shift ;;
        --uniloader) [ $# -ge 2 ] || usage_error "--uniloader attend un fichier"; UNILOADER=$2; shift ;;
        --manifest) [ $# -ge 2 ] || usage_error "--manifest attend un fichier"; MANIFEST=$2; shift ;;
        --boot-partition-size) [ $# -ge 2 ] || usage_error "--boot-partition-size attend un entier"; PART_SIZE=$2; shift ;;
        --report) [ $# -ge 2 ] || usage_error "--report attend un fichier"; REPORT=$2; shift ;;
        --android-dtb-sha256) [ $# -ge 2 ] || usage_error "--android-dtb-sha256 attend un hash"; ANDROID_DTB_SHA=$2; shift ;;
        --vendor-boot) [ $# -ge 2 ] || usage_error "--vendor-boot attend not_required|required|unknown"; VENDOR_STATUS=$2; shift ;;
        --init-boot) [ $# -ge 2 ] || usage_error "--init-boot attend not_required|required|unknown"; INIT_STATUS=$2; shift ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

mkdir -p "$(dirname "$REPORT")" || exit 5
TMP=$(mktemp -d "${TMPDIR:-/tmp}/a71-contract-XXXXXXXX") || exit 5
trap 'rm -rf "$TMP"' EXIT

STATUS=""
DETAIL=""

write_report() {
    {
        printf 'status=%s\n' "$1"
        printf 'detail=%s\n' "$2"
        printf 'stock_boot=%s\n' "$(basename "$STOCK")"
        printf 'stock_present=%s\n' "$([ -f "$STOCK" ] && echo yes || echo no)"
        printf 'partition_size=%s\n' "${PART_SIZE:-not_provided}"
        printf 'runtime_status=not_tested\n'
        printf 'validation_status=provisional\n'
    } >"$REPORT"
    printf 'STATUS=%s\n' "$1"
    printf 'DETAIL=%s\n' "$2"
}

if [ ! -f "$STOCK" ] || [ -L "$STOCK" ]; then
    write_report "BLOCKED_MISSING_STOCK_BOOT" "boot.img stock absent ou symlink"
    exit 0
fi
if [ -z "$PART_SIZE" ]; then
    write_report "BLOCKED_MISSING_PARTITION_SIZE" "taille de partition boot non fournie"
    exit 0
fi
case "$PART_SIZE" in '' | *[!0-9]*) write_report "BLOCKED_MISSING_PARTITION_SIZE" "taille de partition non numerique"; exit 0 ;; esac
[ "$PART_SIZE" -gt 0 ] || { write_report "BLOCKED_MISSING_PARTITION_SIZE" "taille de partition nulle"; exit 0; }

if [ ! -d "$ANALYSIS" ] || [ ! -f "$ANALYSIS/stock-boot-analysis.txt" ]; then
    mkdir -p "$(dirname "$ANALYSIS")"
    "$REPO_ROOT/scripts/analyze-stock-boot.sh" --input "$STOCK" --output "$ANALYSIS" --force >/dev/null 2>&1 ||
        { write_report "BLOCKED_INCOMPATIBLE_FORMAT" "analyse stock impossible"; exit 0; }
fi
A="$ANALYSIS/stock-boot-analysis.txt"
g() { sed -n "s/^$1=//p" "$A" | head -1; }

HV=$(g header_version)
PAGE=$(g page_size)
KS=$(g kernel_size)
RS=$(g ramdisk_size)
DS=$(g dtb_size)
CL=$(g cmdline)
AVB=$(g avb_footer_present)
DTB_SHA=$(g dtb_sha256)
KERNEL_SHA=$(g kernel_sha256)
[ -n "$HV" ] || { write_report "BLOCKED_INCOMPATIBLE_FORMAT" "analyse incomplète"; exit 0; }

case "$HV" in
    0 | 1 | 2) ;;
    *) write_report "BLOCKED_UNSUPPORTED_HEADER" "header Android v$HV non supporte par le contrat Samsung"; exit 0 ;;
esac
[ "$AVB" = "yes" ] && { write_report "BLOCKED_AVB" "footer AVB detecte : coexistence non prouvee"; exit 0; }
[ "$DS" = "not_present" ] && { write_report "BLOCKED_UNPROVEN_PARAMETER" "DTB Android absent du stock boot"; exit 0; }
[ "$CL" = "not_present" ] && { write_report "BLOCKED_UNPROVEN_PARAMETER" "cmdline stock absente"; exit 0; }
case "$KS" in ''|*[!0-9]*) write_report "BLOCKED_UNPROVEN_PARAMETER" "kernel_size stock invalide"; exit 0 ;; esac
case "$RS" in ''|*[!0-9]*) write_report "BLOCKED_UNPROVEN_PARAMETER" "ramdisk_size stock invalide"; exit 0 ;; esac
[ "$KS" -gt 0 ] && [ "$RS" -gt 0 ] || { write_report "BLOCKED_UNPROVEN_PARAMETER" "kernel/ramdisk stock vide"; exit 0; }
TOTAL_END=$(g total_end); FILE_SIZE=$(g file_size)
case "$TOTAL_END:$FILE_SIZE" in *[!0-9:]*) write_report "BLOCKED_UNPROVEN_PARAMETER" "bornes stock invalides"; exit 0 ;; esac
TRAILING=$((FILE_SIZE - TOTAL_END))
[ "$TRAILING" -ge 0 ] || { write_report "BLOCKED_UNPROVEN_PARAMETER" "bornes stock negatives"; exit 0; }
[ "$TRAILING" -eq 0 ] || { write_report "BLOCKED_UNPROVEN_PARAMETER" "donnees de queue non prouvees ($TRAILING octets)"; exit 0; }
if [ -n "$ANDROID_DTB_SHA" ]; then
    [ "$DTB_SHA" = "$ANDROID_DTB_SHA" ] ||
        { write_report "BLOCKED_UNPROVEN_PARAMETER" "DTB Android non concordant"; exit 0; }
else
    write_report "BLOCKED_UNPROVEN_PARAMETER" "identite du DTB Android non fournie (--android-dtb-sha256)"; exit 0
fi

# Parametres valides du manifeste : aucun TODO accepte.
MAN=$(python3 - "$MANIFEST" <<'PY'
import re,sys
text=open(sys.argv[1],encoding='utf-8',errors='replace').read().splitlines()
section=None
vals={}
for line in text:
    if not line.strip() or line.lstrip().startswith('#'): continue
    if line.strip()=='boot_image:':
        section='boot_image'
    elif line.strip()=='validated:':
        section='boot_image.validated'
    elif line and not line.startswith(' '):
        section=None
    m=re.match(r'^  ([a-z_]+):\s*(.*)$', line)
    if m and section=='boot_image':
        vals[m.group(1)]=m.group(2).strip().strip('"')
    m=re.match(r'^    ([a-z_]+):\s*(.*)$', line)
    if m and section=='boot_image.validated':
        vals[m.group(1)]=m.group(2).strip().strip('"')
for k in ('validation_status','header_version','page_size','kernel_addr','ramdisk_addr','tags_addr','dtb_addr','cmdline','boot_partition_size'):
    print('%s=%s' % (k, vals.get(k,'')))
PY
)
echo "$MAN" >"$TMP/manifest-fields"
bad=0
while IFS='=' read -r k v; do
    case "$v" in '' | TODO_*) bad=1 ;; esac
done <<<"$MAN"
[ "$bad" = 0 ] || { write_report "BLOCKED_UNPROVEN_PARAMETER" "boot_image.validated contient un TODO"; exit 0; }
MAN_VALIDATION=$(printf '%s\n' "$MAN" | sed -n 's/^validation_status=//p')
MAN_HV=$(printf '%s\n' "$MAN" | sed -n 's/^header_version=//p')
MAN_PAGE=$(printf '%s\n' "$MAN" | sed -n 's/^page_size=//p')
MAN_CMD=$(printf '%s\n' "$MAN" | sed -n 's/^cmdline=//p')
MAN_BOOT_SIZE=$(printf '%s\n' "$MAN" | sed -n 's/^boot_partition_size=//p')
[ "$MAN_VALIDATION" = "validated" ] || { write_report "BLOCKED_UNPROVEN_PARAMETER" "boot_image.validation_status != validated"; exit 0; }
[ "$MAN_HV" = "$HV" ] || { write_report "BLOCKED_UNPROVEN_PARAMETER" "header_version manifeste != stock"; exit 0; }
[ "$MAN_PAGE" = "$PAGE" ] || { write_report "BLOCKED_UNPROVEN_PARAMETER" "page_size manifeste != stock"; exit 0; }
[ "$MAN_CMD" = "$CL" ] || { write_report "BLOCKED_UNPROVEN_PARAMETER" "cmdline manifeste != stock"; exit 0; }
[ "$MAN_BOOT_SIZE" = "$PART_SIZE" ] || { write_report "BLOCKED_UNPROVEN_PARAMETER" "boot_partition_size manifeste != argument"; exit 0; }
for key in kernel_addr ramdisk_addr tags_addr dtb_addr; do
    mv=$(printf '%s\n' "$MAN" | sed -n "s/^$key=//p")
    sv=$(g "$key")
    [ "$mv" = "$sv" ] || { write_report "BLOCKED_UNPROVEN_PARAMETER" "$key manifeste != stock"; exit 0; }
done

[ -f "$UNILOADER" ] && [ ! -L "$UNILOADER" ] ||
    { write_report "BLOCKED_UNPROVEN_PARAMETER" "uniLoader absent"; exit 0; }
UL_TYPE=$(file -b "$UNILOADER")
case "$UL_TYPE" in *"Linux kernel ARM64 boot executable Image"*) ;; *) write_report "BLOCKED_INCOMPATIBLE_FORMAT" "uniLoader n'est pas une Image ARM64"; exit 0 ;; esac
UL_SIZE=$(stat -c '%s' "$UNILOADER")
STOCK_SIZE=$(g file_size)
CAND_SIZE=$((STOCK_SIZE - KS + UL_SIZE))
if [ "$CAND_SIZE" -gt "$PART_SIZE" ]; then
    write_report "BLOCKED_SIZE" "candidat estime $CAND_SIZE > partition $PART_SIZE"
    exit 0
fi

# vendor_boot/init_boot : seulement une preuve explicite permet READY.
for pair in "vendor_boot:$VENDOR_STATUS" "init_boot:$INIT_STATUS"; do
    name=${pair%%:*}; value=${pair#*:}
    case "$value" in
        not_required) ;;
        required) write_report "BLOCKED_INCOMPATIBLE_FORMAT" "$name requis par le firmware"; exit 0 ;;
        *) write_report "BLOCKED_UNPROVEN_PARAMETER" "$name non determine"; exit 0 ;;
    esac
done

write_report "READY_TO_PACKAGE" "contrat prouve : header v$HV, DTB Android concordant, taille compatible"
exit 0
