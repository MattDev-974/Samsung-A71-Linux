#!/usr/bin/env bash
# shellcheck shell=bash
#
# common.sh - fonctions partagees du nouveau pipeline (phase 1).
#
# Ce fichier est SOURCE par install.sh (et par scripts/preflight.sh lorsqu'il
# est utilise comme bibliotheque). Il active volontairement le mode strict pour
# tous les appelants :
#
#   set -Eeuo pipefail
#
# Contrat :
#   * aucune action destructive ;
#   * aucun secret dans les journaux : ni arguments bruts, ni texte de commande ;
#   * une valeur TODO_* ne bloque que l'etape qui en depend vraiment.

set -Eeuo pipefail

# --------------------------------------------------------------------------
# Chemins (toujours derives de l'emplacement du fichier, jamais du cwd)
# --------------------------------------------------------------------------
COMMON_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$COMMON_DIR/.." && pwd)

WORK_DIR="${A71_WORK_DIR:-$REPO_ROOT/work}"
CACHE_DIR="${A71_CACHE_DIR:-$REPO_ROOT/.cache}"
OUT_DIR="${A71_OUT_DIR:-$WORK_DIR/output}"
LOG_DIR="${A71_LOG_DIR:-$WORK_DIR/logs}"
MANIFEST="${A71_MANIFEST:-$REPO_ROOT/manifest.yaml}"

# Etape courante : renseignee par le script appelant avec un libelle controle
# (jamais un secret, jamais une commande brute).
A71_CURRENT_STEP="${A71_CURRENT_STEP:-}"

# --------------------------------------------------------------------------
# Options globales
# --------------------------------------------------------------------------
A71_NO_WRITE="${A71_NO_WRITE:-0}"
A71_JOBS="${A71_JOBS:-}"
LOG_FILE=""

# --------------------------------------------------------------------------
# Couleurs (uniquement sur un terminal)
# --------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_INFO=$'\033[1;36m'
    C_OK=$'\033[1;32m'
    C_WARN=$'\033[1;33m'
    C_ERR=$'\033[1;31m'
else
    C_RESET=""
    C_INFO=""
    C_OK=""
    C_WARN=""
    C_ERR=""
fi

# --------------------------------------------------------------------------
# Sondes systeme (GNU d'abord, BSD ensuite, echec ferme sinon)
# --------------------------------------------------------------------------
a71_stat_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}
a71_stat_owner() {
    stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}
a71_stat_nlink() {
    stat -c '%h' "$1" 2>/dev/null || stat -f '%l' "$1" 2>/dev/null
}

have() { command -v "$1" >/dev/null 2>&1; }

# Vrai si le repertoire contient au moins une entree (sans parser ls).
a71_dir_has_entries() {
    local d=${1:-}
    local -a entries=()
    local had_nullglob=0 had_dotglob=0
    [ -d "$d" ] || return 1
    shopt -q nullglob && had_nullglob=1
    shopt -q dotglob && had_dotglob=1
    shopt -s nullglob dotglob
    entries=("$d"/*)
    [ "$had_nullglob" = "1" ] || shopt -u nullglob
    [ "$had_dotglob" = "1" ] || shopt -u dotglob
    [ "${#entries[@]}" -gt 0 ]
}

# --------------------------------------------------------------------------
# Journalisation (aucun secret)
# --------------------------------------------------------------------------
_log() {
    local level=$1
    shift
    local color="$C_INFO"
    case "$level" in
        OK) color="$C_OK" ;;
        WARN) color="$C_WARN" ;;
        ERROR) color="$C_ERR" ;;
    esac
    printf '%s[%s]%s %s\n' "$color" "$level" "$C_RESET" "$*" >&2
    if [ -n "$LOG_FILE" ]; then
        printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >>"$LOG_FILE" || true
    fi
}

# Journal sans affichage (le script affiche deja son propre rapport).
logfile_only() {
    [ -n "$LOG_FILE" ] || return 0
    printf '%s [INFO] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_FILE" || true
}

info() { _log INFO "$@"; }
ok() { _log OK "$@"; }
warn() { _log WARN "$@"; }
err() { _log ERROR "$@"; }
step() { _log INFO "==> $*"; }

die() {
    err "$*"
    deliberate_exit 1
}

# --------------------------------------------------------------------------
# Erreurs, sorties volontaires et nettoyage
# --------------------------------------------------------------------------
__A71_ERR_TRAPPED=0
__A71_CLEANUP_DONE=0
__A71_DELIBERATE_EXIT=0

deliberate_exit() {
    __A71_DELIBERATE_EXIT=1
    exit "${1:-1}"
}

# Trap ERR : ne journalise JAMAIS le texte de la commande (il pourrait contenir
# un secret). Seuls le code, le script, la ligne et l'etape controlee le sont.
a71_on_error() {
    local rc=$1 line=$2 src=$3
    local script
    if [ "${__A71_ERR_TRAPPED}" = "1" ]; then
        return 0
    fi
    __A71_ERR_TRAPPED=1
    if [ "${__A71_DELIBERATE_EXIT}" = "1" ]; then
        exit "$rc"
    fi
    script=$(basename "${src:-inconnu}")
    err "ECHEC (code $rc) dans $script a la ligne $line (etape : ${A71_CURRENT_STEP:-<non definie>})"
    if [ -n "$LOG_FILE" ]; then
        printf 'ECHEC code=%s script=%s ligne=%s etape=%s\n' \
            "$rc" "$script" "$line" "${A71_CURRENT_STEP:-<non definie>}" >>"$LOG_FILE" || true
    fi
    exit "$rc"
}

a71_cleanup() {
    local rc=$?
    if [ "${__A71_CLEANUP_DONE}" = "1" ]; then
        return 0
    fi
    __A71_CLEANUP_DONE=1
    # Phase 1 : aucune ressource a liberer (aucun montage, aucun loop device).
    return "$rc"
}

a71_install_traps() {
    trap 'a71_on_error $? $LINENO "${BASH_SOURCE[0]:-}"' ERR
    trap a71_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# --------------------------------------------------------------------------
# Securite du repertoire et du fichier de journal
# --------------------------------------------------------------------------
# Politique :
#   * chemin par defaut ($REPO_ROOT/work/logs) : creation et correction en 700
#     autorisees ;
#   * chemin personnalise (A71_LOG_DIR) : doit deja exister, etre un repertoire
#     reel, appartenir a l'utilisateur courant, etre exactement en 700 ; aucun
#     chmod automatique ;
#   * aucun lien symbolique, ni sur WORK_DIR ni sur LOG_DIR ;
#   * le chemin canonique doit rester dans $REPO_ROOT/work pour le defaut.

a71_ensure_log_dir() {
    local uid def canon mode owner
    uid=$(id -u)
    def="$REPO_ROOT/work/logs"

    if [ -L "$WORK_DIR" ]; then
        die "WORK_DIR est un lien symbolique : $WORK_DIR"
    fi
    if [ -L "$LOG_DIR" ]; then
        die "LOG_DIR est un lien symbolique : $LOG_DIR"
    fi

    if [ "$LOG_DIR" = "$def" ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || die "impossible de creer $LOG_DIR"
        chmod 700 "$LOG_DIR" 2>/dev/null || die "chmod 700 impossible sur $LOG_DIR"
        canon=$(cd "$LOG_DIR" 2>/dev/null && pwd -P) || die "LOG_DIR inaccessible : $LOG_DIR"
        [ "$canon" = "$def" ] ||
            die "LOG_DIR sort de $REPO_ROOT/work (canonique : $canon)"
    else
        [ -d "$LOG_DIR" ] || die "A71_LOG_DIR doit deja exister : $LOG_DIR"
        canon=$(cd "$LOG_DIR" 2>/dev/null && pwd -P) || die "A71_LOG_DIR inaccessible : $LOG_DIR"
        [ "$canon" = "$LOG_DIR" ] ||
            die "A71_LOG_DIR doit etre un chemin canonique (recu $LOG_DIR, canonique $canon)"
    fi

    mode=$(a71_stat_mode "$LOG_DIR") || die "stat indisponible pour $LOG_DIR"
    owner=$(a71_stat_owner "$LOG_DIR") || die "stat indisponible pour $LOG_DIR"
    [ "$owner" = "$uid" ] ||
        die "LOG_DIR n'appartient pas a l'utilisateur courant (uid $owner, attendu $uid)"
    [ "$mode" = "700" ] ||
        die "LOG_DIR doit etre en mode 700 (actuel $mode)"
}

# Verifie un journal deja existant transmis via A71_LOG_FILE.
a71_log_path_trusted() {
    local f=${1:-} uid parent dir canon mode owner nlink
    uid=$(id -u)
    [ -n "$f" ] || return 1
    case "$f" in /*) ;; *) return 1 ;; esac
    [ -L "$f" ] && return 1
    [ -f "$f" ] || return 1
    parent=$(dirname "$f")
    [ "$parent" = "$LOG_DIR" ] || return 1
    dir=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
    canon=$(cd "$LOG_DIR" 2>/dev/null && pwd -P) || return 1
    [ "$dir" = "$canon" ] || return 1
    mode=$(a71_stat_mode "$f") || return 1
    owner=$(a71_stat_owner "$f") || return 1
    nlink=$(a71_stat_nlink "$f") || return 1
    [ "$mode" = "600" ] || return 1
    [ "$owner" = "$uid" ] || return 1
    [ "$nlink" = "1" ] || return 1
    return 0
}

if [ -n "${A71_LOG_FILE:-}" ] && [ "${A71_NO_WRITE}" != "1" ]; then
    if a71_log_path_trusted "$A71_LOG_FILE"; then
        LOG_FILE=$A71_LOG_FILE
    else
        printf '%s[ERREUR]%s journal refuse : A71_LOG_FILE doit etre un fichier regulier en 600, appartenant a l utilisateur, sans lien, directement dans LOG_DIR (%s)\n' \
            "$C_ERR" "$C_RESET" "${A71_LOG_FILE}" >&2
        exit 2
    fi
fi

# log_init <action> <dry_run> <no_write> <jobs>
# Ne recoit que des champs controles : jamais les arguments bruts.
log_init() {
    local action=${1:-} dry_run=${2:-0} no_write=${3:-0} jobs=${4:-}
    local uid mode owner

    [ "$A71_NO_WRITE" = "1" ] && return 0
    [ "$no_write" = "1" ] && return 0
    [ -n "$LOG_FILE" ] && return 0

    a71_ensure_log_dir

    uid=$(id -u)
    LOG_FILE=$(umask 077 && mktemp "$LOG_DIR/a71-XXXXXXXX.log") ||
        die "impossible de creer un journal dans $LOG_DIR"

    mode=$(a71_stat_mode "$LOG_FILE") || mode=""
    owner=$(a71_stat_owner "$LOG_FILE") || owner=""
    if [ "$mode" != "600" ] || [ "$owner" != "$uid" ]; then
        rm -f "$LOG_FILE" 2>/dev/null || true
        die "journal refuse : permissions ou proprietaire incorrects (mode=$mode uid=$owner)"
    fi

    A71_LOG_FILE=$LOG_FILE
    export A71_LOG_FILE

    {
        printf '# a71 installer - journal\n'
        printf '# date     : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '# cwd      : %s\n' "$PWD"
        printf '# action   : %s\n' "$action"
        printf '# dry_run  : %s\n' "$dry_run"
        printf '# no_write : %s\n' "$no_write"
        printf '# jobs     : %s\n' "${jobs:-<non defini>}"
        printf '# manifeste: %s\n' "$MANIFEST"
        printf '# aucune donnee secrete ne doit figurer dans ce fichier\n'
    } >"$LOG_FILE"
}

log_file() {
    printf '%s\n' "$LOG_FILE"
}

# --------------------------------------------------------------------------
# Manifeste : parseur strict, jamais execute
# --------------------------------------------------------------------------
# Sous-ensemble YAML supporte (volontairement limite et strict) :
#   * indentation en espaces uniquement, exactement 2 par niveau ;
#   * pas de tabulation nulle part ;
#   * cle = [A-Za-z_][A-Za-z0-9_-]* ;
#   * une paire "cle: valeur" par ligne ; valeur vide = section ;
#   * guillemets doubles encadrant toute la valeur, sans guillemet interne ;
#   * commentaires uniquement en debut de ligne ; un commentaire inline (" #")
#     dans une valeur non citee est REFUSE ;
#   * aucun echappement YAML ;
#   * listes, blocs multilignes, anchors, tags : NON supportes.
# Tout chemin duplique (section, scalaire, ou collision des deux) invalide le
# manifeste.
#
# Codes de retour : 0 = succes ; 1 = cle absente (get) ; 3 = invalide.

__A71_MANIFEST_AWK='
function fail(lineno, msg) {
    if (errmsg == "") errmsg = "ligne " lineno ": " msg
}
function trim(s) {
    sub(/^[ ]+/, "", s)
    sub(/[ ]+$/, "", s)
    return s
}
BEGIN { n = 0; errmsg = "" }
{
    lineno = NR
    raw = $0
    if (raw ~ /^[ ]*$/) next
    if (raw ~ /\t/) { fail(lineno, "tabulation interdite"); next }
    if (raw ~ /^[ ]*#/) next
    ind = match(raw, /[^ ]/) - 1
    if (ind % 2 != 0) { fail(lineno, "indentation impaire (2 espaces par niveau)"); next }
    level = ind / 2
    line = substr(raw, ind + 1)
    c = index(line, ":")
    if (c == 0) { fail(lineno, "ligne sans deux-points"); next }
    name = substr(line, 1, c - 1)
    if (name !~ /^[A-Za-z_][A-Za-z0-9_-]*$/) {
        fail(lineno, "nom de cle invalide: [" name "]")
        next
    }
    if (level > 0 && !((level - 1) in active)) {
        fail(lineno, "parent non section au niveau " (level - 1) " (cle " name ")")
        next
    }
    val = trim(substr(line, c + 1))
    is_section = (val == "")
    if (!is_section) {
        if (val ~ /^".*"$/) {
            inner = substr(val, 2, length(val) - 2)
            if (inner ~ /"/) { fail(lineno, "guillemet interne non supporte"); next }
            val = inner
        } else if (val ~ /^"/) {
            fail(lineno, "guillemet d ouverture non ferme")
            next
        } else if (val ~ /"$/) {
            fail(lineno, "guillemet final sans guillemet initial")
            next
        } else if (val ~ /"/) {
            fail(lineno, "guillemet interne non supporte")
            next
        } else if (val ~ / #/) {
            fail(lineno, "commentaire inline non supporte (valeur non citee)")
            next
        }
    }
    for (k in active) {
        if (k + 0 >= level) delete active[k]
    }
    path = ""
    for (i = 0; i < level; i++) path = path active[i] "."
    full = path name
    if (full in kind) {
        if (kind[full] == "section" && is_section)
            fail(lineno, "section dupliquee: " full)
        else if (kind[full] == "leaf" && !is_section)
            fail(lineno, "scalaire duplique: " full)
        else
            fail(lineno, "collision section/scalaire: " full)
        next
    }
    kind[full] = is_section ? "section" : "leaf"
    seen[full] = is_section ? "" : val
    order[++n] = full
    if (is_section) active[level] = name
}
END {
    if (errmsg != "") { print "manifeste invalide: " errmsg > "/dev/stderr"; exit 3 }
    if (mode == "validate") exit 0
    if (mode == "get") {
        if (!(want in kind)) exit 1
        if (kind[want] == "section") exit 1
        print seen[want]
        exit 0
    }
    if (mode == "todo") {
        for (i = 1; i <= n; i++) {
            k = order[i]
            if (kind[k] == "leaf" && seen[k] ~ /^TODO_/) print k
        }
        exit 0
    }
    if (mode == "paths") {
        for (i = 1; i <= n; i++) print order[i]
        exit 0
    }
    exit 0
}
'

__a71_manifest_awk() {
    local mode=$1 file=$2 want=${3:-}
    [ -f "$file" ] || return 3
    awk -v mode="$mode" -v want="$want" "$__A71_MANIFEST_AWK" "$file"
}

manifest_validate() {
    __a71_manifest_awk validate "$1"
}

manifest_get() {
    __a71_manifest_awk get "$1" "$2"
}

manifest_todo_keys() {
    __a71_manifest_awk todo "$1"
}

manifest_paths() {
    __a71_manifest_awk paths "$1"
}

is_todo_value() {
    local v=${1:-}
    [ -z "$v" ] && return 0
    case "$v" in
        TODO_*) return 0 ;;
    esac
    return 1
}

# Lit une cle en distinguant les trois cas d'echec (absente, invalide, autre).
# manifest_get_or_error <cle> <contexte>
manifest_get_or_error() {
    local key=$1 ctx=$2 val rc=0
    val=$(manifest_get "$MANIFEST" "$key") || rc=$?
    case "$rc" in
        0) printf '%s\n' "$val" ;;
        1) err "manifeste : cle absente ($key) - $ctx"; return 1 ;;
        *) err "manifeste invalide ($MANIFEST) - $ctx"; return 1 ;;
    esac
}

# Exige une valeur resolue ; sinon echoue en nommant la cle et l'etape bloquee.
require_manifest_value() {
    local key=$1 blocked=$2 val
    val=$(manifest_get_or_error "$key" "etape bloquee : $blocked") || return 1
    if is_todo_value "$val"; then
        die "manifeste : $key = $val (non resolu) - etape bloquee : $blocked"
    fi
    printf '%s\n' "$val"
}

# --------------------------------------------------------------------------
# Politique --jobs : entier decimal 1..128, sans signe, zeros de tete acceptes.
# Limite fixe de securite : evite une surcharge accidentelle de la machine.
# --------------------------------------------------------------------------
A71_JOBS_MIN=1
A71_JOBS_MAX=128

validate_jobs() {
    local v=${1:-}
    case "$v" in
        '' | *[!0-9]*)
            err "--jobs attend un entier decimal positif, sans signe (recu : '${v}')"
            return 1
            ;;
    esac
    local n=$((10#$v))
    if [ "$n" -lt "$A71_JOBS_MIN" ] || [ "$n" -gt "$A71_JOBS_MAX" ]; then
        err "--jobs doit etre compris entre $A71_JOBS_MIN et $A71_JOBS_MAX (recu : $v)"
        return 1
    fi
    printf '%s\n' "$n"
}
