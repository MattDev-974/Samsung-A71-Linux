#!/usr/bin/env bash
# shellcheck shell=bash
#
# kernel-build.sh - compilation REELLE du noyau, des modules et des DTB avec la
#                   toolchain Bootlin validee. Aucun rootfs, aucun initramfs,
#                   aucun boot.img, aucun montage, aucun flash.
#
# Usage :
#   ./scripts/kernel-build.sh --kernel-source DIR --config FILE \
#       --toolchain-root DIR --output DIR [--requirements FILE] \
#       [--jobs N] [--force]
#
# Codes de sortie :
#    0 compilation et controles reussis
#    2 erreur d'usage
#    3 source noyau ou commit invalide
#    4 configuration ou exigences invalides
#    5 chemin ou repertoire de sortie dangereux
#    6 toolchain invalide
#    7 prerequis hote absent
#    8 echec de compilation ou de make
#    9 artefact produit absent ou invalide
#   10 release ou exigences finales incoherentes

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PROG=$(basename "$0")

# shellcheck source=scripts/common.sh
. "$SCRIPT_DIR/common.sh"
a71_install_traps

EXIT_OK=0
EXIT_USAGE=2
EXIT_SOURCE=3
EXIT_CONFIG=4
EXIT_OUTPUT=5
EXIT_TOOLCHAIN=6
EXIT_HOST=7
EXIT_BUILD=8
EXIT_ARTIFACT=9
EXIT_COHERENCE=10

umask 077

# Etats explicites : une etape non atteinte ne doit JAMAIS apparaitre comme
# "failed". Valeurs autorisees : not_started, running, completed, failed,
# not_checked, match, mismatch, not_produced.
BUILD_STEP="init"
ST_REQ_INPUT="not_started"
ST_OLDDEFCONFIG="not_started"
ST_REQ_NORMALIZED="not_started"
ST_KRELEASE_BEFORE="not_checked"
ST_BUILD="not_started"
ST_MODULES_INSTALL="not_started"
ST_KRELEASE_AFTER="not_checked"
ST_ARTIFACTS="not_started"
ST_REQ_FINAL="not_started"
RELEASE_MATCH="not_checked"
CONFIG_UNCHANGED="not_checked"
PAHOLE_REQUIREMENT="not_checked"
REQ_TOTAL="not_checked"
REQ_FAILS="not_checked"
MODULE_COUNT="not_checked"
MOD_KO="not_checked"
MOD_GZ="not_checked"
MOD_XZ="not_checked"
MOD_ZST="not_checked"
MODULE_ELF="not_checked"
MODULE_COMPRESSION="not_checked"
IMAGE_SIZE="not_produced"
DTB_SIZE="not_produced"
BUILT_RELEASE="not_produced"
OUT_DIR=""
LOGS=""
REPORTS=""
KBUILD=""

MAKE_EXIT=""
RESULT="FAILED"

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() { say "$1"; printf 'Utilise --help.\n' >&2; deliberate_exit "$EXIT_USAGE"; }

usage() {
    cat <<EOF
$PROG - compilation du noyau, des modules et des DTB (sans rootfs)

Usage
  $PROG --kernel-source DIR --config FILE --toolchain-root DIR --output DIR \\
        [--requirements FILE] [--jobs N] [--force]

Options
  --kernel-source DIR  arbre noyau (commit impose par le manifeste)
  --config FILE        configuration fusionnee a utiliser
  --toolchain-root DIR racine de la toolchain (contenant bin/)
  --output DIR         repertoire de sortie (kbuild/, artifacts/, reports/, logs/)
  --requirements FILE  exigences (defaut : configs/a71-required-symbols.txt)
  --jobs N             taches paralleles, entier 1..128
  --force              accepte une sortie non vide et la recree
  -h, --help           affiche cette aide

Codes de sortie
  0 succes   2 usage   3 source   4 config   5 sortie
  6 toolchain   7 prerequis hote   8 build   9 artefact   10 coherence
EOF
}

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
KERNEL_SOURCE=""
CONFIG_FILE=""
TOOLCHAIN_ROOT=""
OUT_DIR=""
REQ_FILE=""
JOBS=""
JOBS_GIVEN=0
FORCE=0
SEEN=" "

mark_opt() {
    case "$SEEN" in
        *" $1 "*) usage_error "option repetee : --$1" ;;
    esac
    SEEN="$SEEN$1 "
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit "$EXIT_OK" ;;
        --kernel-source) mark_opt kernel-source; [ $# -ge 2 ] || usage_error "--kernel-source attend un repertoire"; KERNEL_SOURCE=$2; shift ;;
        --config) mark_opt config; [ $# -ge 2 ] || usage_error "--config attend un fichier"; CONFIG_FILE=$2; shift ;;
        --toolchain-root) mark_opt toolchain-root; [ $# -ge 2 ] || usage_error "--toolchain-root attend un repertoire"; TOOLCHAIN_ROOT=$2; shift ;;
        --output) mark_opt output; [ $# -ge 2 ] || usage_error "--output attend un repertoire"; OUT_DIR=$2; shift ;;
        --requirements) mark_opt requirements; [ $# -ge 2 ] || usage_error "--requirements attend un fichier"; REQ_FILE=$2; shift ;;
        --jobs) mark_opt jobs; [ $# -ge 2 ] || usage_error "--jobs attend une valeur"; JOBS=$2; JOBS_GIVEN=1; shift ;;
        --force) mark_opt force; FORCE=1 ;;
        --force=*) usage_error "--force ne prend pas de valeur" ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

[ -n "$KERNEL_SOURCE" ] || usage_error "--kernel-source est obligatoire"
[ -n "$CONFIG_FILE" ] || usage_error "--config est obligatoire"
[ -n "$TOOLCHAIN_ROOT" ] || usage_error "--toolchain-root est obligatoire"
[ -n "$OUT_DIR" ] || usage_error "--output est obligatoire"
[ -n "$REQ_FILE" ] || REQ_FILE="$REPO_ROOT/configs/a71-required-symbols.txt"

if [ "$JOBS_GIVEN" = "1" ]; then
    if ! JOBS=$(validate_jobs "$JOBS"); then
        deliberate_exit "$EXIT_USAGE"
    fi
else
    JOBS=$(nproc 2>/dev/null || echo 2)
    case "$JOBS" in '' | *[!0-9]*) JOBS=2 ;; esac
    [ "$JOBS" -ge 1 ] || JOBS=1
    [ "$JOBS" -le 128 ] || JOBS=128
fi

# --------------------------------------------------------------------------
# Aides
# --------------------------------------------------------------------------
# Execute une commande dont l'echec est ATTENDU et analyse : le trap ERR est
# retire le temps de l'appel (sinon il sortirait avant la capture du code).
# Le code de retour est expose via A71_LAST_RC : la fonction retourne TOUJOURS 0,
# sinon le "return <non nul>" declencherait lui-meme le trap ERR.
run_tolerant() {
    local rc
    trap - ERR
    set +e
    "$@"
    rc=$?
    set -e
    trap 'a71_on_error $? $LINENO "${BASH_SOURCE[0]:-}"' ERR
    A71_LAST_RC=$rc
    return 0
}

kb_release() {
    run_tolerant make -s "${MAKE_COMMON[@]}" kernelrelease 2>>"$LOGS/kernelrelease.log"
    [ "$A71_LAST_RC" -eq 0 ] || return 0
}

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Ecrit la synthese (utilisable en succes comme en echec)
write_summary() {
    local tmp
    [ -n "${REPORTS:-}" ] && [ -d "${REPORTS:-/nonexistent}" ] || return 0
    [ -n "${OUT_DIR:-}" ] && [ -d "${OUT_DIR:-/nonexistent}" ] || return 0
    tmp=$(mktemp "$REPORTS/.summary-XXXXXXXX") || return 0
    {
        printf 'result=%s\n' "$RESULT"
        printf 'failed_step=%s\n' "$BUILD_STEP"
        printf 'make_exit_code=%s\n' "${MAKE_EXIT:-none}"
        printf 'kernel_commit=%s\n' "${KERNEL_COMMIT:-inconnu}"
        printf 'kernel_branch=%s\n' "${KERNEL_BRANCH:-inconnu}"
        printf 'kernel_git_dirty=%s\n' "${GIT_DIRTY:-inconnu}"
        printf 'kernel_source_version=%s\n' "${SOURCE_VERSION:-inconnu}"
        printf 'expected_release=%s\n' "${EXPECTED_RELEASE:-inconnu}"
        printf 'calculated_release_before_build=%s\n' "${RELEASE_BEFORE:-not_checked}"
        printf 'built_release=%s\n' "$BUILT_RELEASE"
        printf 'release_match=%s\n' "$RELEASE_MATCH"
        printf 'config_sha256_input=%s\n' "${SHA_INPUT:-}"
        printf 'config_sha256_normalized=%s\n' "${SHA_NORMALIZED:-}"
        printf 'config_sha256_final=%s\n' "${SHA_FINAL:-}"
        printf 'config_unchanged_during_build=%s\n' "$CONFIG_UNCHANGED"
        printf 'requirements_total=%s\n' "$REQ_TOTAL"
        printf 'requirements_failures=%s\n' "$REQ_FAILS"
        printf 'toolchain_target=%s\n' "${TARGET:-inconnu}"
        printf 'toolchain_gcc_version=%s\n' "${GCC_VERSION:-inconnu}"
        printf 'cross_compile_basename=%s\n' "$(basename "${CROSS_COMPILE:-inconnu}")"
        printf 'jobs=%s\n' "$JOBS"
        printf 'source_date_epoch=%s\n' "${SOURCE_DATE_EPOCH:-not_checked}"
        printf 'kbuild_build_timestamp=%s\n' "${KBUILD_TIMESTAMP:-not_checked}"
        printf 'kbuild_build_user=a71-builder\n'
        printf 'kbuild_build_host=a71-build\n'
        printf 'reproducibility_policy=controlled\n'
        printf 'image_path=artifacts/Image\n'
        printf 'image_size=%s\n' "$IMAGE_SIZE"
        printf 'image_sha256=%s\n' "${IMAGE_SHA:-}"
        printf 'dtb_path=artifacts/sm7150-samsung-a715f.dtb\n'
        printf 'dtb_size=%s\n' "$DTB_SIZE"
        printf 'dtb_sha256=%s\n' "${DTB_SHA:-}"
        printf 'module_release_directory=%s\n' "${MODULE_DIR_REL:-}"
        printf 'module_count=%s\n' "$MODULE_COUNT"
        printf 'module_count_ko=%s\n' "$MOD_KO"
        printf 'module_count_gz=%s\n' "$MOD_GZ"
        printf 'module_count_xz=%s\n' "$MOD_XZ"
        printf 'module_count_zst=%s\n' "$MOD_ZST"
        printf 'module_elf_check=%s\n' "$MODULE_ELF"
        printf 'module_compression=%s\n' "${MODULE_COMPRESSION:-inconnu}"
        printf 'requirements_input=%s\n' "$ST_REQ_INPUT"
        printf 'olddefconfig=%s\n' "$ST_OLDDEFCONFIG"
        printf 'requirements_normalized=%s\n' "$ST_REQ_NORMALIZED"
        printf 'kernelrelease_before_build=%s\n' "$ST_KRELEASE_BEFORE"
        printf 'build=%s\n' "$ST_BUILD"
        printf 'modules_install=%s\n' "$ST_MODULES_INSTALL"
        printf 'kernelrelease_after_build=%s\n' "$ST_KRELEASE_AFTER"
        printf 'artifacts_validation=%s\n' "$ST_ARTIFACTS"
        printf 'requirements_final=%s\n' "$ST_REQ_FINAL"
        printf 'pahole_requirement=%s\n' "$PAHOLE_REQUIREMENT"
        printf 'runtime=not_tested\n'
        printf 'validation=provisional\n'
    } >"$tmp"
    mv -f "$tmp" "$OUT_DIR/build-summary.txt"
}

fail() {
    local code=$1 step=$2
    shift 2
    BUILD_STEP=$step
    RESULT="FAILED"
    # Seule l'etape nommee passe a "failed" ; les autres gardent leur etat.
    case "$step" in
        check-config-input) ST_REQ_INPUT="failed" ;;
        olddefconfig) ST_OLDDEFCONFIG="failed" ;;
        check-config-normalized) ST_REQ_NORMALIZED="failed" ;;
        kernelrelease) ST_KRELEASE_BEFORE="failed" ;;
        build) ST_BUILD="failed" ;;
        modules_install) ST_MODULES_INSTALL="failed" ;;
        release-check) ST_KRELEASE_AFTER="failed" ;;
        artifact-*) ST_ARTIFACTS="failed" ;;
        final-config) ST_REQ_FINAL="failed" ;;
    esac
    say "$*"
    write_summary || true
    deliberate_exit "$code"
}

# --------------------------------------------------------------------------
# 1. Source noyau
# --------------------------------------------------------------------------
BUILD_STEP="kernel-source"
[ -e "$KERNEL_SOURCE" ] || fail "$EXIT_SOURCE" "kernel-source" "source noyau absente"
[ -d "$KERNEL_SOURCE" ] || fail "$EXIT_SOURCE" "kernel-source" "source noyau n'est pas un repertoire"
[ -L "$KERNEL_SOURCE" ] && fail "$EXIT_SOURCE" "kernel-source" "source noyau est un lien symbolique"
KERNEL_SOURCE=$(cd "$KERNEL_SOURCE" && pwd -P)
case "$KERNEL_SOURCE" in
    *" "* | *:*)
        say "le systeme de build du noyau refuse les espaces et ':' (Makefile:217)"
        fail "$EXIT_SOURCE" "kernel-source" "chemin source avec espace ou ':'"
        ;;
esac
[ -d "$KERNEL_SOURCE/.git" ] || fail "$EXIT_SOURCE" "kernel-source" "source noyau non git"
[ -f "$KERNEL_SOURCE/Makefile" ] || fail "$EXIT_SOURCE" "kernel-source" "Makefile absent"
[ -f "$KERNEL_SOURCE/scripts/kconfig/merge_config.sh" ] || fail "$EXIT_SOURCE" "kernel-source" "scripts/kconfig/merge_config.sh absent"

EXPECTED_COMMIT=$(A71_MANIFEST="$MANIFEST" bash -c '. "$1/scripts/common.sh"; manifest_get "$A71_MANIFEST" kernel.commit' _ "$REPO_ROOT") ||
    fail "$EXIT_SOURCE" "kernel-source" "kernel.commit introuvable dans le manifeste"
KERNEL_BRANCH=$(A71_MANIFEST="$MANIFEST" bash -c '. "$1/scripts/common.sh"; manifest_get "$A71_MANIFEST" kernel.branch' _ "$REPO_ROOT" || true)
EXPECTED_RELEASE=$(A71_MANIFEST="$MANIFEST" bash -c '. "$1/scripts/common.sh"; manifest_get "$A71_MANIFEST" kernel.expected_release' _ "$REPO_ROOT") ||
    fail "$EXIT_SOURCE" "kernel-source" "kernel.expected_release introuvable"
SOURCE_VERSION=$(A71_MANIFEST="$MANIFEST" bash -c '. "$1/scripts/common.sh"; manifest_get "$A71_MANIFEST" kernel.source_version' _ "$REPO_ROOT" || echo inconnue)
MANIFEST_DTB=$(A71_MANIFEST="$MANIFEST" bash -c '. "$1/scripts/common.sh"; manifest_get "$A71_MANIFEST" kernel.dtb_output' _ "$REPO_ROOT") ||
    fail "$EXIT_SOURCE" "kernel-source" "kernel.dtb_output introuvable"
MANIFEST_DTS=$(A71_MANIFEST="$MANIFEST" bash -c '. "$1/scripts/common.sh"; manifest_get "$A71_MANIFEST" kernel.dts_source' _ "$REPO_ROOT") ||
    fail "$EXIT_SOURCE" "kernel-source" "kernel.dts_source introuvable"

KERNEL_COMMIT=$(git -C "$KERNEL_SOURCE" rev-parse HEAD 2>/dev/null || true)
[ -n "$KERNEL_COMMIT" ] || fail "$EXIT_SOURCE" "kernel-source" "HEAD du noyau illisible"
[ "$KERNEL_COMMIT" = "$EXPECTED_COMMIT" ] ||
    fail "$EXIT_SOURCE" "kernel-source" "commit noyau $KERNEL_COMMIT != attendu $EXPECTED_COMMIT"

if [ -n "$KERNEL_BRANCH" ] && git -C "$KERNEL_SOURCE" rev-parse --verify --quiet "origin/$KERNEL_BRANCH" >/dev/null 2>&1; then
    git -C "$KERNEL_SOURCE" merge-base --is-ancestor "$KERNEL_COMMIT" "origin/$KERNEL_BRANCH" 2>/dev/null ||
        fail "$EXIT_SOURCE" "kernel-source" "commit non atteignable depuis origin/$KERNEL_BRANCH"
fi

[ -f "$KERNEL_SOURCE/$MANIFEST_DTS" ] ||
    fail "$EXIT_SOURCE" "kernel-source" "DTS declare absent des sources : $MANIFEST_DTS"

dirty=$(git -C "$KERNEL_SOURCE" status --porcelain 2>/dev/null || true)
if [ -n "$dirty" ]; then
    GIT_DIRTY="oui"
    say "arbre noyau sale :"
    printf '%s\n' "$dirty" | awk '{print "  - " $2}' | head -20 >&2
    fail "$EXIT_SOURCE" "kernel-source" "arbre Git sale : commit non reproductible"
fi
GIT_DIRTY="non"

# --- metadonnees reproductibles -------------------------------------------
# Timestamp derive du COMMIT epingle (jamais la date courante).
SOURCE_DATE_EPOCH=$(git -C "$KERNEL_SOURCE" show -s --format=%ct "$KERNEL_COMMIT" 2>/dev/null || true)
case "$SOURCE_DATE_EPOCH" in
    '' | *[!0-9]*)
        fail "$EXIT_SOURCE" "source-timestamp" "timestamp du commit invalide (git show -s --format=%ct)"
        ;;
esac
[ "$SOURCE_DATE_EPOCH" -gt 0 ] ||
    fail "$EXIT_SOURCE" "source-timestamp" "timestamp du commit nul"
KBUILD_TIMESTAMP=$(LC_ALL=C TZ=UTC date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || true)
[ -n "$KBUILD_TIMESTAMP" ] ||
    fail "$EXIT_SOURCE" "source-timestamp" "conversion du timestamp impossible"
export SOURCE_DATE_EPOCH


# --------------------------------------------------------------------------
# 2. Configuration
# --------------------------------------------------------------------------
BUILD_STEP="config"
[ -e "$CONFIG_FILE" ] || fail "$EXIT_CONFIG" "config" "configuration absente"
[ -f "$CONFIG_FILE" ] || fail "$EXIT_CONFIG" "config" "configuration n'est pas un fichier regulier"
[ -L "$CONFIG_FILE" ] && fail "$EXIT_CONFIG" "config" "configuration est un lien symbolique"
[ -r "$CONFIG_FILE" ] || fail "$EXIT_CONFIG" "config" "configuration illisible"
[ -f "$REQ_FILE" ] || fail "$EXIT_CONFIG" "config" "exigences absentes : $(basename "$REQ_FILE")"

SHA_INPUT=$(sha_of "$CONFIG_FILE")
[ -n "$SHA_INPUT" ] || fail "$EXIT_CONFIG" "config" "SHA-256 de la configuration impossible"

# Controles explicites de la politique de boot (lecture texte, aucun source).
conf_has() {
    local want=$1
    grep -qxF -- "$want" "$CONFIG_FILE"
}
for want in 'CONFIG_LOCALVERSION="-a71"' 'CONFIG_LOCALVERSION_AUTO=n' 'CONFIG_DRM=y' 'CONFIG_DRM_SIMPLEDRM=y' 'CONFIG_DRM_MSM=m'; do
    case "$want" in
        'CONFIG_LOCALVERSION_AUTO=n')
            conf_has "$want" || grep -qxF -- '# CONFIG_LOCALVERSION_AUTO is not set' "$CONFIG_FILE" ||
                fail "$EXIT_CONFIG" "config" "configuration : LOCALVERSION_AUTO doit etre desactive"
            ;;
        *) conf_has "$want" || fail "$EXIT_CONFIG" "config" "configuration : '$want' attendu" ;;
    esac
done

# --------------------------------------------------------------------------
# 3. Toolchain
# --------------------------------------------------------------------------
BUILD_STEP="toolchain"
[ -d "$TOOLCHAIN_ROOT" ] || fail "$EXIT_TOOLCHAIN" "toolchain" "toolchain absente"
[ -L "$TOOLCHAIN_ROOT" ] && fail "$EXIT_TOOLCHAIN" "toolchain" "toolchain est un lien symbolique"
TOOLCHAIN_ROOT=$(cd "$TOOLCHAIN_ROOT" && pwd -P)
case "$TOOLCHAIN_ROOT" in
    *" "* | *:*)
        say "le systeme de build du noyau refuse les espaces et ':' (Makefile:217)"
        fail "$EXIT_TOOLCHAIN" "toolchain" "chemin toolchain avec espace ou ':'"
        ;;
esac
[ -d "$TOOLCHAIN_ROOT/bin" ] || fail "$EXIT_TOOLCHAIN" "toolchain" "bin/ absent de la toolchain"

declare -a TC_CAND=()
while IFS= read -r c; do
    [ -x "$c" ] || continue
    resolved=$(readlink -f "$c" 2>/dev/null || true)
    case "$resolved" in
        "$TOOLCHAIN_ROOT"/*) TC_CAND+=("$c") ;;
        *) say "candidat ignore (cible hors toolchain) : $(basename "$c")" ;;
    esac
done < <(find "$TOOLCHAIN_ROOT/bin" -maxdepth 1 \( -type f -o -type l \) -name '*-gcc' | sort)
[ "${#TC_CAND[@]}" -gt 0 ] || fail "$EXIT_TOOLCHAIN" "toolchain" "aucun compilateur *-gcc"

CC_ABS=""
BEST_LEN=-1
for c in "${TC_CAND[@]}"; do
    base=$(basename "$c")
    t=$("$c" -dumpmachine 2>/dev/null || true)
    case "$t" in aarch64*) ;; *) say "candidat non aarch64 ignore : $base ($t)"; continue ;; esac
    plen=${#base}
    if [ "$plen" -gt "$BEST_LEN" ]; then
        BEST_LEN=$plen
        CC_ABS=$c
    elif [ "$plen" -eq "$BEST_LEN" ] && [ "$(basename "$CC_ABS")" != "$base" ]; then
        fail "$EXIT_TOOLCHAIN" "toolchain" "ambiguite : $(basename "$CC_ABS") et $base de meme specificite"
    fi
done
[ -n "$CC_ABS" ] || fail "$EXIT_TOOLCHAIN" "toolchain" "aucun compilateur aarch64 valide"

TARGET=$("$CC_ABS" -dumpmachine 2>/dev/null || true)
case "$TARGET" in aarch64*) ;; *) fail "$EXIT_TOOLCHAIN" "toolchain" "cible non aarch64 : $TARGET" ;; esac
CROSS_COMPILE="${CC_ABS%gcc}"

for tool in gcc ld ar nm objcopy objdump strip readelf; do
    [ -x "${CROSS_COMPILE}${tool}" ] ||
        fail "$EXIT_TOOLCHAIN" "toolchain" "outil manquant : ${CROSS_COMPILE}${tool}"
done

GCC_VERSION=$("$CC_ABS" --version 2>/dev/null | head -1)
GCC_DUMPVERSION=$("$CC_ABS" -dumpversion 2>/dev/null || true)
SYSROOT=$("$CC_ABS" -print-sysroot 2>/dev/null || true)
CC_FILE=$(LC_ALL=C file -Lb "$(readlink -f "$CC_ABS")" 2>/dev/null || echo inconnu)


# --------------------------------------------------------------------------
# 5. Securite de la sortie
# --------------------------------------------------------------------------
BUILD_STEP="output"
case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="$PWD/$OUT_DIR" ;;
esac
[ -L "$OUT_DIR" ] && fail "$EXIT_OUTPUT" "output" "sortie est un lien symbolique"
mkdir -p "$OUT_DIR" || fail "$EXIT_OUTPUT" "output" "creation de la sortie impossible"
OUT_DIR=$(cd "$OUT_DIR" && pwd -P)
case "$OUT_DIR" in
    /) fail "$EXIT_OUTPUT" "output" "sortie = /" ;;
    *" "* | *:*)
        say "le systeme de build du noyau refuse les espaces et ':' (Makefile:217)"
        fail "$EXIT_OUTPUT" "output" "chemin de sortie avec espace ou ':'"
        ;;
esac
[ "$OUT_DIR" = "$REPO_ROOT" ] && fail "$EXIT_OUTPUT" "output" "sortie = depot"
[ "$OUT_DIR" = "$KERNEL_SOURCE" ] && fail "$EXIT_OUTPUT" "output" "sortie = source noyau"
[ "$OUT_DIR" = "$TOOLCHAIN_ROOT" ] && fail "$EXIT_OUTPUT" "output" "sortie = racine toolchain"
case "$OUT_DIR" in
    "$KERNEL_SOURCE"/*) fail "$EXIT_OUTPUT" "output" "sortie dans l'arbre noyau" ;;
    "$TOOLCHAIN_ROOT"/*) fail "$EXIT_OUTPUT" "output" "sortie dans la toolchain" ;;
esac
case "$KERNEL_SOURCE" in
    "$OUT_DIR"/*) fail "$EXIT_OUTPUT" "output" "sortie est un parent de la source noyau" ;;
esac

if [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
    if [ "$FORCE" != "1" ]; then
        fail "$EXIT_OUTPUT" "output" "sortie non vide (utilise --force)"
    fi
    # gardes re-verifiees avant toute suppression
    [ -n "$OUT_DIR" ] && [ "$OUT_DIR" != "/" ] && [ -d "$OUT_DIR" ] || fail "$EXIT_OUTPUT" "output" "sortie invalide"
    case "$OUT_DIR" in
        "$KERNEL_SOURCE"/* | "$TOOLCHAIN_ROOT"/* | "$REPO_ROOT") fail "$EXIT_OUTPUT" "output" "suppression dangereuse refusee" ;;
    esac
    find "$OUT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + ||
        fail "$EXIT_OUTPUT" "output" "nettoyage de la sortie impossible"
fi

KBUILD="$OUT_DIR/kbuild"
MODULES_INSTALL="$OUT_DIR/modules-install"
ARTIFACTS="$OUT_DIR/artifacts"
LOGS="$OUT_DIR/logs"
REPORTS="$OUT_DIR/reports"
mkdir -p "$KBUILD" "$MODULES_INSTALL" "$ARTIFACTS" "$LOGS" "$REPORTS"
chmod 700 "$OUT_DIR" "$KBUILD" "$MODULES_INSTALL" "$ARTIFACTS" "$LOGS" "$REPORTS" 2>/dev/null || true

# Arguments communs a TOUTES les commandes make du noyau. Definir APRES que
# KBUILD et CROSS_COMPILE soient connus : une valeur vide ferait construire
# dans l'arbre source au lieu du repertoire O=.
MAKE_REPRO=(
    KBUILD_BUILD_TIMESTAMP="$KBUILD_TIMESTAMP"
    KBUILD_BUILD_USER="a71-builder"
    KBUILD_BUILD_HOST="a71-build"
    KBUILD_BUILD_VERSION="1"
)
MAKE_COMMON=(-C "$KERNEL_SOURCE" O="$KBUILD" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" "${MAKE_REPRO[@]}")

# --------------------------------------------------------------------------
# 4. Prerequis hote
# --------------------------------------------------------------------------
BUILD_STEP="host"

# --- prerequis de COMPILATION ---------------------------------------------
# bc est reellement requis : kernel/Kbuild:21 genere
# include/generated/timeconst.h avec "echo $(CONFIG_HZ) | bc -q timeconst.bc".
for tool in bc make git sha256sum find grep sed awk bison flex openssl perl python3 rsync file readelf; do
    have "$tool" || fail "$EXIT_HOST" "host" "prerequis de compilation manquant : $tool"
done

# --- prerequis de VALIDATION post-build ------------------------------------
# Le noyau possede son propre DTC : leur absence n'empeche pas de produire le
# DTB, mais empeche sa validation independante.
HAVE_DTC=0
have dtc && HAVE_DTC=1
HAVE_FDTDUMP=0
have fdtdump && HAVE_FDTDUMP=1
[ "$HAVE_DTC" = "1" ] || [ "$HAVE_FDTDUMP" = "1" ] ||
    fail "$EXIT_HOST" "host" "prerequis de validation manquant : dtc ou fdtdump (validation independante du DTB)"

# --- prerequis CONDITIONNEL ------------------------------------------------
# pahole ne peut etre evalue qu'apres normalisation (CONFIG_DEBUG_INFO_BTF).
PAHOLE_REQUIREMENT="not_checked"
have pahole && PAHOLE_STATUS="present" || PAHOLE_STATUS="absent"

# --------------------------------------------------------------------------
# 6. Verification de la configuration par le verificateur
# --------------------------------------------------------------------------
BUILD_STEP="check-config-input"
ST_REQ_INPUT="running"
cp -- "$CONFIG_FILE" "$REPORTS/config-input.config"
if ! "$SCRIPT_DIR/check-config.sh" --config "$CONFIG_FILE" --requirements "$REQ_FILE" \
    --report "$REPORTS/requirements-input.txt" --quiet; then
    fail "$EXIT_CONFIG" "check-config-input" "exigences non satisfaites par la configuration d'entree"
fi
ST_REQ_INPUT="completed"

# --------------------------------------------------------------------------
# 7. Normalisation
# --------------------------------------------------------------------------
BUILD_STEP="olddefconfig"
ST_OLDDEFCONFIG="running"
cp -- "$CONFIG_FILE" "$KBUILD/.config"
rc=0
run_tolerant make "${MAKE_COMMON[@]}" olddefconfig >"$LOGS/olddefconfig.log" 2>&1
rc=$A71_LAST_RC
if [ "$rc" -ne 0 ]; then
    MAKE_EXIT=$rc
    fail "$EXIT_BUILD" "olddefconfig" "olddefconfig a echoue (make code $rc)"
fi
[ -f "$KBUILD/.config" ] || fail "$EXIT_BUILD" "olddefconfig" "olddefconfig n'a produit aucun .config"
ST_OLDDEFCONFIG="completed"
cp -- "$KBUILD/.config" "$REPORTS/config-normalized.config"
SHA_NORMALIZED=$(sha_of "$KBUILD/.config")

ST_REQ_NORMALIZED="running"
if ! "$SCRIPT_DIR/check-config.sh" --config "$KBUILD/.config" --requirements "$REQ_FILE" \
    --report "$REPORTS/requirements-normalized.txt" --quiet; then
    fail "$EXIT_CONFIG" "check-config-normalized" "exigences non satisfaites apres olddefconfig"
fi
ST_REQ_NORMALIZED="completed"

# pahole : evaluation possible seulement maintenant que la configuration est normalisee.
if grep -qxF 'CONFIG_DEBUG_INFO_BTF=y' "$KBUILD/.config"; then
    PAHOLE_REQUIREMENT="required"
    [ "$PAHOLE_STATUS" = "present" ] || fail "$EXIT_HOST" "host" "CONFIG_DEBUG_INFO_BTF=y exige pahole, absent"
else
    PAHOLE_REQUIREMENT="not_required"
fi

# --------------------------------------------------------------------------
# 8. Release avant compilation
# --------------------------------------------------------------------------
BUILD_STEP="kernelrelease"
ST_KRELEASE_BEFORE="running"
RELEASE_BEFORE=$(kb_release 2>/dev/null || true)
[ -n "$RELEASE_BEFORE" ] || fail "$EXIT_BUILD" "kernelrelease" "kernelrelease incalculable"
ST_KRELEASE_BEFORE="completed"
if [ "$RELEASE_BEFORE" != "$EXPECTED_RELEASE" ]; then
    RELEASE_MATCH="mismatch"
    fail "$EXIT_COHERENCE" "kernelrelease" "release $RELEASE_BEFORE != attendue $EXPECTED_RELEASE"
fi

# --------------------------------------------------------------------------
# 9. Compilation
# --------------------------------------------------------------------------
BUILD_STEP="build"
ST_BUILD="running"
say "compilation : Image modules dtbs (-j$JOBS)"
run_tolerant make "${MAKE_COMMON[@]}" -j"$JOBS" Image modules dtbs >"$LOGS/build.log" 2>&1
rc=$A71_LAST_RC
if [ "$rc" -ne 0 ]; then
    MAKE_EXIT=$rc
    fail "$EXIT_BUILD" "build" "compilation echouee (make code $rc)"
fi

# --------------------------------------------------------------------------
# 10. Installation privee des modules
# --------------------------------------------------------------------------
BUILD_STEP="modules_install"
ST_MODULES_INSTALL="running"
case "$MODULES_INSTALL/" in
    "$OUT_DIR"/*) ;;
    *) fail "$EXIT_OUTPUT" "modules_install" "INSTALL_MOD_PATH hors de la sortie" ;;
esac
run_tolerant make "${MAKE_COMMON[@]}" INSTALL_MOD_PATH="$MODULES_INSTALL" modules_install >"$LOGS/modules-install.log" 2>&1
rc=$A71_LAST_RC
if [ "$rc" -ne 0 ]; then
    MAKE_EXIT=$rc
    fail "$EXIT_BUILD" "modules_install" "modules_install echoue (make code $rc)"
fi
ST_MODULES_INSTALL="completed"

# --------------------------------------------------------------------------
# 11. Release construite
# --------------------------------------------------------------------------
BUILD_STEP="release-check"
ST_KRELEASE_AFTER="running"
BUILT_RELEASE=$(kb_release 2>/dev/null || true)
[ -n "$BUILT_RELEASE" ] || fail "$EXIT_COHERENCE" "release-check" "release construite incalculable"
[ "$BUILT_RELEASE" = "$RELEASE_BEFORE" ] ||
    fail "$EXIT_COHERENCE" "release-check" "release apres build ($BUILT_RELEASE) != avant ($RELEASE_BEFORE)"
[ "$BUILT_RELEASE" = "$EXPECTED_RELEASE" ] ||
    fail "$EXIT_COHERENCE" "release-check" "release $BUILT_RELEASE != attendue $EXPECTED_RELEASE"
ST_KRELEASE_AFTER="completed"
RELEASE_MATCH="match"
MODULE_DIR="$MODULES_INSTALL/lib/modules/$BUILT_RELEASE"
MODULE_DIR_REL="modules-install/lib/modules/$BUILT_RELEASE"
[ -d "$MODULE_DIR" ] || fail "$EXIT_ARTIFACT" "release-check" "repertoire modules absent : $BUILT_RELEASE"

# --------------------------------------------------------------------------
# 12. Artefacts : Image
# --------------------------------------------------------------------------
ST_ARTIFACTS="running"
BUILD_STEP="artifact-image"
IMG_SRC="$KBUILD/arch/arm64/boot/Image"
[ -f "$IMG_SRC" ] || fail "$EXIT_ARTIFACT" "artifact-image" "Image absente"
[ -L "$IMG_SRC" ] && fail "$EXIT_ARTIFACT" "artifact-image" "Image est un lien symbolique"
IMAGE_SIZE=$(wc -c <"$IMG_SRC" | tr -d ' ')
[ "$IMAGE_SIZE" -gt 0 ] || fail "$EXIT_ARTIFACT" "artifact-image" "Image vide"
IMAGE_SHA=$(sha_of "$IMG_SRC")
cp -- "$IMG_SRC" "$ARTIFACTS/Image"
[ "$(sha_of "$ARTIFACTS/Image")" = "$IMAGE_SHA" ] ||
    fail "$EXIT_ARTIFACT" "artifact-image" "copie de Image non conforme"
LC_ALL=C file -b "$ARTIFACTS/Image" >"$REPORTS/image.txt"

# --------------------------------------------------------------------------
# 13. Artefacts : DTB Linux A71
# --------------------------------------------------------------------------
BUILD_STEP="artifact-dtb"
DTB_SRC="$KBUILD/$MANIFEST_DTB"
[ -f "$DTB_SRC" ] || fail "$EXIT_ARTIFACT" "artifact-dtb" "DTB absent : $MANIFEST_DTB"
[ -L "$DTB_SRC" ] && fail "$EXIT_ARTIFACT" "artifact-dtb" "DTB est un lien symbolique"
DTB_SIZE=$(wc -c <"$DTB_SRC" | tr -d ' ')
[ "$DTB_SIZE" -gt 0 ] || fail "$EXIT_ARTIFACT" "artifact-dtb" "DTB vide"
DTB_SHA=$(sha_of "$DTB_SRC")

magic=$(od -An -tx1 -N4 "$DTB_SRC" 2>/dev/null | tr -d ' \n')
[ "$magic" = "d00dfeed" ] || fail "$EXIT_ARTIFACT" "artifact-dtb" "magie FDT invalide ($magic)"

if [ "$HAVE_DTC" = "1" ]; then
    dtc -I dtb -O dts "$DTB_SRC" >"$LOGS/dtb-decompiled.dts" 2>"$LOGS/dtc.log" ||
        fail "$EXIT_ARTIFACT" "artifact-dtb" "decompilation dtc impossible"
elif [ "$HAVE_FDTDUMP" = "1" ]; then
    fdtdump "$DTB_SRC" >"$LOGS/dtb-decompiled.dts" 2>"$LOGS/dtc.log" ||
        fail "$EXIT_ARTIFACT" "artifact-dtb" "inspection fdtdump impossible"
fi
for needle in 'samsung,a715f' 'qcom,sm7150' 'simple-framebuffer'; do
    grep -qF -- "$needle" "$LOGS/dtb-decompiled.dts" ||
        fail "$EXIT_ARTIFACT" "artifact-dtb" "DTB : '$needle' absent du DTS decompile"
done

cp -- "$DTB_SRC" "$ARTIFACTS/sm7150-samsung-a715f.dtb"
[ "$(sha_of "$ARTIFACTS/sm7150-samsung-a715f.dtb")" = "$DTB_SHA" ] ||
    fail "$EXIT_ARTIFACT" "artifact-dtb" "copie du DTB non conforme"

{
    printf 'source      : %s\n' "$MANIFEST_DTB"
    printf 'taille      : %s\n' "$DTB_SIZE"
    printf 'sha256      : %s\n' "$DTB_SHA"
    printf 'magic FDT   : %s\n' "$magic"
    printf 'compatibles : samsung,a715f / qcom,sm7150 / simple-framebuffer\n'
    printf 'outil       : %s\n' "$([ "$HAVE_DTC" = "1" ] && echo dtc || echo fdtdump)"
    printf 'nature      : DTB Linux compile depuis le DTS du noyau (PAS le DTB Android utilisateur)\n'
} >"$REPORTS/dtb.txt"

# --------------------------------------------------------------------------
# 14. Artefacts : modules
# --------------------------------------------------------------------------
BUILD_STEP="artifact-modules"
[ -f "$KBUILD/modules.order" ] || fail "$EXIT_ARTIFACT" "artifact-modules" "modules.order absent"
[ -f "$KBUILD/modules.builtin" ] || fail "$EXIT_ARTIFACT" "artifact-modules" "modules.builtin absent"

# Collecte sans pipe : un "sort | while read; break" provoque EPIPE et le trap
# ERR peut tuer le script apres un build pourtant reussi.
mapfile -t MOD_FILES < <(find "$MODULE_DIR" -type f \
    \( -name '*.ko' -o -name '*.ko.gz' -o -name '*.ko.xz' -o -name '*.ko.zst' \) 2>/dev/null)
[ "${#MOD_FILES[@]}" -gt 0 ] || fail "$EXIT_ARTIFACT" "artifact-modules" "aucun module produit"

# Comptage par format : aucune hypothese "tous les modules se ressemblent".
MOD_KO=0
MOD_GZ=0
MOD_XZ=0
MOD_ZST=0
for f in "${MOD_FILES[@]}"; do
    case "$f" in
        *.ko.gz) MOD_GZ=$((MOD_GZ + 1)) ;;
        *.ko.xz) MOD_XZ=$((MOD_XZ + 1)) ;;
        *.ko.zst) MOD_ZST=$((MOD_ZST + 1)) ;;
        *.ko) MOD_KO=$((MOD_KO + 1)) ;;
    esac
done
MODULE_COUNT=$((MOD_KO + MOD_GZ + MOD_XZ + MOD_ZST))
[ "$MODULE_COUNT" -eq "${#MOD_FILES[@]}" ] ||
    fail "$EXIT_ARTIFACT" "artifact-modules" "comptage de modules incoherent"

formats=0
[ "$MOD_KO" -gt 0 ] && formats=$((formats + 1))
[ "$MOD_GZ" -gt 0 ] && formats=$((formats + 1))
[ "$MOD_XZ" -gt 0 ] && formats=$((formats + 1))
[ "$MOD_ZST" -gt 0 ] && formats=$((formats + 1))
case "$formats" in
    0) fail "$EXIT_ARTIFACT" "artifact-modules" "aucun module comptabilise" ;;
    1)
        if [ "$MOD_KO" -gt 0 ]; then MODULE_COMPRESSION="none"
        elif [ "$MOD_GZ" -gt 0 ]; then MODULE_COMPRESSION="gz"
        elif [ "$MOD_XZ" -gt 0 ]; then MODULE_COMPRESSION="xz"
        else MODULE_COMPRESSION="zst"; fi
        ;;
    *) MODULE_COMPRESSION="mixed" ;;
esac

# aucun module ne doit venir d'ailleurs que de la sortie
outside=0
for f in "${MOD_FILES[@]}"; do
    case "$f" in
        "$MODULES_INSTALL"/*) ;;
        *) outside=$((outside + 1)) ;;
    esac
done
[ "$outside" = "0" ] || fail "$EXIT_ARTIFACT" "artifact-modules" "module hors de la sortie"

sample=""
for f in "${MOD_FILES[@]}"; do
    case "$f" in
        *.ko) sample=$f; break ;;
    esac
done
if [ -n "$sample" ]; then
    if LC_ALL=C readelf -h "$sample" 2>/dev/null | grep -qE 'Machine:[[:space:]]+AArch64'; then
        MODULE_ELF="aarch64"
    else
        fail "$EXIT_ARTIFACT" "artifact-modules" "module non ELF AArch64 : $(basename "$sample")"
    fi
elif [ "$MODULE_COUNT" -gt 0 ]; then
    # uniquement des modules compresses : la verification exigerait une
    # decompression controlee, qui n'est pas faite dans cet increment.
    MODULE_ELF="not_verified_compressed"
else
    MODULE_ELF="not_verified_no_module"
fi

{
    printf 'release         : %s\n' "$BUILT_RELEASE"
    printf 'repertoire      : modules-install/lib/modules/%s\n' "$BUILT_RELEASE"
    printf 'modules         : %s\n' "$MODULE_COUNT"
    printf '  .ko           : %s\n' "$MOD_KO"
    printf '  .ko.gz        : %s\n' "$MOD_GZ"
    printf '  .ko.xz        : %s\n' "$MOD_XZ"
    printf '  .ko.zst       : %s\n' "$MOD_ZST"
    printf 'compression     : %s\n' "$MODULE_COMPRESSION"
    printf 'elf aarch64     : %s\n' "$MODULE_ELF"
    printf 'modules.order   : present\n'
    printf 'modules.builtin : present\n'
} >"$REPORTS/modules.txt"

# --------------------------------------------------------------------------
# 15. Coherence finale de la configuration
# --------------------------------------------------------------------------
ST_ARTIFACTS="completed"
BUILD_STEP="final-config"
SHA_FINAL=$(sha_of "$KBUILD/.config")
if [ "$SHA_FINAL" = "$SHA_NORMALIZED" ]; then
    CONFIG_UNCHANGED="match"
else
    CONFIG_UNCHANGED="mismatch"
    fail "$EXIT_COHERENCE" "final-config" "configuration modifiee pendant le build"
fi

ST_REQ_FINAL="running"
if ! "$SCRIPT_DIR/check-config.sh" --config "$KBUILD/.config" --requirements "$REQ_FILE" \
    --report "$REPORTS/requirements-final.txt" --quiet; then
    fail "$EXIT_COHERENCE" "final-config" "exigences non satisfaites apres compilation"
fi
ST_REQ_FINAL="completed"

REQ_TOTAL=$(sed -n 's/^# total *: *//p' "$REPORTS/requirements-final.txt" | head -1)
REQ_FAILS=$(sed -n 's/^# echecs *: *//p' "$REPORTS/requirements-final.txt" | head -1)
REQ_TOTAL=${REQ_TOTAL:-0}
REQ_FAILS=${REQ_FAILS:-0}

SHA_CONFIG_AFTER=$(sha_of "$CONFIG_FILE")
[ "$SHA_CONFIG_AFTER" = "$SHA_INPUT" ] ||
    fail "$EXIT_COHERENCE" "final-config" "configuration d'entree modifiee pendant l'execution"

{
    printf 'compileur : %s\n' "$(basename "$CC_ABS")"
    printf 'cross     : %s\n' "$(basename "$CROSS_COMPILE")"
    printf 'cible     : %s\n' "$TARGET"
    printf 'gcc       : %s\n' "$GCC_VERSION"
    printf 'dumpver   : %s\n' "$GCC_DUMPVERSION"
    printf 'sysroot   : %s\n' "${SYSROOT#"$TOOLCHAIN_ROOT"/}"
    printf 'binaire   : %s\n' "$CC_FILE"
    printf 'pahole    : %s\n' "$PAHOLE_STATUS"
} >"$REPORTS/toolchain.txt"

# --------------------------------------------------------------------------
# 16. Provenance et synthese
# --------------------------------------------------------------------------
python3 - "$REPORTS/provenance.json" <<PY
import json, sys
data = {
    "kernel_commit": "$KERNEL_COMMIT",
    "kernel_branch": "${KERNEL_BRANCH:-}",
    "kernel_git_dirty": "$GIT_DIRTY",
    "kernel_source_version": "$SOURCE_VERSION",
    "config_sha256_input": "$SHA_INPUT",
    "config_sha256_normalized": "$SHA_NORMALIZED",
    "config_sha256_final": "$SHA_FINAL",
    "toolchain_target": "$TARGET",
    "toolchain_gcc": "$GCC_VERSION",
    "toolchain_archive_sha256": "b0fad860eb94b503a56d66ca8b9ba06d2d4826943e37ebd1d7217423f6ea5bb2",
    "expected_release": "$EXPECTED_RELEASE",
    "calculated_release": "$BUILT_RELEASE",
    "image": {"size": $IMAGE_SIZE, "sha256": "$IMAGE_SHA", "path": "artifacts/Image"},
    "dtb": {"size": $DTB_SIZE, "sha256": "$DTB_SHA", "path": "artifacts/sm7150-samsung-a715f.dtb", "source": "$MANIFEST_DTB"},
    "modules": {
        "count": $MODULE_COUNT, "ko": $MOD_KO, "gz": $MOD_GZ, "xz": $MOD_XZ, "zst": $MOD_ZST,
        "compression": "$MODULE_COMPRESSION", "release": "$BUILT_RELEASE",
        "directory": "modules-install/lib/modules/$BUILT_RELEASE",
    },
    "commands": [
        "make -C <source> O=<out>/kbuild ARCH=arm64 CROSS_COMPILE=<prefix> olddefconfig",
        "make -C <source> O=<out>/kbuild ARCH=arm64 CROSS_COMPILE=<prefix> kernelrelease",
        "make -C <source> O=<out>/kbuild ARCH=arm64 CROSS_COMPILE=<prefix> -j<N> Image modules dtbs",
        "make -C <source> O=<out>/kbuild ARCH=arm64 CROSS_COMPILE=<prefix> INSTALL_MOD_PATH=<out>/modules-install modules_install",
    ],
    "source_date_epoch": $SOURCE_DATE_EPOCH,
    "kbuild_build_timestamp": "$KBUILD_TIMESTAMP",
    "kbuild_build_user": "a71-builder",
    "kbuild_build_host": "a71-build",
    "reproducibility_policy": "controlled",
    "runtime_status": "not_tested",
    "validation_status": "provisional",
    "boot_image": "not_built",
    "rootfs": "not_built",
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

ST_BUILD="completed"
RESULT="OK"
BUILD_STEP="done"
write_summary
say "build termine : $BUILT_RELEASE"
say "synthese : $OUT_DIR/build-summary.txt"
deliberate_exit "$EXIT_OK"
