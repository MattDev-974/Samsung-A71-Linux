#!/usr/bin/env bash
# shellcheck shell=bash
#
# tests/phase1/run-kernel-build-test.sh - test d'INTEGRATION LOURD.
#
# Non lance par defaut : exige A71_RUN_KERNEL_BUILD=1.
# Il compile reellement le noyau (Image + modules + DTB) : plusieurs minutes,
# plusieurs Go d'espace, et des prerequis hote stricts.
#
# Prerequis verifiables par : ./scripts/kernel-build.sh --help
#   bash make git sha256sum find grep sed awk bc bison flex openssl perl
#   python3 rsync file readelf  +  dtc OU fdtdump  (+ pahole si BTF)
#
# Contraintes externes a ce test :
#   * l'arbre noyau et la sortie doivent etre dans un chemin SANS espace
#     (le systeme de build du noyau refuse les espaces : Makefile:217) ;
#   * aucun acces reseau n'est effectue ici.
#
# Usage :
#   A71_RUN_KERNEL_BUILD=1 ./tests/phase1/run-kernel-build-test.sh
#
# Variables optionnelles :
#   A71_KERNEL_SOURCE   arbre noyau (defaut : work/src/kernel-6.18)
#   A71_CONFIG          configuration (defaut : work/config/final.config)
#   A71_TOOLCHAIN_ROOT  racine toolchain (defaut : work/toolchain/toolchain-root)
#   A71_BUILD_OUTPUT    sortie (defaut : work/kernel-build)
#   A71_JOBS            parallelisme (defaut : nproc)

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

if [ "${A71_RUN_KERNEL_BUILD:-0}" != "1" ]; then
    printf 'test d integration ignore (definir A71_RUN_KERNEL_BUILD=1 pour l executer)\n'
    exit 0
fi

KERNEL_SOURCE=${A71_KERNEL_SOURCE:-$ROOT/../work/src/kernel-6.18}
CONFIG_FILE=${A71_CONFIG:-$ROOT/../work/config/final.config}
TOOLCHAIN_ROOT=${A71_TOOLCHAIN_ROOT:-$ROOT/../work/toolchain/toolchain-root}
OUTPUT=${A71_BUILD_OUTPUT:-$ROOT/../work/kernel-build}
JOBS=${A71_JOBS:-$(nproc 2>/dev/null || echo 2)}

MANIFEST_BEFORE=$(sha256sum "$ROOT/manifest.yaml" | cut -d' ' -f1)

fail() {
    printf 'ECHEC: %s\n' "$*" >&2
    exit 1
}

printf '== test d integration : compilation noyau ==\n'
printf 'source    : %s\n' "$KERNEL_SOURCE"
printf 'config    : %s\n' "$CONFIG_FILE"
printf 'toolchain : %s\n' "$TOOLCHAIN_ROOT"
printf 'sortie    : %s\n' "$OUTPUT"
printf 'jobs      : %s\n' "$JOBS"

# --- prerequis de l'environnement ----------------------------------------
[ -d "$KERNEL_SOURCE/.git" ] || fail "arbre noyau absent : $KERNEL_SOURCE"
[ -f "$CONFIG_FILE" ] || fail "configuration absente : $CONFIG_FILE"
[ -d "$TOOLCHAIN_ROOT/bin" ] || fail "toolchain absente : $TOOLCHAIN_ROOT"
for t in bc dtc fdtdump; do
    if [ "$t" = "bc" ]; then
        command -v bc >/dev/null || fail "prerequis de COMPILATION absent : bc (kernel/Kbuild:21 genere include/generated/timeconst.h avec bc)"
    else
        command -v dtc >/dev/null || command -v fdtdump >/dev/null || fail "prerequis de VALIDATION post-build absent : dtc ou fdtdump (le noyau a son propre DTC, mais la validation independante du DTB est impossible)"
    fi
done

# --- build ----------------------------------------------------------------
printf '\n== compilation ==\n'
"$ROOT/scripts/kernel-build.sh" \
    --kernel-source "$KERNEL_SOURCE" \
    --config "$CONFIG_FILE" \
    --toolchain-root "$TOOLCHAIN_ROOT" \
    --output "$OUTPUT" \
    --requirements "$ROOT/configs/a71-required-symbols.txt" \
    --jobs "$JOBS"
rc=$?
[ "$rc" -eq 0 ] || fail "kernel-build.sh a retourne $rc"

# --- verifications --------------------------------------------------------
printf '\n== verifications ==\n'
SUM="$OUTPUT/build-summary.txt"
[ -f "$SUM" ] || fail "build-summary.txt absent"

grep -qx 'result=OK' "$SUM" || fail "result != OK"
grep -qx 'built_release=6.18.0-rc1-a71+' "$SUM" || fail "built_release inattendue"
grep -qx 'release_match=oui' "$SUM" || fail "release_match != oui"
grep -qx 'requirements_failures=0' "$SUM" || fail "exigences en echec"
grep -qx 'runtime=not_tested' "$SUM" || fail "runtime != not_tested"
grep -qx 'validation=provisional' "$SUM" || fail "validation != provisional"

[ -s "$OUTPUT/artifacts/Image" ] || fail "Image absente"
[ -s "$OUTPUT/artifacts/sm7150-samsung-a715f.dtb" ] || fail "DTB A71 absent"
[ -d "$OUTPUT/modules-install/lib/modules/6.18.0-rc1-a71+" ] || fail "modules absents"

mods=$(find "$OUTPUT/modules-install" -type f -name '*.ko*' | wc -l)
[ "$mods" -gt 0 ] || fail "aucun module produit"

for f in logs/olddefconfig.log logs/build.log logs/modules-install.log \
    reports/config-input.config reports/config-normalized.config \
    reports/requirements-input.txt reports/requirements-normalized.txt \
    reports/requirements-final.txt reports/toolchain.txt reports/image.txt \
    reports/dtb.txt reports/modules.txt reports/provenance.json; do
    [ -f "$OUTPUT/$f" ] || fail "rapport manquant : $f"
done
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUTPUT/reports/provenance.json" ||
    fail "provenance.json invalide"

# aucune construction hors perimetre
find "$OUTPUT" \( -name 'boot.img' -o -name 'initramfs*' -o -name 'rootfs*' \) | grep -q . &&
    fail "artefact hors perimetre detecte"

# manifeste inchange
MANIFEST_AFTER=$(sha256sum "$ROOT/manifest.yaml" | cut -d' ' -f1)
[ "$MANIFEST_BEFORE" = "$MANIFEST_AFTER" ] || fail "manifest.yaml modifie"

printf '\nOK : %s\n' "$(grep -E '^(built_release|module_count|image_sha256|dtb_sha256)=' "$SUM" | tr '\n' ' ')"
printf 'modules : %s\n' "$mods"
exit 0
