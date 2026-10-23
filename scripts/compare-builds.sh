#!/usr/bin/env bash
# shellcheck shell=bash
#
# compare-builds.sh - compare deux sorties de scripts/kernel-build.sh et produit
#                     un rapport de reproductibilite deterministe.
#
# Usage :
#   ./scripts/compare-builds.sh --a DIR --b DIR [--output FILE] [--help]
#
# Codes de sortie :
#   0 artefacts identiques
#   1 artefacts differents
#   2 erreur d'usage
#   3 sortie de build invalide (rapport ou artefact manquant)

set -Eeuo pipefail

PROG=$(basename "$0")
EXIT_OK=0
EXIT_DIFF=1
EXIT_USAGE=2
EXIT_INVALID=3

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() { say "$1"; printf 'Utilise --help.\n' >&2; exit "$EXIT_USAGE"; }

usage() {
    cat <<EOU
$PROG - comparaison de deux builds noyau

Usage
  $PROG --a DIR --b DIR [--output FILE]

Options
  --a DIR       premiere sortie de kernel-build.sh
  --b DIR       seconde sortie
  --output FILE rapport (defaut : <a>/reports/reproducibility.txt)
  -h, --help    cette aide

Codes : 0 identiques, 1 differents, 2 usage, 3 sortie invalide
EOU
}

A=""; B=""; OUT=""
SEEN=" "
mark_opt() { case "$SEEN" in *" $1 "*) usage_error "option repetee : --$1" ;; esac; SEEN="$SEEN$1 "; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit "$EXIT_OK" ;;
        --a) mark_opt a; [ $# -ge 2 ] || usage_error "--a attend un repertoire"; A=$2; shift ;;
        --b) mark_opt b; [ $# -ge 2 ] || usage_error "--b attend un repertoire"; B=$2; shift ;;
        --output) mark_opt output; [ $# -ge 2 ] || usage_error "--output attend un fichier"; OUT=$2; shift ;;
        --a=*) mark_opt a; A=${1#--a=} ;;
        --b=*) mark_opt b; B=${1#--b=} ;;
        --output=*) mark_opt output; OUT=${1#--output=} ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

[ -n "$A" ] || usage_error "--a est obligatoire"
[ -n "$B" ] || usage_error "--b est obligatoire"
[ -d "$A" ] || { say "sortie A absente"; exit "$EXIT_INVALID"; }
[ -d "$B" ] || { say "sortie B absente"; exit "$EXIT_INVALID"; }
for d in "$A" "$B"; do
    [ -f "$d/build-summary.txt" ] || { say "build-summary.txt absent dans $(basename "$d")"; exit "$EXIT_INVALID"; }
done
[ -n "$OUT" ] || OUT="$A/reports/reproducibility.txt"
[ -d "$(dirname "$OUT")" ] || { say "repertoire du rapport absent"; exit "$EXIT_INVALID"; }

field() { sed -n "s/^$2=//p" "$1/build-summary.txt" | head -1; }

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

A_IMG=$(field "$A" image_sha256)
B_IMG=$(field "$B" image_sha256)
A_DTB=$(field "$A" dtb_sha256)
B_DTB=$(field "$B" dtb_sha256)
A_CFG=$(field "$A" config_sha256_final)
B_CFG=$(field "$B" config_sha256_final)
A_REL=$(field "$A" built_release)
B_REL=$(field "$B" built_release)
A_N=$(field "$A" module_count)
B_N=$(field "$B" module_count)
A_DIR=$(field "$A" module_release_directory)
B_DIR=$(field "$B" module_release_directory)

# --- modules : arborescence relative + hash de chaque fichier --------------
list_modules() {
    # list_modules <sortie> <fichier> : lignes "<sha256>  <chemin relatif>"
    local root=$1 out=$2 dir
    dir=$(sed -n 's/^module_release_directory=//p' "$root/build-summary.txt" | head -1)
    : >"$out"
    [ -n "$dir" ] && [ -d "$root/$dir" ] || return 0
    ( cd "$root/$dir" && find . -type f -name '*.ko*' -print0 2>/dev/null |
        sort -z | xargs -0 -r sha256sum ) >"$out"
}

list_modules "$A" "$A/reports/modules-a.sha256"
list_modules "$B" "$B/reports/modules-b.sha256"
LIST_A="$A/reports/modules-a.sha256"
LIST_B="$B/reports/modules-b.sha256"

MOD_DIFF="$A/reports/modules.diff"
diff -u --label modules-a --label modules-b "$LIST_A" "$LIST_B" >"$MOD_DIFF" 2>/dev/null || true
MOD_TREE_MATCH="no"
if [ ! -s "$MOD_DIFF" ]; then MOD_TREE_MATCH="yes"; fi

img_match="no"; [ -n "$A_IMG" ] && [ "$A_IMG" = "$B_IMG" ] && img_match="yes"
dtb_match="no"; [ -n "$A_DTB" ] && [ "$A_DTB" = "$B_DTB" ] && dtb_match="yes"
cfg_match="no"; [ -n "$A_CFG" ] && [ "$A_CFG" = "$B_CFG" ] && cfg_match="yes"
rel_match="no"; [ -n "$A_REL" ] && [ "$A_REL" = "$B_REL" ] && rel_match="yes"
n_match="no"; [ -n "$A_N" ] && [ "$A_N" = "$B_N" ] && n_match="yes"

overall="no"
if [ "$img_match" = "yes" ] && [ "$dtb_match" = "yes" ] && [ "$MOD_TREE_MATCH" = "yes" ] &&
    [ "$cfg_match" = "yes" ] && [ "$rel_match" = "yes" ] && [ "$n_match" = "yes" ]; then
    overall="yes"
fi

{
    printf '# reproductibilite de deux builds noyau\n'
    printf 'build_a_result=%s\n' "$(field "$A" result)"
    printf 'build_b_result=%s\n' "$(field "$B" result)"
    printf 'image_sha256_a=%s\n' "$A_IMG"
    printf 'image_sha256_b=%s\n' "$B_IMG"
    printf 'image_match=%s\n' "$img_match"
    printf 'dtb_sha256_a=%s\n' "$A_DTB"
    printf 'dtb_sha256_b=%s\n' "$B_DTB"
    printf 'dtb_match=%s\n' "$dtb_match"
    printf 'module_count_a=%s\n' "$A_N"
    printf 'module_count_b=%s\n' "$B_N"
    printf 'module_count_match=%s\n' "$n_match"
    printf 'module_tree_match=%s\n' "$MOD_TREE_MATCH"
    printf 'config_sha256_a=%s\n' "$A_CFG"
    printf 'config_sha256_b=%s\n' "$B_CFG"
    printf 'config_match=%s\n' "$cfg_match"
    printf 'release_a=%s\n' "$A_REL"
    printf 'release_b=%s\n' "$B_REL"
    printf 'release_match=%s\n' "$rel_match"
    printf 'source_date_epoch=%s\n' "$(field "$A" source_date_epoch)"
    printf 'kbuild_build_timestamp=%s\n' "$(field "$A" kbuild_build_timestamp)"
    printf 'kbuild_build_user=%s\n' "$(field "$A" kbuild_build_user)"
    printf 'kbuild_build_host=%s\n' "$(field "$A" kbuild_build_host)"
    printf 'overall_reproducible=%s\n' "$overall"
} >"$OUT.tmp"
mv -f "$OUT.tmp" "$OUT"

say "rapport : $OUT (overall_reproducible=$overall)"
[ "$overall" = "yes" ] && exit "$EXIT_OK"
exit "$EXIT_DIFF"
