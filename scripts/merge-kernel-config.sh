#!/usr/bin/env bash
# shellcheck shell=bash
#
# merge-kernel-config.sh - fusion Kconfig REELLE (base + fragment -> olddefconfig)
#                         SANS compiler Image, modules, DTB ni uniLoader.
#
# Usage :
#   ./scripts/merge-kernel-config.sh \
#       --kernel-source DIR --base FILE --fragment FILE \
#       --requirements FILE --output DIR [--force] [--help]
#
# Ce que fait le script :
#   1. verifie que le HEAD du noyau correspond au commit du manifeste ;
#   2. copie les entrees dans le repertoire de sortie (les entrees ne sont
#      jamais modifiees) ;
#   3. execute le scripts/kconfig/merge_config.sh DU NOYAU fourni (jamais un
#      autre), avec -m et -O ;
#   4. conserve merged.config AVANT normalisation ;
#   5. execute make -C KERNEL O=<out>/kbuild ARCH=arm64 olddefconfig ;
#   6. conserve final.config ;
#   7. produit les differences base->merged et merged->final ;
#   8. verifie chaque directive du fragment et chaque exigence ;
#   9. produit config-summary.txt.
#
# Ce que le script ne fait JAMAIS : compiler, monter, formater, flasher,
# modifier le manifeste, modifier les entrees, ecrire hors du repertoire de
# sortie.
#
# Codes de sortie :
#   0 succes complet (fusion + exigences satisfaites)
#   1 exigences non satisfaites (le rapport est ecrit)
#   2 erreur d'usage
#   3 source noyau invalide (absente, non git, HEAD inattendu)
#   4 entree invalide (absente, illisible, fragment vide)
#   5 repertoire de sortie refuse (symlink, dans les sources, non vide)
#   6 echec de merge_config.sh ou de olddefconfig

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PROG=$(basename "$0")

# shellcheck source=scripts/common.sh
. "$SCRIPT_DIR/common.sh"
a71_install_traps

EXIT_OK=0
EXIT_REQ_FAIL=1
EXIT_USAGE=2
EXIT_KERNEL=3
EXIT_INPUT=4
EXIT_OUTPUT=5
EXIT_STEP=6

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() {
    say "$1"
    printf 'Utilise --help pour la syntaxe.\n' >&2
    deliberate_exit "$EXIT_USAGE"
}

usage() {
    cat <<EOF
$PROG - fusion Kconfig reelle, sans compilation

Usage
  $PROG --kernel-source DIR --base FILE --fragment FILE \\
        --requirements FILE --output DIR [--force]

Options
  --kernel-source DIR  arbre noyau (doit etre au commit du manifeste)
  --base FILE          configuration de base (pmaports vendue)
  --fragment FILE      fragment du projet (a71-proposed.config)
  --requirements FILE  exigences (a71-required-symbols.txt)
  --output DIR         repertoire de sortie (cree s'il est absent)
  --force              accepte un repertoire de sortie non vide
  -h, --help           affiche cette aide

Sorties produites dans DIR
  base.config              copie de l'entree base
  fragment.config          copie de l'entree fragment
  merged.config            resultat de merge_config.sh, avant olddefconfig
  final.config             resultat de olddefconfig
  base-to-merged.diff      differences introduites par le fragment
  merged-to-final.diff     differences introduites par olddefconfig
  fragment-results.tsv     chaque directive : demandee/base/merge/final
  requirements-report.txt  rapport de scripts/check-config.sh
  merge.log                journal complet de merge_config.sh
  olddefconfig.log         journal complet de olddefconfig
  config-summary.txt       synthese deterministe

Codes de sortie
  0 succes complet   1 exigences non satisfaites   2 usage
  3 source noyau invalide   4 entree invalide   5 sortie refusee
  6 echec merge_config.sh / olddefconfig
EOF
}

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
KERNEL_SOURCE=""
BASE_FILE=""
FRAGMENT_FILE=""
REQ_FILE=""
OUT_DIR=""
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
        --base) mark_opt base; [ $# -ge 2 ] || usage_error "--base attend un fichier"; BASE_FILE=$2; shift ;;
        --fragment) mark_opt fragment; [ $# -ge 2 ] || usage_error "--fragment attend un fichier"; FRAGMENT_FILE=$2; shift ;;
        --requirements) mark_opt requirements; [ $# -ge 2 ] || usage_error "--requirements attend un fichier"; REQ_FILE=$2; shift ;;
        --output) mark_opt output; [ $# -ge 2 ] || usage_error "--output attend un repertoire"; OUT_DIR=$2; shift ;;
        --force) mark_opt force; FORCE=1 ;;
        --kernel-source=*) mark_opt kernel-source; KERNEL_SOURCE=${1#--kernel-source=} ;;
        --base=*) mark_opt base; BASE_FILE=${1#--base=} ;;
        --fragment=*) mark_opt fragment; FRAGMENT_FILE=${1#--fragment=} ;;
        --requirements=*) mark_opt requirements; REQ_FILE=${1#--requirements=} ;;
        --output=*) mark_opt output; OUT_DIR=${1#--output=} ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

[ -n "$KERNEL_SOURCE" ] || usage_error "--kernel-source est obligatoire"
[ -n "$BASE_FILE" ] || usage_error "--base est obligatoire"
[ -n "$FRAGMENT_FILE" ] || usage_error "--fragment est obligatoire"
[ -n "$REQ_FILE" ] || usage_error "--requirements est obligatoire"
[ -n "$OUT_DIR" ] || usage_error "--output est obligatoire"

# --------------------------------------------------------------------------
# Source noyau : existence, depot git, HEAD == commit du manifeste
# --------------------------------------------------------------------------
[ -d "$KERNEL_SOURCE" ] || { say "source noyau absente : $(basename "$KERNEL_SOURCE")"; deliberate_exit "$EXIT_KERNEL"; }
[ -d "$KERNEL_SOURCE/.git" ] || { say "source noyau non git : $(basename "$KERNEL_SOURCE")"; deliberate_exit "$EXIT_KERNEL"; }

KERNEL_SOURCE=$(cd "$KERNEL_SOURCE" && pwd -P)

# Le systeme de build du noyau refuse explicitement les espaces et les
# deux-points dans le chemin source (Makefile:217), et merge_config.sh teste
# "-d $2" sans guillemets : un chemin espace casse silencieusement la fusion.
case "$KERNEL_SOURCE" in
    *" "* | *:*)
        say "source noyau dans un chemin contenant un espace ou ':' : refusee par le noyau (Makefile:217)"
        say "utilisez un arbre dans un chemin sans espace, par exemple /tmp/a71-kernel"
        deliberate_exit "$EXIT_KERNEL"
        ;;
esac

EXPECTED_COMMIT=$(manifest_get "$MANIFEST" "kernel.commit") || {
    say "manifeste illisible : kernel.commit introuvable"
    deliberate_exit "$EXIT_KERNEL"
}
KERNEL_BRANCH=$(manifest_get "$MANIFEST" "kernel.branch" 2>/dev/null || true)
HEAD_COMMIT=$(git -C "$KERNEL_SOURCE" rev-parse HEAD 2>/dev/null || true)
[ -n "$HEAD_COMMIT" ] || { say "HEAD du noyau illisible"; deliberate_exit "$EXIT_KERNEL"; }

if [ "$HEAD_COMMIT" != "$EXPECTED_COMMIT" ]; then
    say "commit noyau inattendu : HEAD=$HEAD_COMMIT attendu=$EXPECTED_COMMIT"
    deliberate_exit "$EXIT_KERNEL"
fi

# Atteignabilite depuis la reference documentaire (best effort : un clone
# superficiel peut ne pas contenir l'historique complet).
REACHABLE="non_verifiee"
if [ -n "$KERNEL_BRANCH" ]; then
    if git -C "$KERNEL_SOURCE" rev-parse --verify --quiet "origin/$KERNEL_BRANCH" >/dev/null 2>&1; then
        if git -C "$KERNEL_SOURCE" merge-base --is-ancestor "$HEAD_COMMIT" "origin/$KERNEL_BRANCH" 2>/dev/null; then
            REACHABLE="oui"
        else
            REACHABLE="non"
        fi
    fi
fi

MERGE_TOOL="$KERNEL_SOURCE/scripts/kconfig/merge_config.sh"
[ -f "$MERGE_TOOL" ] || { say "merge_config.sh absent de la source noyau"; deliberate_exit "$EXIT_KERNEL"; }

# --------------------------------------------------------------------------
# Entrees
# --------------------------------------------------------------------------
for f in "$BASE_FILE" "$FRAGMENT_FILE" "$REQ_FILE"; do
    [ -f "$f" ] || { say "entree absente : $(basename "$f")"; deliberate_exit "$EXIT_INPUT"; }
    [ -r "$f" ] || { say "entree illisible : $(basename "$f")"; deliberate_exit "$EXIT_INPUT"; }
done
if ! grep -qE '^CONFIG_[A-Za-z0-9_]+=' "$FRAGMENT_FILE"; then
    say "fragment invalide : aucune directive CONFIG_*="
    deliberate_exit "$EXIT_INPUT"
fi

BASE_SHA_BEFORE=$(sha256sum "$BASE_FILE" | cut -d' ' -f1)
FRAG_SHA_BEFORE=$(sha256sum "$FRAGMENT_FILE" | cut -d' ' -f1)
REQ_SHA_BEFORE=$(sha256sum "$REQ_FILE" | cut -d' ' -f1)

# --------------------------------------------------------------------------
# Repertoire de sortie : refus des chemins dangereux
# --------------------------------------------------------------------------
if [ -L "$OUT_DIR" ]; then
    say "sortie refusee : lien symbolique"
    deliberate_exit "$EXIT_OUTPUT"
fi

mkdir -p "$OUT_DIR" 2>/dev/null || { say "sortie impossible : creation refusee"; deliberate_exit "$EXIT_OUTPUT"; }
OUT_DIR=$(cd "$OUT_DIR" && pwd -P)

case "$OUT_DIR" in
    *" "* | *:*)
        say "sortie dans un chemin contenant un espace ou ':' : refusee (merge_config.sh teste '-d \$2' sans guillemets)"
        say "utilisez un repertoire de sortie sans espace, par exemple /tmp/a71-config"
        deliberate_exit "$EXIT_OUTPUT"
        ;;
esac

case "$OUT_DIR/" in
    "$KERNEL_SOURCE"/*)
        say "sortie refusee : situee dans l'arbre des sources noyau"
        deliberate_exit "$EXIT_OUTPUT"
        ;;
esac

if [ "$FORCE" != "1" ] && [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
    say "sortie refusee : repertoire non vide (utilise --force)"
    deliberate_exit "$EXIT_OUTPUT"
fi

# --------------------------------------------------------------------------
# Copie des entrees (les originaux ne sont jamais modifies)
# --------------------------------------------------------------------------
cp -- "$BASE_FILE" "$OUT_DIR/base.config"
cp -- "$FRAGMENT_FILE" "$OUT_DIR/fragment.config"
cp -- "$REQ_FILE" "$OUT_DIR/requirements.txt"

MERGED_DIR="$OUT_DIR/merged"
KBUILD_DIR="$OUT_DIR/kbuild"
mkdir -p "$MERGED_DIR"

A71_CURRENT_STEP="merge_config.sh"
# --------------------------------------------------------------------------
# 1. merge_config.sh du noyau fourni
# --------------------------------------------------------------------------
set +e
"$MERGE_TOOL" -m -O "$MERGED_DIR" "$OUT_DIR/base.config" "$OUT_DIR/fragment.config" \
    >"$OUT_DIR/merge.log" 2>&1
merge_rc=$?
set -e

if [ "$merge_rc" -ne 0 ]; then
    say "merge_config.sh a echoue (code $merge_rc), voir merge.log"
    deliberate_exit "$EXIT_STEP"
fi
if [ ! -f "$MERGED_DIR/.config" ]; then
    say "merge_config.sh n'a produit aucun .config"
    deliberate_exit "$EXIT_STEP"
fi
cp -- "$MERGED_DIR/.config" "$OUT_DIR/merged.config"

# --------------------------------------------------------------------------
# 2. olddefconfig sur une arborescence de build dediee
# --------------------------------------------------------------------------
A71_CURRENT_STEP="olddefconfig"
mkdir -p "$KBUILD_DIR"
cp -- "$OUT_DIR/merged.config" "$KBUILD_DIR/.config"

set +e
make -C "$KERNEL_SOURCE" O="$KBUILD_DIR" ARCH=arm64 olddefconfig \
    >"$OUT_DIR/olddefconfig.log" 2>&1
olddef_rc=$?
set -e

if [ "$olddef_rc" -ne 0 ]; then
    say "olddefconfig a echoue (code $olddef_rc), voir olddefconfig.log"
    deliberate_exit "$EXIT_STEP"
fi
if [ ! -f "$KBUILD_DIR/.config" ]; then
    say "olddefconfig n'a produit aucun .config"
    deliberate_exit "$EXIT_STEP"
fi
cp -- "$KBUILD_DIR/.config" "$OUT_DIR/final.config"

# --------------------------------------------------------------------------
# 3. Differences
# --------------------------------------------------------------------------
A71_CURRENT_STEP="rapports"
diff -u --label base.config --label merged.config \
    "$OUT_DIR/base.config" "$OUT_DIR/merged.config" >"$OUT_DIR/base-to-merged.diff" 2>/dev/null || true
diff -u --label merged.config --label final.config \
    "$OUT_DIR/merged.config" "$OUT_DIR/final.config" >"$OUT_DIR/merged-to-final.diff" 2>/dev/null || true

# --------------------------------------------------------------------------
# 4. Verification de chaque directive du fragment
# --------------------------------------------------------------------------
# Fragment : lignes actives CONFIG_X=valeur uniquement (commentaires ignores).
conf_value() {
    # conf_value <fichier> <symbole> -> valeur ou "-" si absent
    local file=$1 sym=$2 line
    line=$(grep -m1 -E "^${sym}=" "$file" 2>/dev/null || true)
    if [ -n "$line" ]; then
        printf '%s' "${line#*=}"
        return 0
    fi
    if grep -m1 -qE "^# ${sym} is not set$" "$file" 2>/dev/null; then
        printf 'n'
        return 0
    fi
    printf '%s' "-"
}

{
    printf 'symbol\trequested\tbase\tmerged\tfinal\tstatus\n'
    while IFS= read -r line; do
        case "$line" in '' | '#'*) continue ;; esac
        case "$line" in CONFIG_*=*) ;; *) continue ;; esac
        sym=${line%%=*}
        want=${line#*=}
        v_base=$(conf_value "$OUT_DIR/base.config" "$sym")
        v_merge=$(conf_value "$OUT_DIR/merged.config" "$sym")
        v_final=$(conf_value "$OUT_DIR/final.config" "$sym")
        status="applied"
        if [ "$v_merge" = "-" ]; then
            status="absent_apres_merge"
        elif [ "$v_final" = "-" ]; then
            status="supprime_par_olddefconfig"
        elif [ "$v_final" != "$want" ]; then
            status="modifie_par_olddefconfig"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sym" "$want" "$v_base" "$v_merge" "$v_final" "$status"
    done <"$OUT_DIR/fragment.config"
} >"$OUT_DIR/fragment-results.tsv"

# --------------------------------------------------------------------------
# 5. Exigences : check-config.sh (code propage)
# --------------------------------------------------------------------------
A71_CURRENT_STEP="exigences"
req_rc=0
"$SCRIPT_DIR/check-config.sh" \
    --config "$OUT_DIR/final.config" \
    --requirements "$OUT_DIR/requirements.txt" \
    --report "$OUT_DIR/requirements-report.txt" \
    --quiet || req_rc=$?

# --------------------------------------------------------------------------
# 6. kernelrelease (calculee, jamais compilee)
# --------------------------------------------------------------------------
A71_CURRENT_STEP="kernelrelease"
KERNEL_RELEASE="non_calculee"
set +e
kr=$(make -s -C "$KERNEL_SOURCE" O="$KBUILD_DIR" ARCH=arm64 kernelrelease 2>>"$OUT_DIR/olddefconfig.log")
kr_rc=$?
set -e
if [ "$kr_rc" -eq 0 ] && [ -n "$kr" ]; then
    KERNEL_RELEASE=$kr
fi

# --------------------------------------------------------------------------
# 7. Synthese deterministe
# --------------------------------------------------------------------------
n_frag=$(grep -cE '^CONFIG_[A-Za-z0-9_]+=' "$OUT_DIR/fragment.config" || true)
n_changed=$(grep -cE '^\+[^+]' "$OUT_DIR/base-to-merged.diff" || true)
n_olddef=$(grep -cE '^\+[^+]' "$OUT_DIR/merged-to-final.diff" || true)
n_req_total=$(sed -n 's/^# total *: *//p' "$OUT_DIR/requirements-report.txt" 2>/dev/null | head -1)
n_req_fail=$(sed -n 's/^# echecs *: *//p' "$OUT_DIR/requirements-report.txt" 2>/dev/null | head -1)
n_req_total=${n_req_total:-0}
n_req_fail=${n_req_fail:-0}
req_result=$(grep -m1 -E '^RESULTAT: ' "$OUT_DIR/requirements-report.txt" 2>/dev/null | sed 's/^RESULTAT: //' || echo INCONNU)

if [ "$req_rc" -eq 0 ]; then
    FINAL_RESULT="OK"
    FINAL_CODE=$EXIT_OK
else
    FINAL_RESULT="ECHEC"
    FINAL_CODE=$EXIT_REQ_FAIL
fi

summary_tmp=$(umask 077 && mktemp "$OUT_DIR/.summary-XXXXXXXX")
{
    printf '# fusion de configuration noyau - synthese\n'
    printf 'kernel_commit\t%s\n' "$EXPECTED_COMMIT"
    printf 'kernel_branch\t%s\n' "${KERNEL_BRANCH:-<non definie>}"
    printf 'kernel_head_atteignable\t%s\n' "$REACHABLE"
    printf 'kernel_release_calculee\t%s\n' "$KERNEL_RELEASE"
    printf 'base\t%s\n' "$(basename "$BASE_FILE")"
    printf 'fragment\t%s\n' "$(basename "$FRAGMENT_FILE")"
    printf 'requirements\t%s\n' "$(basename "$REQ_FILE")"
    printf 'directives_fragment\t%s\n' "$n_frag"
    printf 'lignes_changees_base_vers_merge\t%s\n' "$n_changed"
    printf 'lignes_changees_merge_vers_final\t%s\n' "$n_olddef"
    printf 'exigences_total\t%s\n' "$n_req_total"
    printf 'exigences_echecs\t%s\n' "$n_req_fail"
    printf 'exigences_resultat\t%s\n' "$req_result"
    printf 'fragment_modifie_par_olddefconfig\t%s\n' "$(grep -cE 'modifie_par_olddefconfig|supprime_par_olddefconfig' "$OUT_DIR/fragment-results.tsv" || true)"
    printf 'resultat_final\t%s\n' "$FINAL_RESULT"
    printf 'build\tAUCUNE COMPILATION (Image/modules/DTB non construits)\n'
    printf 'runtime\tnot_tested\n'
} >"$summary_tmp"
mv -f "$summary_tmp" "$OUT_DIR/config-summary.txt"

# --------------------------------------------------------------------------
# 8. Integrite des entrees
# --------------------------------------------------------------------------
BASE_SHA_AFTER=$(sha256sum "$BASE_FILE" | cut -d' ' -f1)
FRAG_SHA_AFTER=$(sha256sum "$FRAGMENT_FILE" | cut -d' ' -f1)
REQ_SHA_AFTER=$(sha256sum "$REQ_FILE" | cut -d' ' -f1)
if [ "$BASE_SHA_BEFORE" != "$BASE_SHA_AFTER" ] ||
    [ "$FRAG_SHA_BEFORE" != "$FRAG_SHA_AFTER" ] ||
    [ "$REQ_SHA_BEFORE" != "$REQ_SHA_AFTER" ]; then
    say "entree modifiee pendant l'execution : anomalie"
    deliberate_exit "$EXIT_STEP"
fi

say "synthese : $OUT_DIR/config-summary.txt (resultat $FINAL_RESULT)"
deliberate_exit "$FINAL_CODE"
