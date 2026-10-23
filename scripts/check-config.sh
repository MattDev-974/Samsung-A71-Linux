#!/usr/bin/env bash
# shellcheck shell=bash
#
# check-config.sh - verificateur STATIQUE des exigences de configuration noyau.
#
# Lecture seule : ne compile rien, ne fusionne rien, ne monte rien, n'ecrit
# jamais dans le .config ni dans le fichier d'exigences. Le seul ecrit possible
# est le rapport demande explicitement par --report (fichier temporaire +
# renommage atomique).
#
# Usage :
#   ./scripts/check-config.sh --config FILE --requirements FILE
#   ./scripts/check-config.sh --config FILE --requirements FILE --report FILE
#   ./scripts/check-config.sh --help
#
# Options : --config, --requirements, --report, --quiet, --help.
#
# Codes de sortie :
#   0 exigences satisfaites
#   1 exigences non satisfaites
#   2 erreur d'usage
#   3 fichier d'exigences invalide (absent, illisible, format, doublon)
#   4 .config absent, illisible ou invalide (format, doublon)
#   5 erreur d'ecriture du rapport

set -Eeuo pipefail

PROG=$(basename "$0")
EXIT_OK=0
EXIT_FAIL=1
EXIT_USAGE=2
EXIT_REQ=3
EXIT_CONF=4
EXIT_REPORT=5

# --------------------------------------------------------------------------
# Messages (toujours sur stderr : stdout reste le rapport)
# --------------------------------------------------------------------------
say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() {
    say "$1"
    printf 'Utilise --help pour la syntaxe.\n' >&2
    exit "$EXIT_USAGE"
}

usage() {
    cat <<EOF
$PROG - verification statique d'une configuration noyau

Usage
  $PROG --config FILE --requirements FILE [--report FILE] [--quiet]
  $PROG --help

Options
  --config FILE        fichier .config a verifier (lecture seule)
  --requirements FILE  liste d'exigences CONFIG_SYM=valeur
  --report FILE        ecrit le rapport dans FILE (atomique)
  --quiet              n'affiche rien sur stdout (le code de sortie reste parlant)
  -h, --help           affiche cette aide

Format des exigences (une par ligne)
  CONFIG_SYMBOL=y      doit etre integre
  CONFIG_SYMBOL=m      doit etre en module
  CONFIG_SYMBOL=m|y    integre ou module
  CONFIG_SYMBOL=n      doit etre desactive
  # commentaire        ignore
  Les lignes vides sont ignorees. Tout autre contenu est une erreur (code 3).

Codes de sortie
  0 exigences satisfaites
  1 exigences non satisfaites
  2 erreur d'usage
  3 fichier d'exigences invalide
  4 .config absent, illisible ou invalide
  5 erreur d'ecriture du rapport
EOF
}

# --------------------------------------------------------------------------
# Analyse des arguments
# --------------------------------------------------------------------------
CONFIG_FILE=""
REQ_FILE=""
REPORT_FILE=""
QUIET=0
SEEN=" "

mark_opt() {
    case "$SEEN" in
        *" $1 "*) usage_error "option repetee : --$1" ;;
    esac
    SEEN="$SEEN$1 "
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit "$EXIT_OK"
            ;;
        --config)
            mark_opt config
            [ $# -ge 2 ] || usage_error "--config attend un fichier"
            CONFIG_FILE=$2
            shift
            ;;
        --requirements)
            mark_opt requirements
            [ $# -ge 2 ] || usage_error "--requirements attend un fichier"
            REQ_FILE=$2
            shift
            ;;
        --report)
            mark_opt report
            [ $# -ge 2 ] || usage_error "--report attend un fichier"
            REPORT_FILE=$2
            shift
            ;;
        --quiet)
            mark_opt quiet
            QUIET=1
            ;;
        --config=*)
            mark_opt config
            CONFIG_FILE=${1#--config=}
            ;;
        --requirements=*)
            mark_opt requirements
            REQ_FILE=${1#--requirements=}
            ;;
        --report=*)
            mark_opt report
            REPORT_FILE=${1#--report=}
            ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

[ -n "$CONFIG_FILE" ] || usage_error "--config est obligatoire"
[ -n "$REQ_FILE" ] || usage_error "--requirements est obligatoire"

# --------------------------------------------------------------------------
# Lecture du .config
# --------------------------------------------------------------------------
# Un .config valide contient des lignes :
#   CONFIG_X=valeur        (y, m, n, nombre, chaine entre guillemets)
#   # CONFIG_X is not set
#   # commentaire quelconque
# Toute autre ligne commencant par "CONFIG_" est une erreur de format.

declare -A CONF_VALUE=()
declare -A CONF_LINE=()
CONF_DUP=0
CONF_BAD=""

if [ ! -f "$CONFIG_FILE" ]; then
    say "fichier .config absent : $(basename "$CONFIG_FILE")"
    exit "$EXIT_CONF"
fi
if [ ! -r "$CONFIG_FILE" ]; then
    say "fichier .config illisible : $(basename "$CONFIG_FILE")"
    exit "$EXIT_CONF"
fi

conf_lineno=0
while IFS= read -r line || [ -n "$line" ]; do
    conf_lineno=$((conf_lineno + 1))
    case "$line" in
        '' | '#'*)
            # commentaire ou ligne vide : ignore (mais "# CONFIG_X is not set" est traite plus bas)
            if [[ "$line" =~ ^#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
                sym=${BASH_REMATCH[1]}
                if [ -n "${CONF_VALUE[$sym]:-}" ] || [ -n "${CONF_LINE[$sym]:-}" ]; then
                    CONF_DUP=$((CONF_DUP + 1))
                fi
                CONF_VALUE[$sym]="n"
                CONF_LINE[$sym]=$conf_lineno
            fi
            continue
            ;;
        CONFIG_*=*)
            sym=${line%%=*}
            val=${line#*=}
            if ! [[ "$sym" =~ ^CONFIG_[A-Za-z0-9_]+$ ]]; then
                CONF_BAD="ligne $conf_lineno : nom de symbole invalide"
                break
            fi
            if [ -n "${CONF_LINE[$sym]:-}" ]; then
                CONF_DUP=$((CONF_DUP + 1))
            fi
            CONF_VALUE[$sym]=$val
            CONF_LINE[$sym]=$conf_lineno
            continue
            ;;
        CONFIG_*)
            CONF_BAD="ligne $conf_lineno : ligne CONFIG_ sans '='"
            break
            ;;
        *)
            # bruit tolerant : certaines versions ajoutent des lignes libres
            continue
            ;;
    esac
done <"$CONFIG_FILE"

if [ -n "$CONF_BAD" ]; then
    say ".config invalide : $CONF_BAD"
    exit "$EXIT_CONF"
fi
if [ "$CONF_DUP" -gt 0 ]; then
    say ".config invalide : $CONF_DUP symbole(s) declare(s) plusieurs fois"
    exit "$EXIT_CONF"
fi

# --------------------------------------------------------------------------
# Lecture des exigences
# --------------------------------------------------------------------------
declare -A REQ_VALUE=()
declare -a REQ_ORDER=()
REQ_DUP=0
REQ_BAD=""

if [ ! -f "$REQ_FILE" ]; then
    say "fichier d'exigences absent : $(basename "$REQ_FILE")"
    exit "$EXIT_REQ"
fi
if [ ! -r "$REQ_FILE" ]; then
    say "fichier d'exigences illisible : $(basename "$REQ_FILE")"
    exit "$EXIT_REQ"
fi

req_lineno=0
while IFS= read -r line || [ -n "$line" ]; do
    req_lineno=$((req_lineno + 1))
    case "$line" in
        '' | '#'*) continue ;;
    esac
    if ! [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_]+)=(y|m|n|m\|y)$ ]]; then
        REQ_BAD="ligne $req_lineno : format invalide"
        break
    fi
    sym=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[2]}
    if [ -n "${REQ_VALUE[$sym]:-}" ]; then
        REQ_DUP=$((REQ_DUP + 1))
    fi
    REQ_VALUE[$sym]=$val
    REQ_ORDER+=("$sym")
done <"$REQ_FILE"

if [ -n "$REQ_BAD" ]; then
    say "exigences invalides : $REQ_BAD"
    exit "$EXIT_REQ"
fi
if [ "$REQ_DUP" -gt 0 ]; then
    say "exigences invalides : $REQ_DUP symbole(s) en double"
    exit "$EXIT_REQ"
fi
if [ "${#REQ_ORDER[@]}" -eq 0 ]; then
    say "exigences invalides : aucune exigence"
    exit "$EXIT_REQ"
fi

# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------
TOTAL=0
FAILS=0
declare -a REPORT=()

rep() { REPORT+=("$1"); }

for sym in "${REQ_ORDER[@]}"; do
    want=${REQ_VALUE[$sym]}
    TOTAL=$((TOTAL + 1))
    if [ -z "${CONF_LINE[$sym]:-}" ]; then
        FAILS=$((FAILS + 1))
        rep "ECHEC $sym : attendu $want, symbole absent du .config"
        continue
    fi
    got=${CONF_VALUE[$sym]}
    case "$want" in
        "y")
            if [ "$got" = "y" ]; then
                rep "OK    $sym=$got"
            elif [ "$got" = "m" ]; then
                FAILS=$((FAILS + 1))
                rep "ECHEC $sym : attendu y, obtenu m (retrograde)"
            elif [ "$got" = "n" ]; then
                FAILS=$((FAILS + 1))
                rep "ECHEC $sym : attendu y, desactive"
            else
                FAILS=$((FAILS + 1))
                rep "ECHEC $sym : attendu y, valeur incorrecte"
            fi
            ;;
        "m")
            if [ "$got" = "m" ]; then
                rep "OK    $sym=$got"
            elif [ "$got" = "y" ]; then
                FAILS=$((FAILS + 1))
                rep "ECHEC $sym : attendu m, obtenu y (integre au lieu de module)"
            elif [ "$got" = "n" ]; then
                FAILS=$((FAILS + 1))
                rep "ECHEC $sym : attendu m, desactive"
            else
                FAILS=$((FAILS + 1))
                rep "ECHEC $sym : attendu m, valeur incorrecte"
            fi
            ;;
        "m|y")
            if [ "$got" = "m" ] || [ "$got" = "y" ]; then
                rep "OK    $sym=$got (m|y accepte)"
            elif [ "$got" = "n" ]; then
                FAILS=$((FAILS + 1))
                rep "ECHEC $sym : attendu m|y, desactive"
            else
                FAILS=$((FAILS + 1))
                rep "ECHEC $sym : attendu m|y, valeur incorrecte"
            fi
            ;;
        "n")
            if [ "$got" = "n" ]; then
                rep "OK    $sym desactive (attendu n)"
            elif [ "$got" = "y" ] || [ "$got" = "m" ]; then
                FAILS=$((FAILS + 1))
                rep "ECHEC $sym : attendu n, obtenu $got"
            else
                FAILS=$((FAILS + 1))
                rep "ECHEC $sym : attendu n, valeur incorrecte"
            fi
            ;;
    esac
done

if [ "$FAILS" -gt 0 ]; then
    RESULT="ECHEC"
    CODE=$EXIT_FAIL
else
    RESULT="OK"
    CODE=$EXIT_OK
fi

# Rapport deterministe : aucun horodatage, aucun chemin absolu.
render_report() {
    printf '# verification de configuration noyau\n'
    printf '# config    : %s\n' "$(basename "$CONFIG_FILE")"
    printf '# exigences : %s\n' "$(basename "$REQ_FILE")"
    printf '# total     : %d\n' "$TOTAL"
    printf '# echecs    : %d\n' "$FAILS"
    printf 'RESULTAT: %s\n' "$RESULT"
    printf '%s\n' "${REPORT[@]}"
}

if [ "$QUIET" != "1" ]; then
    render_report
fi

# --------------------------------------------------------------------------
# Rapport fichier (atomique, sans creation de repertoire, sans symlink)
# --------------------------------------------------------------------------
if [ -n "$REPORT_FILE" ]; then
    if [ -L "$REPORT_FILE" ]; then
        say "rapport refuse : la cible est un lien symbolique ($(basename "$REPORT_FILE"))"
        exit "$EXIT_REPORT"
    fi
    report_dir=$(dirname "$REPORT_FILE")
    if [ ! -d "$report_dir" ]; then
        say "rapport refuse : le repertoire cible n'existe pas ($(basename "$report_dir"))"
        exit "$EXIT_REPORT"
    fi
    if [ ! -w "$report_dir" ]; then
        say "rapport refuse : repertoire non inscriptible ($(basename "$report_dir"))"
        exit "$EXIT_REPORT"
    fi
    tmp=$(umask 077 && mktemp "$report_dir/.a71-report-XXXXXXXX") || {
        say "rapport impossible : creation du fichier temporaire echouee"
        exit "$EXIT_REPORT"
    }
    if ! render_report >"$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        say "rapport impossible : ecriture echouee"
        exit "$EXIT_REPORT"
    fi
    if ! mv -f "$tmp" "$REPORT_FILE" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        say "rapport impossible : renommage atomique echoue"
        exit "$EXIT_REPORT"
    fi
fi

exit "$CODE"
