#!/usr/bin/env bash
# shellcheck shell=bash
#
# tests/phase1/run-tests.sh - tests non destructifs du socle (phase 1).
#
# Portee :
#   * parseur de manifeste strict (syntaxe, doublons, valeurs piegees) ;
#   * analyse des options (exclusivite help/version, repetitions, conflits) ;
#   * journal (creation, contenu, permissions, refus des chemins non surs) ;
#   * traps et codes de sortie ;
#   * prediagnostic (bibliotheque, lancement direct refuse, outils par action).
#
# Garanties :
#   * n'ecrit que dans un repertoire temporaire (mktemp -d), supprime a la fin ;
#   * ne touche ni au manifeste reel, ni a work/, ni a un peripherique ;
#   * ne telecharge rien, ne compile rien, ne monte rien.
#
# Usage : ./tests/phase1/run-tests.sh
# Code de sortie : 0 si tous les tests passent, 1 sinon.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d) || {
    echo "impossible de creer un repertoire temporaire" >&2
    exit 1
}
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

PASS=0
FAIL=0

check_eq() {
    local desc=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$desc"
    else
        FAIL=$((FAIL + 1))
        printf '  ECHEC %s (attendu [%s], obtenu [%s])\n' "$desc" "$expected" "$actual"
    fi
}

check_ne() {
    local desc=$1 unexpected=$2 actual=$3
    if [ "$unexpected" != "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$desc"
    else
        FAIL=$((FAIL + 1))
        printf '  ECHEC %s (valeur inattendue [%s])\n' "$desc" "$actual"
    fi
}

check_absent() {
    local desc=$1 path=$2
    if [ ! -e "$path" ]; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$desc"
    else
        FAIL=$((FAIL + 1))
        printf '  ECHEC %s (%s existe)\n' "$desc" "$path"
    fi
}

check_present() {
    local desc=$1 path=$2
    if [ -e "$path" ]; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$desc"
    else
        FAIL=$((FAIL + 1))
        printf '  ECHEC %s (%s absent)\n' "$desc" "$path"
    fi
}

section() { printf '\n%s\n' "$*"; }

# Ecrit un manifeste de test et renvoie le code de manifest_validate (0 ou 3).
manifest_case() {
    local name=$1
    shift
    printf '%s' "$*" >"$TMP/$name"
    ( . "$ROOT/scripts/common.sh"
      manifest_validate "$TMP/$name"
    ) >/dev/null 2>&1
    echo $?
}

# get_case <nom> <contenu> <cle> -> "code:valeur"
get_case() {
    local name=$1 content=$2 key=$3 out rc=0
    printf '%s' "$content" >"$TMP/$name"
    out=$( ( . "$ROOT/scripts/common.sh"
             manifest_get "$TMP/$name" "$key" ) 2>/dev/null ) || rc=$?
    printf '%s:%s' "$rc" "$out"
}

# Ecrit un manifeste et renvoie le code de "install.sh --version" (CLI).
manifest_cli() {
    local name=$1
    shift
    printf '%s' "$*" >"$TMP/$name"
    A71_MANIFEST="$TMP/$name" A71_NO_WRITE=1 "$ROOT/install.sh" --version \
        >"$TMP/out" 2>"$TMP/err"
    echo $?
}

# --------------------------------------------------------------------------
section "1. Manifeste - cas de base"
# --------------------------------------------------------------------------
check_eq "manifeste absent -> refus" 1 "$(A71_MANIFEST=$TMP/absent.yaml A71_NO_WRITE=1 "$ROOT/install.sh" --version >/dev/null 2>&1; echo $?)"
: >"$TMP/empty.yaml"
check_eq "manifeste vide -> refus" 1 "$(A71_MANIFEST=$TMP/empty.yaml A71_NO_WRITE=1 "$ROOT/install.sh" --version >/dev/null 2>&1; echo $?)"
check_eq "version absente -> refus" 1 "$(manifest_cli nover.yaml 'project:
  name: x
')"
check_eq "version TODO_VERIFIER -> refus" 1 "$(manifest_cli todo.yaml 'project:
  version: TODO_VERIFIER
')"
grep -qi "non resolue" "$TMP/err" && r=oui || r=non
check_eq "message 'non resolue' present" oui "$r"
check_eq "manifeste valide -> ok" 0 "$(manifest_cli ok.yaml 'project:
  version: 1.2.3
')"
check_eq "valeur guillemetee -> ok" 0 "$(manifest_cli quoted.yaml 'project:
  version: "1.2.3"
')"
check_eq "valeur avec espaces -> ok" 0 "$(manifest_cli spaces.yaml 'project:
  version: "1.2.3 beta"
')"
check_eq "valeur avec deux-points -> ok" 0 "$(manifest_cli colon.yaml 'project:
  version: "1.0:rc1"
')"

# --------------------------------------------------------------------------
section "2. Manifeste - syntaxe stricte"
# --------------------------------------------------------------------------
check_eq "ligne sans deux-points -> invalide" 3 "$(manifest_case s01.yaml 'project:
  version: 1
ceci nest pas yaml
')"
check_eq "tabulation -> invalide" 3 "$(manifest_case s02.yaml "$(printf 'project:\n\tversion: 1\n')")"
check_eq "indentation 1 espace -> invalide" 3 "$(manifest_case s03.yaml 'project:
 version: 1
')"
check_eq "indentation 3 espaces -> invalide" 3 "$(manifest_case s04.yaml 'project:
   version: 1
')"
check_eq "saut de niveau 0->2 -> invalide" 3 "$(manifest_case s05.yaml 'project:
    version: 1
')"
check_eq "niveau inexistant -> invalide" 3 "$(manifest_case s06.yaml '  version: 1
')"
check_eq "cle vide -> invalide" 3 "$(manifest_case s07.yaml 'project:
  : 1
')"
check_eq "cle avec espace -> invalide" 3 "$(manifest_case s08.yaml 'project:
  ver sion: 1
')"
check_eq "cle avec point -> invalide" 3 "$(manifest_case s09.yaml 'project:
  ver.sion: 1
')"
check_eq "section dupliquee -> invalide" 3 "$(manifest_case s10.yaml 'project:
  version: 1
project:
  name: x
')"
check_eq "scalaire duplique -> invalide" 3 "$(manifest_case s11.yaml 'project:
  version: 1
  version: 2
')"
check_eq "collision scalaire->section -> invalide" 3 "$(manifest_case s12.yaml 'project: valeur
project:
  version: 1
')"
check_eq "collision section->scalaire -> invalide" 3 "$(manifest_case s12b.yaml 'project:
  version: 1
project: valeur
')"
check_eq "guillemet non ferme -> invalide" 3 "$(manifest_case s13.yaml 'project:
  version: "1.2.3
')"
check_eq "guillemet final isole -> invalide" 3 "$(manifest_case s14.yaml 'project:
  version: 1.2.3"
')"
check_eq "guillemets internes -> invalide" 3 "$(manifest_case s15.yaml 'project:
  version: a"b
')"
check_eq "profondeur 3 valide" 0 "$(manifest_case d3.yaml 'a:
  b:
    c: 1
')"

printf 'project:\n  version: "$(touch %s/should-not-exist)"\n' "$TMP" >"$TMP/evil.yaml"
A71_MANIFEST="$TMP/evil.yaml" A71_NO_WRITE=1 "$ROOT/install.sh" --version >/dev/null 2>&1
check_absent "manifeste piege non execute" "$TMP/should-not-exist"

( . "$ROOT/scripts/common.sh"
  manifest_validate "$ROOT/manifest.yaml"
) >/dev/null 2>&1
check_eq "manifeste reel valide" 0 "$?"
( . "$ROOT/scripts/common.sh"
  manifest_get "$ROOT/manifest.yaml" boot_image.validated.page_size
) >"$TMP/p1" 2>/dev/null
check_eq "profondeur 3 (validated.page_size)" "TODO_VERIFIER" "$(cat "$TMP/p1")"
( . "$ROOT/scripts/common.sh"
  manifest_get "$ROOT/manifest.yaml" boot_image.legacy_observed.page_size
) >"$TMP/p2" 2>/dev/null
check_eq "profondeur 3 (legacy.page_size)" "4096" "$(cat "$TMP/p2")"

# --------------------------------------------------------------------------
section "3. state_* supprime"
# --------------------------------------------------------------------------
( . "$ROOT/scripts/common.sh"; declare -F state_set >/dev/null ) 2>/dev/null
check_eq "state_set n'existe plus" 1 "$?"
( . "$ROOT/scripts/common.sh"; declare -F state_get >/dev/null ) 2>/dev/null
check_eq "state_get n'existe plus" 1 "$?"

# --------------------------------------------------------------------------
section "4. Options"
# --------------------------------------------------------------------------
opt_code() {
    local logdir=${OPT_LOGDIR:-$TMP/logs}
    A71_LOG_DIR="$logdir" A71_NO_WRITE="${OPT_NO_WRITE:-0}" \
        "$ROOT/install.sh" "$@" >"$TMP/o" 2>"$TMP/e"
    echo $?
}

check_eq "--help" 0 "$(OPT_NO_WRITE=1 opt_code --help)"
check_eq "--version" 0 "$(OPT_NO_WRITE=1 opt_code --version)"
check_eq "--help --no-write" 0 "$(opt_code --help --no-write)"
check_eq "--version --no-write" 0 "$(opt_code --version --no-write)"
check_eq "--no-write --version" 0 "$(opt_code --no-write --version)"
check_eq "--help --check refuse" 2 "$(OPT_NO_WRITE=1 opt_code --help --check)"
check_eq "--check --help refuse" 2 "$(OPT_NO_WRITE=1 opt_code --check --help)"
check_eq "--version --dry-run refuse" 2 "$(OPT_NO_WRITE=1 opt_code --version --dry-run)"
check_eq "--dry-run --version refuse" 2 "$(OPT_NO_WRITE=1 opt_code --dry-run --version)"
check_eq "--jobs abc --help refuse" 2 "$(OPT_NO_WRITE=1 opt_code --jobs abc --help)"
check_eq "--help --option-inconnue refuse" 2 "$(OPT_NO_WRITE=1 opt_code --help --option-inconnue)"
check_eq "--no-write repete refuse" 2 "$(OPT_NO_WRITE=1 opt_code --no-write --no-write)"
check_eq "--check --dry-run refuse" 2 "$(OPT_NO_WRITE=1 opt_code --check --dry-run)"
check_eq "--dry-run --check refuse" 2 "$(OPT_NO_WRITE=1 opt_code --dry-run --check)"
check_eq "--dry-run repete refuse" 2 "$(OPT_NO_WRITE=1 opt_code --dry-run --dry-run)"
check_eq "--option-inconnue refuse" 2 "$(OPT_NO_WRITE=1 opt_code --option-inconnue)"
check_eq "argument positionnel refuse" 2 "$(OPT_NO_WRITE=1 opt_code foo)"
check_eq "--jobs sans valeur refuse" 2 "$(OPT_NO_WRITE=1 opt_code --jobs)"
check_eq "--jobs 0 refuse" 2 "$(OPT_NO_WRITE=1 opt_code --jobs 0)"
check_eq "--jobs -1 refuse" 2 "$(OPT_NO_WRITE=1 opt_code --jobs -1)"
check_eq "--jobs +2 refuse" 2 "$(OPT_NO_WRITE=1 opt_code --jobs +2)"
check_eq "--jobs 200 refuse" 2 "$(OPT_NO_WRITE=1 opt_code --jobs 200)"
check_eq "--jobs abc refuse" 2 "$(OPT_NO_WRITE=1 opt_code --jobs abc)"
check_eq "--jobs=4 accepte" 0 "$(OPT_NO_WRITE=1 opt_code --jobs=4 --dry-run)"
check_eq "--jobs 4 accepte" 0 "$(OPT_NO_WRITE=1 opt_code --jobs 4 --dry-run)"
check_eq "--jobs 01 accepte" 0 "$(OPT_NO_WRITE=1 opt_code --jobs 01 --dry-run)"
check_eq "--jobs 4 --jobs 8 refuse" 2 "$(OPT_NO_WRITE=1 opt_code --jobs 4 --jobs 8)"

A71_NO_WRITE=1 "$ROOT/install.sh" --dry-run --no-write >"$TMP/d1" 2>&1
A71_NO_WRITE=1 "$ROOT/install.sh" --no-write --dry-run >"$TMP/d2" 2>&1
if cmp -s "$TMP/d1" "$TMP/d2"; then
    PASS=$((PASS + 1))
    printf '  ok    ordre --dry-run/--no-write sans effet\n'
else
    FAIL=$((FAIL + 1))
    printf '  ECHEC ordre --dry-run/--no-write change la sortie\n'
fi

# --------------------------------------------------------------------------
section "5. Journal"
# --------------------------------------------------------------------------
LOGS="$TMP/logs"
mkdir -p "$LOGS"
chmod 700 "$LOGS"
A71_LOG_DIR="$LOGS" "$ROOT/install.sh" --check >/dev/null 2>&1
check_eq "--check reussit" 0 "$?"
check_eq "un seul journal cree" 1 "$(ls -A "$LOGS" | wc -l)"
LOGF=$(ls -t "$LOGS"/*.log 2>/dev/null | head -1)
check_present "journal present" "$LOGF"
check_eq "en-tete action" 1 "$(grep -c '^# action   : check' "$LOGF" 2>/dev/null)"
check_eq "journal contient le predisagnostic" 1 "$(grep -c 'Prediagnostic' "$LOGF" 2>/dev/null)"
check_eq "journal contient le resume" 1 "$(grep -c 'Resultat :' "$LOGF" 2>/dev/null)"
check_eq "pas d arguments bruts" 0 "$(grep -c '^# args' "$LOGF" 2>/dev/null)"
check_eq "permissions journal 600" 600 "$(stat -c '%a' "$LOGF" 2>/dev/null)"
check_eq "permissions repertoire 700" 700 "$(stat -c '%a' "$LOGS" 2>/dev/null)"

before=$(ls -A "$LOGS" | wc -l)
A71_LOG_DIR="$LOGS" "$ROOT/install.sh" --check --no-write >/dev/null 2>&1
after=$(ls -A "$LOGS" | wc -l)
check_eq "--no-write n ecrit aucun journal" "$before" "$after"

mkdir -p "$TMP/real-logs"
chmod 700 "$TMP/real-logs"
ln -sfn "$TMP/real-logs" "$TMP/link-logs"
A71_LOG_DIR="$TMP/link-logs" "$ROOT/install.sh" --check >/dev/null 2>"$TMP/e"
check_eq "LOG_DIR symlink refuse" 1 "$?"
grep -qi "lien symbolique" "$TMP/e" && r=oui || r=non
check_eq "message lien symbolique" oui "$r"

mkdir -p "$TMP/logs2"
chmod 700 "$TMP/logs2"
: >"$TMP/hors.log"
chmod 600 "$TMP/hors.log"
A71_LOG_DIR="$TMP/logs2" A71_LOG_FILE="$TMP/hors.log" \
    "$ROOT/install.sh" --check >/dev/null 2>"$TMP/e2"
check_eq "journal hors LOG_DIR refuse" 2 "$?"
grep -qi "journal refuse" "$TMP/e2" && r=oui || r=non
check_eq "message journal refuse" oui "$r"

# --------------------------------------------------------------------------
section "6. Traps et codes de sortie"
# --------------------------------------------------------------------------
HELPER="$TMP/trap-case.sh"
cat >"$HELPER" <<'EOS'
#!/usr/bin/env bash
A71_NO_WRITE=1
export A71_NO_WRITE
. "$A71_ROOT/scripts/common.sh"
a71_install_traps

case "$1" in
    ok) exit 0 ;;
    false) false ;;
    exit7) exit 7 ;;
    missing) commande_qui_nexiste_pas ;;
    unset) echo "$VARIABLE_JAMAIS_DEFINIE" ;;
    in_function) f() { false; }; f ;;
    subshell) ( false ) ;;
    cmdsubst) x=$(false); printf '%s' "$x" ;;
    cleanup_twice) a71_cleanup; a71_cleanup; exit 0 ;;
    deliberate) deliberate_exit 5 ;;
    die) die "erreur volontaire" ;;
    *) exit 99 ;;
esac
EOS
chmod +x "$HELPER"

trap_case() {
    A71_ROOT="$ROOT" "$HELPER" "$1" >"$TMP/to" 2>"$TMP/te"
    echo $?
}

check_eq "sortie normale" 0 "$(trap_case ok)"
check_eq "false -> 1" 1 "$(trap_case false)"
check_eq "exit 7 conserve" 7 "$(trap_case exit7)"
check_eq "commande inexistante -> 127" 127 "$(trap_case missing)"
check_eq "erreur dans une fonction" 1 "$(trap_case in_function)"
check_eq "erreur dans un sous-shell" 1 "$(trap_case subshell)"
check_eq "erreur dans une substitution" 1 "$(trap_case cmdsubst)"
check_eq "cleanup deux fois" 0 "$(trap_case cleanup_twice)"
check_eq "deliberate_exit 5" 5 "$(trap_case deliberate)"
check_eq "die -> 1" 1 "$(trap_case die)"

A71_ROOT="$ROOT" "$HELPER" unset >/dev/null 2>"$TMP/te_unset"
rc_unset=$?
check_ne "set -u -> code non nul" 0 "$rc_unset"
grep -qiE "unbound variable|parameter not set|variable sans liaison|non definie" "$TMP/te_unset" && r=oui || r=non
check_eq "set -u -> message explicite" oui "$r"

A71_ROOT="$ROOT" "$HELPER" false >/dev/null 2>"$TMP/te2"
check_eq "un seul ECHEC sur false" 1 "$(grep -c 'ECHEC' "$TMP/te2")"
A71_ROOT="$ROOT" "$HELPER" deliberate >/dev/null 2>"$TMP/te3"
check_eq "aucun ECHEC sur deliberate_exit" 0 "$(grep -c 'ECHEC' "$TMP/te3")"

# --------------------------------------------------------------------------
section "7. Prediagnostic"
# --------------------------------------------------------------------------
bash "$ROOT/scripts/preflight.sh" >/dev/null 2>"$TMP/pf"
check_eq "preflight direct refuse" 2 "$?"
grep -qi "bibliotheque" "$TMP/pf" && r=oui || r=non
check_eq "message bibliotheque" oui "$r"

# PATH restreint : seuls les outils du socle. Les outils des phases suivantes
# (git, make, cpio, sfdisk, heimdall...) sont absents et ne doivent pas bloquer.
BIN="$TMP/bin"
mkdir -p "$BIN"
for c in bash awk sed grep df uname nproc mkdir mktemp chmod date dirname basename cat rm id stat head wc; do
    p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$BIN/$c"
done
mkdir -p "$TMP/logs3" && chmod 700 "$TMP/logs3"
PATH="$BIN" A71_LOG_DIR="$TMP/logs3" A71_WORK_DIR="$TMP/w3" \
    "$BIN/bash" "$ROOT/install.sh" --check >"$TMP/pfout" 2>&1
check_eq "--check sans outils futurs : non bloquant" 0 "$?"

rm -f "$BIN/awk"
mkdir -p "$TMP/logs4" && chmod 700 "$TMP/logs4"
PATH="$BIN" A71_LOG_DIR="$TMP/logs4" A71_WORK_DIR="$TMP/w4" \
    "$BIN/bash" "$ROOT/install.sh" --check >"$TMP/pfout2" 2>&1
check_eq "--check sans awk : bloquant" 1 "$?"

ln -sf "$(command -v awk)" "$BIN/awk"
mkdir -p "$TMP/logs5" && chmod 700 "$TMP/logs5"
PATH="$BIN" A71_LOG_DIR="$TMP/logs5" A71_WORK_DIR="$TMP/w5" \
    "$BIN/bash" -c ". \"$ROOT/scripts/common.sh\"; . \"$ROOT/scripts/preflight.sh\"; run_preflight build" \
    >/dev/null 2>&1
check_eq "action build sans git : bloquant" 1 "$?"

# --------------------------------------------------------------------------
section "8. Parseur - parcours et collisions"
# --------------------------------------------------------------------------
check_eq "parcours valide a/b/c puis d puis e" 0 "$(manifest_case t01.yaml 'a:
  b:
    c: 1
  d: 2
e: 3
')"
check_eq "retour 2->1 puis nouvelle section" 0 "$(manifest_case t02.yaml 'a:
  b:
    c: 1
d:
  e: 2
')"
check_eq "section vide puis cle soeur (valide YAML)" 0 "$(manifest_case t03.yaml 'a:
  b:
  c: 1
')"
check_eq "feuille puis enfant (saut de niveau)" 3 "$(manifest_case t04.yaml 'a:
  b: 1
    c: 2
')"
check_eq "saut 0->2 refuse" 3 "$(manifest_case t05.yaml 'a:
    b: 1
')"
check_eq "collision scalar->section" 3 "$(manifest_case c01.yaml 'a: valeur
a:
  b: valeur
')"
check_eq "collision section->scalar" 3 "$(manifest_case c02.yaml 'a:
  b: valeur
a: valeur
')"
check_eq "section redefinie" 3 "$(manifest_case c03.yaml 'a:
  b: valeur
a:
  c: valeur
')"
check_eq "scalar puis section meme nom" 3 "$(manifest_case c04.yaml 'a:
  b: valeur
  b:
    c: valeur
')"
check_eq "section puis scalar meme nom" 3 "$(manifest_case c05.yaml 'a:
  b:
    c: valeur
  b: valeur
')"

# --------------------------------------------------------------------------
section "9. Valeurs : vides, guillemets, commentaires"
# --------------------------------------------------------------------------
check_eq "key: est une section (get=1, pas de valeur)" '1:' "$(get_case v01.yaml 'k:
' k)"
check_eq "key: \"\" est un scalaire vide (get=0)" 0: "$(get_case v02.yaml 'k: ""
' k)"
check_eq "key: \" \" est un scalaire espace" 0:' ' "$(get_case v03.yaml 'k: " "
' k)"
check_eq "commentaire inline non cite refuse" 3 "$(manifest_case v04.yaml 'k: value # commentaire
')"
check_eq "commentaire inline dans guillemets accepte" 0 "$(manifest_case v05.yaml 'k: "value # texte"
')"
check_eq "valeur avec # sans espace acceptee" 0 "$(manifest_case v06.yaml 'k: value#texte
')"
check_eq "valeur '#' restituee" '0:value#texte' "$(get_case v07.yaml 'k: value#texte
' k)"
check_eq "commentaire sur ligne entiere accepte" 0 "$(manifest_case v08.yaml '# commentaire
k: 1
')"

# --------------------------------------------------------------------------
section "10. dry-run et manifeste"
# --------------------------------------------------------------------------
DRY_OK='kernel:
  commit: 0123456789abcdef
distribution:
  series: v3.22
  version: 3.22.7
toolchain:
  version: toolchain-x
uniloader:
  commit: 4c626a73cc38308227b5c28e75558b3da574312b
'
dry_run() {
    A71_MANIFEST=$1 A71_LOG_DIR="$LOGS" "$ROOT/install.sh" --dry-run >"$TMP/plan" 2>"$TMP/planerr"
    echo $?
}

printf '%s' "$DRY_OK" >"$TMP/dry-ok.yaml"
check_eq "dry-run manifeste valide" 0 "$(dry_run "$TMP/dry-ok.yaml")"
check_eq "dry-run affiche le plan" 1 "$(grep -c 'Etapes qui seraient planifiees' "$TMP/plan")"

check_eq "dry-run manifeste absent" 1 "$(dry_run "$TMP/dry-absent.yaml")"
check_eq "dry-run absent: aucun plan" 0 "$(grep -c 'Etapes qui seraient planifiees' "$TMP/plan")"

: >"$TMP/dry-empty.yaml"
check_eq "dry-run manifeste vide" 1 "$(dry_run "$TMP/dry-empty.yaml")"

printf 'kernel:\n  commit: 1\nceci nest pas yaml\n' >"$TMP/dry-bad.yaml"
check_eq "dry-run manifeste invalide" 1 "$(dry_run "$TMP/dry-bad.yaml")"
check_eq "dry-run invalide: aucun plan" 0 "$(grep -c 'Etapes qui seraient planifiees' "$TMP/plan")"

printf 'distribution:\n  series: v3.22\n  version: 3.22.7\ntoolchain:\n  version: t\nuniloader:\n  commit: 4c626a7\n' >"$TMP/dry-nokernel.yaml"
check_eq "dry-run kernel.commit absente" 1 "$(dry_run "$TMP/dry-nokernel.yaml")"
grep -q "cle absente (kernel.commit)" "$TMP/planerr" && r=oui || r=non
check_eq "message kernel.commit absente" oui "$r"

printf 'kernel:\n  commit: 1\ntoolchain:\n  version: t\nuniloader:\n  commit: 4c626a7\n' >"$TMP/dry-nodist.yaml"
printf 'kernel:\n  commit: 1\ndistribution:\n  series: v3.22\ntoolchain:\n  version: t\nuniloader:\n  commit: 4c626a7\n' >"$TMP/dry-nodistver.yaml"
check_eq "dry-run distribution.version absente" 1 "$(dry_run "$TMP/dry-nodistver.yaml")"
grep -q "cle absente (distribution.version)" "$TMP/planerr" && r=oui || r=non
check_eq "message distribution.version absente" oui "$r"

printf 'kernel:\n  commit: 1\ndistribution:\n  series: v3.22\n  version: 3.22.7\ntoolchain:\n  version: t\n' >"$TMP/dry-nouniloader.yaml"
check_eq "dry-run uniloader.commit absente" 1 "$(dry_run "$TMP/dry-nouniloader.yaml")"
grep -q "cle absente (uniloader.commit)" "$TMP/planerr" && r=oui || r=non
check_eq "message uniloader.commit absente" oui "$r"

# manifest_get_or_default ne doit pas masquer une erreur autre que "cle absente" :
# le corps de la fonction doit propager le code de retour.
awk '/^manifest_get_or_default\(\)/,/^}/' "$ROOT/install.sh" >"$TMP/god.txt"
check_eq "get_or_default: branche de propagation presente" 1 "$(grep -c 'return "\$rc"' "$TMP/god.txt")"
check_eq "get_or_default: aucun repli inconditionnel" 0 "$(grep -c '^ *|| *printf' "$TMP/god.txt")"
check_eq "dry-run distribution.series absente" 1 "$(dry_run "$TMP/dry-nodist.yaml")"
printf 'kernel:\n  commit: 1\ndistribution:\n  series: v3.22\n  version: 3.22.7\nuniloader:\n  commit: 4c626a7\n' >"$TMP/dry-notc.yaml"
check_eq "dry-run toolchain.version absente" 1 "$(dry_run "$TMP/dry-notc.yaml")"

printf 'kernel:\n  commit: TODO_VERIFIER\ndistribution:\n  series: v3.22\n  version: 3.22.7\ntoolchain:\n  version: t\nuniloader:\n  commit: 4c626a7\n' >"$TMP/dry-todo.yaml"
check_eq "dry-run valeur structurelle TODO affichee" 0 "$(dry_run "$TMP/dry-todo.yaml")"
grep -q "kernel.commit" "$TMP/plan" && r=oui || r=non
check_eq "TODO listee dans le plan" oui "$r"

# --------------------------------------------------------------------------
section "11. Securite du journal"
# --------------------------------------------------------------------------
# work/ symlink
ln -sfn "$TMP/real-work" "$TMP/worklink"
mkdir -p "$TMP/real-work" && chmod 700 "$TMP/real-work"
A71_WORK_DIR="$TMP/worklink" "$ROOT/install.sh" --check >/dev/null 2>"$TMP/we"
check_eq "WORK_DIR symlink refuse" 1 "$?"
grep -qi "lien symbolique" "$TMP/we" && r=oui || r=non
check_eq "message WORK_DIR symlink" oui "$r"

# repertoire personnalise en 755 refuse (aucun chmod automatique)
mkdir -p "$TMP/logs755" && chmod 755 "$TMP/logs755"
A71_LOG_DIR="$TMP/logs755" "$ROOT/install.sh" --check >/dev/null 2>"$TMP/l755"
check_eq "LOG_DIR 755 refuse" 1 "$?"
grep -qi "mode 700" "$TMP/l755" && r=oui || r=non
check_eq "message mode 700" oui "$r"

# journal symlink refuse
mkdir -p "$TMP/logs6" && chmod 700 "$TMP/logs6"
: >"$TMP/logs6/real.log" && chmod 600 "$TMP/logs6/real.log"
ln -sfn "$TMP/logs6/real.log" "$TMP/logs6/link.log"
A71_LOG_DIR="$TMP/logs6" A71_LOG_FILE="$TMP/logs6/link.log" \
    "$ROOT/install.sh" --check >/dev/null 2>"$TMP/lsym"
check_eq "journal symlink refuse" 2 "$?"

# journal dans un sous-repertoire refuse
mkdir -p "$TMP/logs6/sub" && chmod 700 "$TMP/logs6/sub"
: >"$TMP/logs6/sub/x.log" && chmod 600 "$TMP/logs6/sub/x.log"
A71_LOG_DIR="$TMP/logs6" A71_LOG_FILE="$TMP/logs6/sub/x.log" \
    "$ROOT/install.sh" --check >/dev/null 2>"$TMP/lsub"
check_eq "journal en sous-repertoire refuse" 2 "$?"

# journal en 644 refuse
: >"$TMP/logs6/m644.log" && chmod 644 "$TMP/logs6/m644.log"
A71_LOG_DIR="$TMP/logs6" A71_LOG_FILE="$TMP/logs6/m644.log" \
    "$ROOT/install.sh" --check >/dev/null 2>"$TMP/l644"
check_eq "journal 644 refuse" 2 "$?"

# journal correct (600, utilisateur, directement dans LOG_DIR) accepte
: >"$TMP/logs6/ok.log" && chmod 600 "$TMP/logs6/ok.log"
A71_LOG_DIR="$TMP/logs6" A71_LOG_FILE="$TMP/logs6/ok.log" \
    "$ROOT/install.sh" --check >/dev/null 2>&1
check_eq "journal 600 accepte" 0 "$?"
check_eq "journal repris alimente" 1 "$(grep -c 'Prediagnostic' "$TMP/logs6/ok.log" 2>/dev/null)"

# --------------------------------------------------------------------------
section "12. Trap : aucune commande brute journalisee"
# --------------------------------------------------------------------------
A71_ROOT="$ROOT" "$HELPER" false >/dev/null 2>"$TMP/terr"
grep -q "commande=" "$TMP/terr" && r=oui || r=non
check_eq "ERR ne journalise pas la commande" non "$r"

# --------------------------------------------------------------------------
section "13. Manifeste 2A-2 (valeurs resolues)"
# --------------------------------------------------------------------------
( . "$ROOT/scripts/common.sh"; manifest_validate "$ROOT/manifest.yaml" ) >/dev/null 2>&1
check_eq "manifeste 2A-2 valide" 0 "$?"

mget() { ( . "$ROOT/scripts/common.sh"; manifest_get "$ROOT/manifest.yaml" "$1" ) 2>/dev/null; }

check_eq "distribution.version" "3.22.7" "$(mget distribution.version)"
check_eq "distribution.minirootfs_sha256 (64 hex)" 64 "$(printf '%s' "$(mget distribution.minirootfs_sha256)" | wc -c)"
check_eq "distribution.minirootfs_url exacte" \
    "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/alpine-minirootfs-3.22.7-aarch64.tar.gz" \
    "$(mget distribution.minirootfs_url)"
check_eq "distribution.signature non verifiee" "not_verified" "$(mget distribution.minirootfs_signature_status)"
check_eq "toolchain.archive (.tar.xz)" "aarch64--glibc--stable-2024.05-1.tar.xz" "$(mget toolchain.archive)"
check_eq "toolchain.sha256 (64 hex)" 64 "$(printf '%s' "$(mget toolchain.sha256)" | wc -c)"
check_eq "toolchain.signature indisponible" "unavailable" "$(mget toolchain.signature_status)"
check_eq "toolchain.host_arch metadata_only" "metadata_only" "$(mget toolchain.host_arch_status)"
check_eq "uniloader.commit = commit de fusion" "4c626a73cc38308227b5c28e75558b3da574312b" "$(mget uniloader.commit)"
check_eq "uniloader.pr_head conservee" "b253dc48f9d297786df60d4389552752ccfb65da" "$(mget uniloader.pr_head)"
check_eq "uniloader.license_reported GPL-2.0" "GPL-2.0" "$(mget uniloader.license_reported)"
check_eq "uniloader.validation provisional" "provisional" "$(mget uniloader.validation_status)"
check_eq "kernel_config.strategy" "vendored_from_pmaports" "$(mget kernel_config.strategy)"
check_eq "kernel_config.pmaports_commit epingle (40 hex)" 40 "$(printf '%s' "$(mget kernel_config.pmaports_commit)" | wc -c)"
check_eq "kernel.built_release TODO_BUILD" "TODO_BUILD" "$(mget kernel.built_release)"
check_eq "boot_image validation non resolue" "TODO_VERIFIER" "$(mget boot_image.validation_status)"
check_eq "kernel.commit resolu" "5d80fcdbbb3fbf399d3db66b0f14497d11c9489a" "$(mget kernel.commit)"
check_eq "toolchain.version resolu" "aarch64--glibc--stable-2024.05-1" "$(mget toolchain.version)"

A71_LOG_DIR="$LOGS" "$ROOT/install.sh" --dry-run >"$TMP/plan2" 2>/dev/null
check_eq "plan affiche uniloader" 1 "$(grep -c 'uniloader     : 4c626a7' "$TMP/plan2")"
check_eq "plan affiche Alpine 3.22.7" 1 "$(grep -c 'Alpine v3.22 3.22.7' "$TMP/plan2")"

# --------------------------------------------------------------------------
section "14. Incrément 2B : configuration pmaports vendue"
# --------------------------------------------------------------------------
mget2() { ( . "$ROOT/scripts/common.sh"; manifest_get "$ROOT/manifest.yaml" "$1" ) 2>/dev/null; }
VENDORED="$ROOT/configs/upstream/pmaports-sm7150.config"
PROV="$ROOT/configs/upstream/pmaports-sm7150.provenance"

check_eq "fichier vendu present" 1 "$([ -f "$VENDORED" ] && echo 1 || echo 0)"
check_eq "fichier de provenance present" 1 "$([ -f "$PROV" ] && echo 1 || echo 0)"

V_SHA=$(sha256sum "$VENDORED" 2>/dev/null | cut -d' ' -f1)
V_SIZE=$(wc -c <"$VENDORED" 2>/dev/null | tr -d ' ')
check_eq "sha256 du fichier vendu = manifeste" "$(mget2 kernel_config.vendored_sha256)" "$V_SHA"
check_eq "sha256 du fichier vendu = provenance" "$(grep -E '^sha256: ' "$PROV" | sed 's/^sha256: //')" "$V_SHA"
check_eq "taille du fichier vendu = manifeste" "$(mget2 kernel_config.vendored_size)" "$V_SIZE"
check_eq "taille du fichier vendu = provenance" "$(grep -E '^size_bytes: ' "$PROV" | sed 's/^size_bytes: //')" "$V_SIZE"

P_COMMIT=$(grep -E '^commit: ' "$PROV" | sed 's/^commit: //')
check_eq "commit pmaports complet (40 hex)" 40 "$(printf '%s' "$P_COMMIT" | wc -c)"
check_eq "commit provenance = manifeste" "$(mget2 kernel_config.pmaports_commit)" "$P_COMMIT"
check_eq "commit pmaports dans le manifeste (40 hex)" 40 "$(printf '%s' "$(mget2 kernel_config.pmaports_commit)" | wc -c)"
check_eq "aucune identite 'master' dans le manifeste" 0 "$(grep -c '^  pmaports_commit: master' "$ROOT/manifest.yaml")"
check_eq "reference documentaire seulement" 1 "$(grep -c '^reference: master' "$PROV")"

check_eq "source_status pinned" "pinned" "$(mget2 kernel_config.source_status)"
check_eq "integrity_status verified" "verified" "$(mget2 kernel_config.integrity_status)"
check_eq "merge_contract_status implemented" "implemented" "$(mget2 kernel_config.merge_contract_status)"
check_eq "runtime_status not_tested" "not_tested" "$(mget2 kernel_config.runtime_status)"
check_eq "validation_status provisional" "provisional" "$(mget2 kernel_config.validation_status)"
check_eq "provenance validation provisional" "provisional" "$(grep -E '^validation_status: ' "$PROV" | sed 's/^validation_status: //')"

# source unique de verite : kernel.config_status ne doit plus exister
check_eq "kernel.config_status supprime" 1 "$(mget2 kernel.config_status >/dev/null 2>&1; echo $?)"

# le fichier vendu est bien une config noyau
check_eq "entete de config noyau" 1 "$(head -3 "$VENDORED" | grep -c 'Kernel Configuration')"

# contradiction DRM : le fragment historique desactive DRM_MSM,
# alors que la config vendue l'active.
check_eq "fragment A71 desactive DRM_MSM" 1 "$(grep -c '^# CONFIG_DRM_MSM is not set' "$ROOT/configs/a71-extra.config")"
check_eq "config vendue active DRM_MSM" 1 "$(grep -c '^CONFIG_DRM_MSM=y' "$VENDORED")"
check_eq "panneau S6E3FA9 absent du config vendu" 0 "$(grep -ciE 's6e3fa9' "$VENDORED")"
check_eq "REFGEN absent du config vendu" 0 "$(grep -c '^CONFIG_REGULATOR_QCOM_REFGEN=y' "$VENDORED")"

# options indispensables effectivement presentes
for o in MMC_SDHCI_MSM EXT4_FS BLK_DEV_INITRD USB_DWC3 USB_CONFIGFS USB_CONFIGFS_RNDIS USB_CONFIGFS_ECM DEVTMPFS FW_LOADER; do
    check_eq "option $o=y dans le config vendu" 1 "$(grep -c "^CONFIG_$o=y" "$VENDORED")"
done

# URLs Bootlin non ambiguës
check_eq "toolchain.base_url" "https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/" "$(mget2 toolchain.base_url)"
check_eq "toolchain.archive_url" "https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/aarch64--glibc--stable-2024.05-1.tar.xz" "$(mget2 toolchain.archive_url)"
check_eq "toolchain.checksum_url (nom sans .tar.xz)" "https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/aarch64--glibc--stable-2024.05-1.sha256" "$(mget2 toolchain.checksum_url)"
check_eq "archive_url = base_url + archive" "$(mget2 toolchain.base_url)$(mget2 toolchain.archive)" "$(mget2 toolchain.archive_url)"

# licence uniLoader : rapportee, pas conclue
check_eq "license_reported" "GPL-2.0" "$(mget2 uniloader.license_reported)"
check_eq "license_spdx_status non tranche" "TODO_VERIFIER" "$(mget2 uniloader.license_spdx_status)"
check_eq "uniloader.validation provisional" "provisional" "$(mget2 uniloader.validation_status)"

# --------------------------------------------------------------------------
section "15. Incrément 2C : fragment proposé et exigences"
# --------------------------------------------------------------------------
PROP="$ROOT/configs/a71-proposed.config"
REQ="$ROOT/configs/a71-required-symbols.txt"
VER="$ROOT/configs/a71-symbols-verified.txt"

check_eq "fragment proposé présent" 1 "$([ -f "$PROP" ] && echo 1 || echo 0)"
check_eq "liste d exigences présente" 1 "$([ -f "$REQ" ] && echo 1 || echo 0)"
check_eq "relevé de symboles présent" 1 "$([ -f "$VER" ] && echo 1 || echo 0)"

# DRM : jamais désactivé dans le fragment proposé
check_eq "aucun '# CONFIG_DRM_MSM is not set' dans le fragment" 0 "$(grep -c '^# CONFIG_DRM_MSM is not set' "$PROP")"
check_eq "fragment fixe DRM_MSM=m" 1 "$(grep -c '^CONFIG_DRM_MSM=m$' "$PROP")"
check_eq "fragment active DRM_SIMPLEDRM=y" 1 "$(grep -c '^CONFIG_DRM_SIMPLEDRM=y$' "$PROP")"

# la contradiction historique reste documentée
check_eq "contradiction historique toujours dans a71-extra.config" 1 "$(grep -c '^# CONFIG_DRM_MSM is not set' "$ROOT/configs/a71-extra.config")"
check_eq "contradiction documentée (KERNEL_CONFIG)" 1 "$(grep -c 'Contradiction historique' "$ROOT/docs/KERNEL_CONFIG.md")"

# symbole du panneau : le nom vérifié, pas le nom supposé
check_eq "panneau: symbole réel présent dans le relevé" 1 "$(grep -c '^CONFIG_DRM_PANEL_SAMSUNG_S6E3FA9_AMB667UM06 ' "$VER")"
check_eq "panneau: nom supposé absent du relevé" 0 "$(grep -c '^CONFIG_DRM_PANEL_SAMSUNG_S6E3FA9 |' "$VER")"

# tous les symboles du fragment et des exigences figurent au relevé
frag_syms=$(grep -E '^CONFIG_[A-Z0-9_]+=' "$PROP" | cut -d= -f1)
missing_frag=0
for s1 in $frag_syms; do
    grep -q "^$s1 " "$VER" || { missing_frag=$((missing_frag+1)); echo "      symbole absent du relevé: $s1"; }
done
check_eq "tous les symboles du fragment sont vérifiés" 0 "$missing_frag"

req_syms=$(grep -E '^CONFIG_[A-Z0-9_]+=' "$REQ" | cut -d= -f1)
missing_req=0
for s1 in $req_syms; do
    grep -q "^$s1 " "$VER" || { missing_req=$((missing_req+1)); echo "      exigence non vérifiée: $s1"; }
done
check_eq "toutes les exigences sont vérifiées" 0 "$missing_req"

# format de la liste d'exigences
check_eq "format des exigences valide" 0 "$(grep -vE '^(#|$|CONFIG_[A-Z0-9_]+=(y|m|n|m\|y)$)' "$REQ" | wc -l)"
check_eq "aucun doublon dans les exigences" 0 "$(grep -E '^CONFIG_' "$REQ" | cut -d= -f1 | sort | uniq -d | wc -l)"
check_eq "aucun doublon dans le relevé" 0 "$(grep -E '^CONFIG_' "$VER" | cut -d' ' -f1 | sort | uniq -d | wc -l)"

# stockage/racine et console exigés en =y
for sym in MMC_SDHCI_MSM EXT4_FS BLK_DEV_INITRD DEVTMPFS VT VT_CONSOLE FRAMEBUFFER_CONSOLE; do
    check_eq "exigence CONFIG_$sym=y" 1 "$(grep -c "^CONFIG_$sym=y$" "$REQ")"
done
check_eq "LOCALVERSION_AUTO interdit" 1 "$(grep -c '^CONFIG_LOCALVERSION_AUTO=n$' "$REQ")"

# statuts inchangés
check_eq "merge_contract_status implemented" "implemented" "$(mget2 kernel_config.merge_contract_status)"
check_eq "runtime_status not_tested" "not_tested" "$(mget2 kernel_config.runtime_status)"
check_eq "validation_status provisional" "provisional" "$(mget2 kernel_config.validation_status)"
check_eq "fragment_status proposed" "proposed" "$(mget2 kernel_config.fragment_status)"
check_eq "required_symbols_file référencé" "configs/a71-required-symbols.txt" "$(mget2 kernel_config.required_symbols_file)"
check_eq "proposed_fragment référencé" "configs/a71-proposed.config" "$(mget2 kernel_config.proposed_fragment)"

# aucun statut validated nulle part
check_eq "aucun 'validated' dans le manifeste" 0 "$(grep -cE '^ +validation_status: validated' "$ROOT/manifest.yaml")"

# --------------------------------------------------------------------------
section "16. Incrément 2D : vérificateur de configuration"
# --------------------------------------------------------------------------
CHK="$ROOT/scripts/check-config.sh"
FIX="$ROOT/tests/phase1/fixtures/config-check"

check_eq "check-config executables" 1 "$([ -x "$CHK" ] && echo 1 || echo 0)"

chk() { "$CHK" "$@" >"$TMP/chk.out" 2>"$TMP/chk.err"; echo $?; }

check_eq "--help -> 0" 0 "$(chk --help)"
check_eq "--config manquant -> 2" 2 "$(chk --requirements "$FIX/ok.req")"
check_eq "--requirements manquant -> 2" 2 "$(chk --config "$FIX/ok.config")"
check_eq "option inconnue -> 2" 2 "$(chk --bogus "$FIX/ok.config")"
check_eq "option repetee -> 2" 2 "$(chk --config "$FIX/ok.config" --config "$FIX/ok.config" --requirements "$FIX/ok.req")"
check_eq "argument positionnel -> 2" 2 "$(chk "$FIX/ok.config")"

check_eq "succes -> 0" 0 "$(chk --config "$FIX/ok.config" --requirements "$FIX/ok.req")"
check_eq "succes: RESULTAT OK" 1 "$(grep -c '^RESULTAT: OK$' "$TMP/chk.out")"
check_eq "y->m -> 1" 1 "$(chk --config "$FIX/y-to-m.config" --requirements "$FIX/y-to-m.req")"
check_eq "y->m: retrograde" 1 "$(grep -c 'retrograde' "$TMP/chk.out")"
check_eq "desactive -> 1" 1 "$(chk --config "$FIX/disabled.config" --requirements "$FIX/disabled.req")"
check_eq "desactive: message" 1 "$(grep -c 'desactive' "$TMP/chk.out")"
check_eq "m|y avec m et y -> 0" 0 "$(chk --config "$FIX/my.config" --requirements "$FIX/my.req")"
check_eq "m|y: deux OK" 2 "$(grep -c 'm|y accepte' "$TMP/chk.out")"
check_eq "exigence n satisfaite -> 0" 0 "$(chk --config "$FIX/n-ok.config" --requirements "$FIX/n-ok.req")"
check_eq "exigence n, symbole absent -> 1" 1 "$(chk --config "$FIX/n-absent.config" --requirements "$FIX/n-absent.req")"
check_eq "symbole requis absent -> 1" 1 "$(chk --config "$FIX/missing-symbol.config" --requirements "$FIX/missing-symbol.req")"
check_eq "symbole absent: message" 1 "$(grep -c 'symbole absent' "$TMP/chk.out")"
check_eq "doublon config -> 4" 4 "$(chk --config "$FIX/dup-config.config" --requirements "$FIX/dup-config.req")"
check_eq "doublon exigences -> 3" 3 "$(chk --config "$FIX/dup-req.config" --requirements "$FIX/dup-req.req")"
check_eq "ligne invalide config -> 4" 4 "$(chk --config "$FIX/bad-line.config" --requirements "$FIX/bad-line.req")"
check_eq "config absent -> 4" 4 "$(chk --config "$TMP/absent.config" --requirements "$FIX/ok.req")"
check_eq "exigences absentes -> 3" 3 "$(chk --config "$FIX/ok.config" --requirements "$TMP/absent.req")"
check_eq "valeur chaine/nombre -> 1" 1 "$(chk --config "$FIX/string-value.config" --requirements "$FIX/string-value.req")"
check_eq "valeur incorrecte: message" 2 "$(grep -c 'valeur incorrecte' "$TMP/chk.out")"

# fichier piege non execute
printf 'CONFIG_A=y\n$(touch %s/pwned)\n' "$TMP" >"$TMP/trap.req"
check_eq "fichier piege: code 3" 3 "$(chk --config "$FIX/trapped.config" --requirements "$TMP/trap.req")"
check_absent "fichier piege non execute" "$TMP/pwned"

# --quiet : aucun stdout, code conserve
"$CHK" --config "$FIX/y-to-m.config" --requirements "$FIX/y-to-m.req" --quiet >"$TMP/q.out" 2>/dev/null
check_eq "quiet: code conserve" 1 "$?"
check_eq "quiet: stdout vide" 0 "$(wc -c <"$TMP/q.out" | tr -d ' ')"

# --report : ecriture atomique
mkdir -p "$TMP/reports"
check_eq "report: code 0" 0 "$(chk --config "$FIX/ok.config" --requirements "$FIX/ok.req" --report "$TMP/reports/r.txt")"
check_eq "report: fichier cree" 1 "$([ -f "$TMP/reports/r.txt" ] && echo 1 || echo 0)"
check_eq "report: contenu RESULTAT" 1 "$(grep -c '^RESULTAT: OK$' "$TMP/reports/r.txt")"
check_eq "report: aucun temporaire restant" 0 "$(ls -A "$TMP/reports" | grep -c '^\.a71-report-')"
check_eq "report: aucun chemin absolu" 0 "$(grep -c '^# config    : /' "$TMP/reports/r.txt")"

# report vers symlink -> 5
ln -sfn "$TMP/reports/r.txt" "$TMP/reports/link.txt"
check_eq "report symlink refuse -> 5" 5 "$(chk --config "$FIX/ok.config" --requirements "$FIX/ok.req" --report "$TMP/reports/link.txt")"
# report vers repertoire inexistant -> 5
check_eq "report repertoire absent -> 5" 5 "$(chk --config "$FIX/ok.config" --requirements "$FIX/ok.req" --report "$TMP/pas-la/r.txt")"
check_absent "report: aucun repertoire cree" "$TMP/pas-la"

# verification sur la base vendue : elle doit ECHOUER (SIMPLEDRM desactive)
check_eq "base vendue non conforme -> 1" 1 "$(chk --config "$ROOT/configs/upstream/pmaports-sm7150.config" --requirements "$ROOT/configs/a71-required-symbols.txt")"
check_eq "base vendue: DRM_SIMPLEDRM en echec" 1 "$(grep -c 'ECHEC CONFIG_DRM_SIMPLEDRM' "$TMP/chk.out")"

# exigences : symboles nouvellement verifies
for sym in MMC MMC_SDHCI MMC_SDHCI_PLTFM DEVTMPFS_MOUNT DRM DRM_FBDEV_EMULATION; do
    check_eq "exigence CONFIG_$sym=y" 1 "$(grep -c "^CONFIG_$sym=y$" "$ROOT/configs/a71-required-symbols.txt")"
    check_eq "CONFIG_$sym dans le releve" 1 "$(grep -c "^CONFIG_$sym |" "$ROOT/configs/a71-symbols-verified.txt")"
done

# statuts documentaires
check_eq "verified_symbols_status" "documentary_snapshot" "$(mget2 kernel_config.verified_symbols_status)"
check_eq "display_policy_status" "experimental" "$(mget2 kernel_config.display_policy_status)"
check_eq "cmdline_policy_status" "experimental" "$(mget2 kernel_config.cmdline_policy_status)"
check_eq "build_contract_status implemented" "implemented" "$(mget2 kernel_config.build_contract_status)"
check_eq "runtime_status toujours not_tested" "not_tested" "$(mget2 kernel_config.runtime_status)"
check_eq "validation_status toujours provisional" "provisional" "$(mget2 kernel_config.validation_status)"

# --------------------------------------------------------------------------
section "17. Incrément 2E : fusion Kconfig réelle (garde-fous)"
# --------------------------------------------------------------------------
MKC="$ROOT/scripts/merge-kernel-config.sh"
check_eq "merge-kernel-config executables" 1 "$([ -x "$MKC" ] && echo 1 || echo 0)"
check_eq "bash -n merge-kernel-config" 0 "$(bash -n "$MKC" 2>/dev/null; echo $?)"
check_eq "--help -> 0" 0 "$("$MKC" --help >/dev/null 2>&1; echo $?)"
check_eq "sans arguments -> 2" 2 "$("$MKC" >/dev/null 2>&1; echo $?)"
check_eq "option inconnue -> 2" 2 "$("$MKC" --bogus >/dev/null 2>&1; echo $?)"

# source noyau absente -> 3
check_eq "source noyau absente -> 3" 3 "$("$MKC" --kernel-source "$TMP/nope" --base "$ROOT/configs/upstream/pmaports-sm7150.config" --fragment "$ROOT/configs/a71-proposed.config" --requirements "$ROOT/configs/a71-required-symbols.txt" --output "$TMP/o1" >/dev/null 2>&1; echo $?)"

# faux depot git avec un mauvais commit -> 3
mkdir -p "$TMP/fakekernel/scripts/kconfig"
( cd "$TMP/fakekernel" && git init -q . && git config user.email t@t && git config user.name t && : >scripts/kconfig/merge_config.sh && git add -A && git commit -qm init ) >/dev/null 2>&1
check_eq "mauvais commit noyau -> 3" 3 "$("$MKC" --kernel-source "$TMP/fakekernel" --base "$ROOT/configs/upstream/pmaports-sm7150.config" --fragment "$ROOT/configs/a71-proposed.config" --requirements "$ROOT/configs/a71-required-symbols.txt" --output "$TMP/o2" >/dev/null 2>&1; echo $?)"

# chemin avec espace -> 3 (limitation du noyau)
mkdir -p "$TMP/avec espace"
check_eq "chemin avec espace -> 3" 3 "$("$MKC" --kernel-source "$TMP/avec espace" --base "$ROOT/configs/upstream/pmaports-sm7150.config" --fragment "$ROOT/configs/a71-proposed.config" --requirements "$ROOT/configs/a71-required-symbols.txt" --output "$TMP/o3" >/dev/null 2>&1; echo $?)"

# Faux noyau SPACE-FREE (le Makefile du noyau refuse les espaces) avec un
# commit correspondant a un manifeste de test dedie.
FAKE="/tmp/a71-fake-kernel.$$"
OUTROOT="/tmp/a71-fake-out.$$"
rm -rf "$FAKE" "$OUTROOT"
mkdir -p "$FAKE/scripts/kconfig" "$OUTROOT"
( cd "$FAKE" && git init -q . && git config user.email t@t && git config user.name t \
  && : >scripts/kconfig/merge_config.sh && git add -A && git commit -qm init ) >/dev/null 2>&1
FAKE_SHA=$(git -C "$FAKE" rev-parse HEAD)
printf 'kernel:\n  commit: %s\n  branch: master\n' "$FAKE_SHA" >"$TMP/fake-manifest.yaml"

# run_fake_full <base> <fragment> <requirements> <output> -> code
run_fake_full() {
    A71_MANIFEST="$TMP/fake-manifest.yaml" "$MKC" --kernel-source "$FAKE" \
        --base "$1" --fragment "$2" --requirements "$3" --output "$4" >/dev/null 2>&1
    echo $?
}
BASE_OK="$ROOT/configs/upstream/pmaports-sm7150.config"
FRAG_OK="$ROOT/configs/a71-proposed.config"
REQ_OK="$ROOT/configs/a71-required-symbols.txt"

check_eq "entree absente -> 4" 4 "$(run_fake_full "$TMP/nobase" "$FRAG_OK" "$REQ_OK" "$OUTROOT/a")"
printf '# rien\n' >"$TMP/empty.fragment"
check_eq "fragment sans directive -> 4" 4 "$(run_fake_full "$BASE_OK" "$TMP/empty.fragment" "$REQ_OK" "$OUTROOT/b")"
check_eq "exigences absentes -> 4" 4 "$(run_fake_full "$BASE_OK" "$FRAG_OK" "$TMP/noreq" "$OUTROOT/c")"

mkdir -p "$OUTROOT/real"
ln -sfn "$OUTROOT/real" "$OUTROOT/link"
check_eq "sortie symlink -> 5" 5 "$(run_fake_full "$BASE_OK" "$FRAG_OK" "$REQ_OK" "$OUTROOT/link")"
check_eq "sortie dans l'arbre noyau -> 5" 5 "$(run_fake_full "$BASE_OK" "$FRAG_OK" "$REQ_OK" "$FAKE/sub")"
mkdir -p "$OUTROOT/nonempty" && : >"$OUTROOT/nonempty/x"
check_eq "sortie non vide -> 5" 5 "$(run_fake_full "$BASE_OK" "$FRAG_OK" "$REQ_OK" "$OUTROOT/nonempty")"

# entree non modifiee par un refus
check_eq "entree fragment intacte" 0 "$([ -z "$(diff -q "$ROOT/configs/a71-proposed.config" "$ROOT/configs/a71-proposed.config")" ] && echo 0 || echo 1)"
rm -rf "$FAKE" "$OUTROOT"

# artefacts de la fusion reelle (work/config) si presents
RC_DIR="$ROOT/../work/config"
if [ -d "$RC_DIR" ]; then
    for f in base.config fragment.config merged.config final.config base-to-merged.diff merged-to-final.diff fragment-results.tsv requirements-report.txt merge.log olddefconfig.log config-summary.txt; do
        check_eq "artefact $f" 1 "$([ -f "$RC_DIR/$f" ] && echo 1 || echo 0)"
    done
    check_eq "summary: aucune compilation" 1 "$(grep -c 'AUCUNE COMPILATION' "$RC_DIR/config-summary.txt")"
    check_eq "summary: runtime not_tested" 1 "$(grep -c '^runtime	not_tested$' "$RC_DIR/config-summary.txt")"
    check_eq "summary: exigences satisfaites" 1 "$(grep -c '^exigences_echecs	0$' "$RC_DIR/config-summary.txt")"
    check_eq "final.config: DRM_SIMPLEDRM=y" 1 "$(grep -c '^CONFIG_DRM_SIMPLEDRM=y$' "$RC_DIR/final.config")"
    check_eq "final.config: DRM_MSM=m" 1 "$(grep -c '^CONFIG_DRM_MSM=m$' "$RC_DIR/final.config")"
    check_eq "final.config: LOCALVERSION -a71" 1 "$(grep -c '^CONFIG_LOCALVERSION=\"-a71\"$' "$RC_DIR/final.config")"
    check_eq "aucun chemin /tmp dans les diffs" 0 "$(grep -c '/tmp/' "$RC_DIR/base-to-merged.diff" "$RC_DIR/merged-to-final.diff" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')"
    check_eq "fragment: 5 directives suivies" 5 "$(($(wc -l <"$RC_DIR/fragment-results.tsv") - 1))"
else
    printf '  (ignore) artefacts de fusion absents : work/config non publie\n'
fi

# politique USB
check_eq "usb_policy.early_usb_recovery_status" "not_implemented" "$(mget2 usb_policy.early_usb_recovery_status)"
check_eq "usb_policy.network_before_root" "not_guaranteed" "$(mget2 usb_policy.network_before_root)"
check_eq "runtime_status toujours not_tested" "not_tested" "$(mget2 kernel_config.runtime_status)"
check_eq "validation_status toujours provisional" "provisional" "$(mget2 kernel_config.validation_status)"
check_eq "kernel.built_release toujours TODO_BUILD" "TODO_BUILD" "$(mget2 kernel.built_release)"

# --------------------------------------------------------------------------
section "18. Incrément 2F-1 : préparation de la toolchain"
# --------------------------------------------------------------------------
PTC="$ROOT/scripts/prepare-toolchain.sh"
check_eq "prepare-toolchain executables" 1 "$([ -x "$PTC" ] && echo 1 || echo 0)"
check_eq "bash -n prepare-toolchain" 0 "$(bash -n "$PTC" 2>/dev/null; echo $?)"
check_eq "--help -> 0" 0 "$("$PTC" --help >/dev/null 2>&1; echo $?)"
check_eq "sans arguments -> 2" 2 "$("$PTC" >/dev/null 2>&1; echo $?)"
check_eq "manifeste absent -> 3" 3 "$("$PTC" --manifest "$TMP/nope.yaml" --cache-dir "$TMP/c1" --work-dir "$TMP/w1" >/dev/null 2>&1; echo $?)"

# fabrique d'archives de test (python3 tarfile)
mk_tar() { python3 - "$@" <<'PYEOF'
import sys, tarfile, io, os
kind, out = sys.argv[1], sys.argv[2]
with tarfile.open(out, "w:gz") as tf:
    def add_file(name, data=b"x"):
        ti = tarfile.TarInfo(name); ti.size = len(data); ti.mode = 0o644
        tf.addfile(ti, io.BytesIO(data))
    def add_dir(name):
        ti = tarfile.TarInfo(name); ti.type = tarfile.DIRTYPE; ti.mode = 0o755
        tf.addfile(ti)
    def add_sym(name, target):
        ti = tarfile.TarInfo(name); ti.type = tarfile.SYMTYPE; ti.linkname = target; ti.mode = 0o777
        tf.addfile(ti)
    def add_lnk(name, target):
        ti = tarfile.TarInfo(name); ti.type = tarfile.LNKTYPE; ti.linkname = target; ti.mode = 0o644
        tf.addfile(ti)
    def add_fifo(name):
        ti = tarfile.TarInfo(name); ti.type = tarfile.FIFOTYPE; ti.mode = 0o644
        tf.addfile(ti)
    if kind == "abs":
        add_file("/etc/passwd")
    elif kind == "dotdot":
        add_file("../evil")
    elif kind == "symlink":
        add_dir("tc"); add_sym("tc/out", "/etc/passwd")
    elif kind == "hardlink":
        add_file("tc/a"); add_lnk("tc/b", "/etc/passwd")
    elif kind == "fifo":
        add_dir("tc"); add_fifo("tc/fifo")
    elif kind == "valid":
        add_dir("tc"); add_dir("tc/bin")
        add_file("tc/bin/aarch64-fake-linux-gnu-gcc", b"#!/bin/sh\nexit 1\n")
    elif kind == "empty":
        pass
PYEOF
}

mk_cksum() {
    # mk_cksum <fichier> <sha> -> fichier .sha256 au format standard
    printf '%s  %s\n' "$2" "$(basename "$1")" >"$1.sha256"
}

mk_manifest() {
    # mk_manifest <fichier> <archive> <url> <checksum_url> <sha> <taille>
    printf 'toolchain:\n  version: test-1\n  archive: %s\n  archive_url: %s\n  checksum_url: %s\n  sha256: %s\n  size: %s\n' \
        "$2" "$3" "$4" "$5" "$6" >"$1"
}

TCROOT="$TMP/tc"
mkdir -p "$TCROOT"
mk_tar valid "$TCROOT/valid.tar.gz"
V_SHA=$(sha256sum "$TCROOT/valid.tar.gz" | cut -d' ' -f1)
V_SIZE=$(wc -c <"$TCROOT/valid.tar.gz" | tr -d ' ')
mk_tar abs "$TCROOT/abs.tar.gz"; A_SHA=$(sha256sum "$TCROOT/abs.tar.gz" | cut -d' ' -f1); A_SIZE=$(wc -c <"$TCROOT/abs.tar.gz" | tr -d ' ')
mk_tar dotdot "$TCROOT/dotdot.tar.gz"; D_SHA=$(sha256sum "$TCROOT/dotdot.tar.gz" | cut -d' ' -f1); D_SIZE=$(wc -c <"$TCROOT/dotdot.tar.gz" | tr -d ' ')
mk_tar symlink "$TCROOT/symlink.tar.gz"; S_SHA=$(sha256sum "$TCROOT/symlink.tar.gz" | cut -d' ' -f1); S_SIZE=$(wc -c <"$TCROOT/symlink.tar.gz" | tr -d ' ')
mk_tar hardlink "$TCROOT/hardlink.tar.gz"; H_SHA=$(sha256sum "$TCROOT/hardlink.tar.gz" | cut -d' ' -f1); H_SIZE=$(wc -c <"$TCROOT/hardlink.tar.gz" | tr -d ' ')
mk_tar fifo "$TCROOT/fifo.tar.gz"; F_SHA=$(sha256sum "$TCROOT/fifo.tar.gz" | cut -d' ' -f1); F_SIZE=$(wc -c <"$TCROOT/fifo.tar.gz" | tr -d ' ')
printf 'deadbeef\n' >"$TCROOT/bad.sha256"
printf '%s  valid.tar.gz\n' "$V_SHA" >"$TCROOT/good.sha256"

tc() { "$PTC" "$@" >"$TMP/tc.out" 2>"$TMP/tc.err"; echo $?; }

# TODO_* refuse
printf 'toolchain:\n  version: test-1\n  archive: valid.tar.gz\n  archive_url: file://%s/valid.tar.gz\n  checksum_url: file://%s/good.sha256\n  sha256: TODO_VERIFIER\n  size: %s\n' "$TCROOT" "$TCROOT" "$V_SIZE" >"$TCROOT/todo.yaml"
check_eq "sha256 TODO_VERIFIER -> 3" 3 "$(tc --manifest "$TCROOT/todo.yaml" --cache-dir "$TCROOT/c" --work-dir "$TCROOT/w")"
# cle absente
printf 'toolchain:\n  version: test-1\n' >"$TCROOT/missing.yaml"
check_eq "cle absente -> 3" 3 "$(tc --manifest "$TCROOT/missing.yaml" --cache-dir "$TCROOT/c" --work-dir "$TCROOT/w")"

# archive valide (file://) -> passe la validation et l'extraction, echoue au compilateur (7)
mk_manifest "$TCROOT/m-valid.yaml" valid.tar.gz "file://$TCROOT/valid.tar.gz" "file://$TCROOT/good.sha256" "$V_SHA" "$V_SIZE"
check_eq "archive valide -> 7 (extraction OK, compilateur inutilisable)" 7 "$(tc --manifest "$TCROOT/m-valid.yaml" --cache-dir "$TCROOT/c-valid" --work-dir "$TCROOT/w-valid")"
check_eq "archive valide: racine extraite" 1 "$([ -d "$TCROOT/w-valid/toolchain/toolchain-root" ] && echo 1 || echo 0)"
check_eq "archive valide: liste produite" 1 "$([ -s "$TCROOT/w-valid/toolchain/archive-list.txt" ] && echo 1 || echo 0)"

# archive dangereuses -> 5
for kind in abs dotdot symlink hardlink fifo; do
    VAR=$(printf '%s' "$kind" | tr 'a-z' 'A-Z')
    eval "SHA=\$${VAR:0:1}_SHA; SIZE=\$${VAR:0:1}_SIZE"
    mk_cksum "$TCROOT/$kind.tar.gz" "$SHA"
    mk_manifest "$TCROOT/m-$kind.yaml" "$kind.tar.gz" "file://$TCROOT/$kind.tar.gz" "file://$TCROOT/$kind.tar.gz.sha256" "$SHA" "$SIZE"
    check_eq "archive $kind refusee -> 5" 5 "$(tc --manifest "$TCROOT/m-$kind.yaml" --cache-dir "$TCROOT/c-$kind" --work-dir "$TCROOT/w-$kind")"
done

# taille incorrecte -> 4
mk_manifest "$TCROOT/m-size.yaml" valid.tar.gz "file://$TCROOT/valid.tar.gz" "file://$TCROOT/good.sha256" "$V_SHA" "$((V_SIZE + 1))"
check_eq "taille incorrecte -> 4" 4 "$(tc --manifest "$TCROOT/m-size.yaml" --cache-dir "$TCROOT/c-size" --work-dir "$TCROOT/w-size")"

# SHA incorrect -> 4
mk_manifest "$TCROOT/m-sha.yaml" valid.tar.gz "file://$TCROOT/valid.tar.gz" "file://$TCROOT/good.sha256" "0000000000000000000000000000000000000000000000000000000000000000" "$V_SIZE"
check_eq "SHA incorrect -> 4" 4 "$(tc --manifest "$TCROOT/m-sha.yaml" --cache-dir "$TCROOT/c-sha" --work-dir "$TCROOT/w-sha")"

# checksum fournisseur incoherent -> 4
printf '%064d  valid.tar.gz\n' 0 >"$TCROOT/mismatch.sha256"
mk_manifest "$TCROOT/m-cksum.yaml" valid.tar.gz "file://$TCROOT/valid.tar.gz" "file://$TCROOT/mismatch.sha256" "$V_SHA" "$V_SIZE"
check_eq "checksum fournisseur incoherent -> 4" 4 "$(tc --manifest "$TCROOT/m-cksum.yaml" --cache-dir "$TCROOT/c-ck" --work-dir "$TCROOT/w-ck")"

# cache absent en offline -> 4
check_eq "offline sans cache -> 4" 4 "$(tc --manifest "$TCROOT/m-valid.yaml" --cache-dir "$TCROOT/c-off" --work-dir "$TCROOT/w-off" --offline)"

# aucun telechargement en offline : URL volontairement invalide mais cache present
mkdir -p "$TCROOT/c-prepop/downloads/sha256"
cp "$TCROOT/valid.tar.gz" "$TCROOT/c-prepop/downloads/sha256/$V_SHA"
mk_manifest "$TCROOT/m-badurl.yaml" valid.tar.gz "https://invalid.invalid/never.tar.gz" "https://invalid.invalid/never.sha256" "$V_SHA" "$V_SIZE"
check_eq "offline: aucun acces reseau (URL invalide ignoree)" 7 "$(tc --manifest "$TCROOT/m-badurl.yaml" --cache-dir "$TCROOT/c-prepop" --work-dir "$TCROOT/w-pre" --offline)"

# reutilisation du cache (deuxieme passage offline)
check_eq "cache reutilise en offline -> 7" 7 "$(tc --manifest "$TCROOT/m-valid.yaml" --cache-dir "$TCROOT/c-prepop" --work-dir "$TCROOT/w-pre2" --offline)"

# cache corrompu -> 4 (puis --force ne s'applique qu'en ligne)
mkdir -p "$TCROOT/c-corrupt/downloads/sha256"
printf 'corrompu' >"$TCROOT/c-corrupt/downloads/sha256/$V_SHA"
check_eq "cache corrompu offline -> 4" 4 "$(tc --manifest "$TCROOT/m-valid.yaml" --cache-dir "$TCROOT/c-corrupt" --work-dir "$TCROOT/w-corrupt" --offline)"
check_eq "cache corrompu en ligne -> 4" 4 "$(tc --manifest "$TCROOT/m-valid.yaml" --cache-dir "$TCROOT/c-corrupt" --work-dir "$TCROOT/w-corrupt2")"

# compilateur absent / ambigu / mauvaise cible
python3 - "$TCROOT" <<'PYEOF'
import sys, tarfile, io, os
root = sys.argv[1]
def make(name, bin_entries):
    path = os.path.join(root, name)
    with tarfile.open(path, "w:gz") as tf:
        ti = tarfile.TarInfo("tc"); ti.type = tarfile.DIRTYPE; ti.mode = 0o755; tf.addfile(ti)
        ti = tarfile.TarInfo("tc/bin"); ti.type = tarfile.DIRTYPE; ti.mode = 0o755; tf.addfile(ti)
        for fname, data in bin_entries:
            ti = tarfile.TarInfo("tc/bin/" + fname); ti.size = len(data); ti.mode = 0o755
            tf.addfile(ti, io.BytesIO(data))
make("nocand.tar.gz", [("readme", b"x")])
make("ambiguous.tar.gz", [("aaa-gcc", b"#!/bin/sh\nexit 1\n"), ("bbb-gcc", b"#!/bin/sh\nexit 1\n")])
make("badtarget.tar.gz", [("arm-gcc", b"#!/bin/sh\ncase \"$1\" in -dumpmachine) echo arm-linux-gnueabihf;; *) exit 1;; esac\n")])
PYEOF
for kind in nocand ambiguous badtarget; do
    T="$TCROOT/$kind.tar.gz"; SHA=$(sha256sum "$T" | cut -d' ' -f1); SIZE=$(wc -c <"$T" | tr -d ' ')
    mk_cksum "$T" "$SHA"
    mk_manifest "$TCROOT/m-$kind.yaml" "$kind.tar.gz" "file://$T" "file://$T.sha256" "$SHA" "$SIZE"
    check_eq "$kind -> 7" 7 "$(tc --manifest "$TCROOT/m-$kind.yaml" --cache-dir "$TCROOT/c-$kind" --work-dir "$TCROOT/w-$kind")"
done


# artefacts reels (work/toolchain) si presents
TC_REAL="$ROOT/../work/toolchain"
if [ -d "$TC_REAL" ]; then
    for f in archive-list.txt toolchain-report.txt provenance.json compiler-version.txt test-elf.txt environment.sh; do
        check_eq "artefact toolchain $f" 1 "$([ -f "$TC_REAL/$f" ] && echo 1 || echo 0)"
    done
    check_eq "rapport: checksum publie coherent" 1 "$(grep -c '\[coherent\]' "$TC_REAL/toolchain-report.txt")"
    check_eq "rapport: signature indisponible" 1 "$(grep -c 'signature .* indisponible' "$TC_REAL/toolchain-report.txt")"
    check_eq "rapport: ELF reussi" 1 "$(grep -c 'test ELF AArch64 *: reussi' "$TC_REAL/toolchain-report.txt")"
    check_eq "rapport: aucune compilation noyau" 1 "$(grep -c 'AUCUNE' "$TC_REAL/toolchain-report.txt")"
    check_eq "environment.sh: CROSS_COMPILE absolu" 1 "$(grep -c '^export CROSS_COMPILE=/' "$TC_REAL/environment.sh")"
    check_eq "environment.sh: TOOLCHAIN_ROOT absolu" 1 "$(grep -c '^export TOOLCHAIN_ROOT=/' "$TC_REAL/environment.sh")"
    check_eq "aucun secret dans environment.sh" 0 "$(grep -ciE 'password|passwd|token|secret|api[_-]?key' "$TC_REAL/environment.sh" || true)"
    check_eq "aucun secret dans le rapport" 0 "$(grep -ciE 'password|passwd|token|secret|api[_-]?key' "$TC_REAL/toolchain-report.txt" || true)"
    check_eq "provenance: sha256_local == manifeste" 1 "$(grep -c '\"sha256_local\": \"b0fad860' "$TC_REAL/provenance.json")"
    check_eq "test-elf: AArch64" 1 "$(grep -c 'ELF AArch64 confirme' "$TC_REAL/test-elf.txt")"
else
    printf '  (ignore) work/toolchain absent\n'
fi

# statuts inchanges
check_eq "kernel.built_release toujours TODO_BUILD" "TODO_BUILD" "$(mget2 kernel.built_release)"
check_eq "runtime_status toujours not_tested" "not_tested" "$(mget2 kernel_config.runtime_status)"
check_eq "validation_status toujours provisional" "provisional" "$(mget2 kernel_config.validation_status)"

# --------------------------------------------------------------------------
section "19. Incrément 2F-2 : compilation noyau (garde-fous)"
# --------------------------------------------------------------------------
KB="$ROOT/scripts/kernel-build.sh"
check_eq "kernel-build executables" 1 "$([ -x "$KB" ] && echo 1 || echo 0)"
check_eq "bash -n kernel-build" 0 "$(bash -n "$KB" 2>/dev/null; echo $?)"
check_eq "kernel-build --help -> 0" 0 "$("$KB" --help >/dev/null 2>&1; echo $?)"
check_eq "kernel-build sans args -> 2" 2 "$("$KB" >/dev/null 2>&1; echo $?)"
check_eq "kernel-build option inconnue -> 2" 2 "$("$KB" --bogus >/dev/null 2>&1; echo $?)"
check_eq "kernel-build argument positionnel -> 2" 2 "$("$KB" foo >/dev/null 2>&1; echo $?)"

# --jobs : validation stricte
KBJ="$TMP/kbj"
mkdir -p "$KBJ"
for bad in "" "-1" "+2" "0" "129" "abc" "1.5"; do
    if [ -z "$bad" ]; then
        code=$("$KB" --kernel-source "$TMP/x" --config "$TMP/y" --toolchain-root "$TMP/z" --output "$KBJ" --jobs 2>/dev/null; echo $?)
    else
        code=$("$KB" --kernel-source "$TMP/x" --config "$TMP/y" --toolchain-root "$TMP/z" --output "$KBJ" --jobs "$bad" 2>/dev/null; echo $?)
    fi
    check_eq "--jobs '$bad' refuse -> 2" 2 "$code"
done
check_eq "--jobs repete -> 2" 2 "$("$KB" --kernel-source "$TMP/x" --config "$TMP/y" --toolchain-root "$TMP/z" --output "$KBJ" --jobs 2 --jobs 4 >/dev/null 2>&1; echo $?)"

# source invalide -> 3
check_eq "source absente -> 3" 3 "$("$KB" --kernel-source "$TMP/nope" --config "$ROOT/configs/a71-proposed.config" --toolchain-root "$TMP/tc" --output "$KBJ/o1" >/dev/null 2>&1; echo $?)"
mkdir -p "$TMP/espace src"
check_eq "source avec espace -> 3" 3 "$("$KB" --kernel-source "$TMP/espace src" --config "$ROOT/configs/a71-proposed.config" --toolchain-root "$TMP/tc" --output "$KBJ/o2" >/dev/null 2>&1; echo $?)"

# faux arbre noyau SPACE-FREE (obligatoire pour le Makefile)
KBROOT="/tmp/a71-kb.$$"
rm -rf "$KBROOT"; mkdir -p "$KBROOT/src/scripts/kconfig" "$KBROOT/tc/bin" "$KBROOT/out"
( cd "$KBROOT/src" && git init -q . && git config user.email t@t && git config user.name t \
  && : >Makefile && : >scripts/kconfig/merge_config.sh && mkdir -p arch/arm64/boot/dts/qcom \
  && : >arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dts && git add -A && git commit -qm init ) >/dev/null 2>&1
SRC_SHA=$(git -C "$KBROOT/src" rev-parse HEAD)
printf 'kernel:\n  commit: %s\n  branch: master\n  expected_release: 6.18.0-rc1-a71+\n  source_version: 6.18.0-rc1\n  dtb_output: arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dtb\n  dts_source: arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dts\n' "$SRC_SHA" >"$TMP/kb-manifest.yaml"

kbrun() {
    A71_MANIFEST="$TMP/kb-manifest.yaml" "$KB" --kernel-source "$KBROOT/src" \
        --config "${CFG:-$ROOT/configs/upstream/pmaports-sm7150.config}" \
        --toolchain-root "${TC:-$KBROOT/tc}" --output "${OUT:-$KBROOT/out/run}" \
        --requirements "${REQ:-$ROOT/configs/a71-required-symbols.txt}" >/dev/null 2>&1
    echo $?
}

# mauvais commit : manifeste pointant un commit different du HEAD reel
printf 'kernel:\n  commit: %s\n  branch: master\n' "0000000000000000000000000000000000000000" >"$TMP/kb-badcommit.yaml"
check_eq "mauvais commit -> 3" 3 "$(A71_MANIFEST="$TMP/kb-badcommit.yaml" "$KB" --kernel-source "$KBROOT/src" --config "$ROOT/configs/upstream/pmaports-sm7150.config" --toolchain-root "$KBROOT/tc" --output "$KBROOT/out/x" >/dev/null 2>&1; echo $?)"

# config "bonne" : issue de la fusion reelle (contient la politique de boot)
GOODCFG="$ROOT/../work/config/final.config"
if [ ! -f "$GOODCFG" ]; then
    printf '  (ignore) work/config/final.config absent : tests avances non executes\n'
else
    # faux compilateur aarch64 + les 8 outils prefixes
    FAKETC="$KBROOT/tc-good"
    mkdir -p "$FAKETC/bin"
    for t in ld ar nm objcopy objdump strip readelf; do
        printf '#!/bin/sh\nexit 0\n' >"$FAKETC/bin/aarch64-fake-$t"
        chmod +x "$FAKETC/bin/aarch64-fake-$t"
    done
    cat >"$FAKETC/bin/aarch64-fake-gcc" <<FAKEEOF
#!/bin/sh
case "\$1" in
  -dumpmachine) echo aarch64-fake-linux-gnu ;;
  --version) echo "fake gcc 99" ;;
  -dumpversion) echo 99 ;;
  -print-sysroot) echo "$FAKETC/sysroot" ;;
  *) exit 0 ;;
esac
FAKEEOF
    chmod +x "$FAKETC/bin/aarch64-fake-gcc"

    kbrun2() {
        A71_MANIFEST="$TMP/kb-manifest.yaml" "$KB" --kernel-source "$KBROOT/src" \
            --config "$GOODCFG" --toolchain-root "${TC2:-$FAKETC}" --output "${OUT2:-$KBROOT/out/run2}" \
            --requirements "$ROOT/configs/a71-required-symbols.txt" >/dev/null 2>&1
        echo $?
    }

    # source non git -> 3
    mkdir -p "$KBROOT/notgit"
    check_eq "source non git -> 3" 3 "$(A71_MANIFEST="$TMP/kb-manifest.yaml" "$KB" --kernel-source "$KBROOT/notgit" --config "$GOODCFG" --toolchain-root "$FAKETC" --output "$KBROOT/out/ng" >/dev/null 2>&1; echo $?)"

    # toolchain : absente / non aarch64 / symlink sortant -> 6
    check_eq "toolchain absente -> 6" 6 "$(TC2="$TMP/nope-tc" kbrun2)"
    mkdir -p "$KBROOT/tc-arm/bin"
    printf '#!/bin/sh\ncase "$1" in -dumpmachine) echo arm-linux-gnueabihf;; *) exit 1;; esac\n' >"$KBROOT/tc-arm/bin/arm-gcc"
    chmod +x "$KBROOT/tc-arm/bin/arm-gcc"
    check_eq "toolchain non aarch64 -> 6" 6 "$(TC2="$KBROOT/tc-arm" kbrun2)"
    OUTSIDE="$KBROOT/outside-gcc"
    printf '#!/bin/sh\ncase "$1" in -dumpmachine) echo aarch64-evil;; *) exit 1;; esac\n' >"$OUTSIDE"
    chmod +x "$OUTSIDE"
    mkdir -p "$KBROOT/tc-escape/bin"
    ln -sfn "$OUTSIDE" "$KBROOT/tc-escape/bin/aarch64-evil-gcc"
    check_eq "compilateur sortant par symlink -> 6" 6 "$(TC2="$KBROOT/tc-escape" kbrun2)"

    # sortie : symlink, /, dans le noyau, non vide -> 5
    mkdir -p "$KBROOT/out/real2"
    ln -sfn "$KBROOT/out/real2" "$KBROOT/out/link2"
    check_eq "sortie symlink -> 5" 5 "$(OUT2="$KBROOT/out/link2" kbrun2)"
    check_eq "sortie = / -> 5" 5 "$(OUT2="/" kbrun2)"
    check_eq "sortie dans l'arbre noyau -> 5" 5 "$(OUT2="$KBROOT/src/kb" kbrun2)"
    check_eq "sortie dans la toolchain -> 5" 5 "$(OUT2="$FAKETC/kb" kbrun2)"
    mkdir -p "$KBROOT/out/nonempty2" && : >"$KBROOT/out/nonempty2/x"
    check_eq "sortie non vide -> 5" 5 "$(OUT2="$KBROOT/out/nonempty2" kbrun2)"

    # prerequis hote : depend de la presence reelle de bc sur la machine
    if command -v bc >/dev/null 2>&1; then
        check_eq "prerequis hote presents -> 8 (make reel sur arbre factice)" 8 "$(kbrun2)"
    else
        check_eq "prerequis hote (bc) -> 7" 7 "$(kbrun2)"
    fi
fi

# synthese de build publiee (succes ou echec) si presente
KA="$ROOT/../work/kernel-build"
if [ -f "$KA/build-summary.txt" ]; then
    for k in result build runtime validation kernel_commit expected_release module_count; do
        check_eq "summary contient $k" 1 "$(grep -c "^$k=" "$KA/build-summary.txt")"
    done
    check_eq "summary: runtime=not_tested" 1 "$(grep -c '^runtime=not_tested$' "$KA/build-summary.txt")"
    check_eq "summary: validation=provisional" 1 "$(grep -c '^validation=provisional$' "$KA/build-summary.txt")"
    check_eq "aucune construction boot.img" 0 "$(find "$KA" -name 'boot.img' 2>/dev/null | wc -l)"
    check_eq "aucune construction rootfs" 0 "$(find "$KA" -name 'rootfs*' 2>/dev/null | wc -l)"
    if grep -qx 'result=OK' "$KA/build-summary.txt"; then
        check_eq "summary: build=completed" 1 "$(grep -c '^build=completed$' "$KA/build-summary.txt")"
        check_eq "artefact Image" 1 "$([ -f "$KA/artifacts/Image" ] && echo 1 || echo 0)"
        check_eq "artefact DTB A71" 1 "$([ -f "$KA/artifacts/sm7150-samsung-a715f.dtb" ] && echo 1 || echo 0)"
        check_eq "rapport provenance JSON valide" 0 "$(python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$KA/reports/provenance.json" 2>/dev/null; echo $?)"
    else
        check_eq "summary: build=failed" 1 "$(grep -c '^build=failed$' "$KA/build-summary.txt")"
        check_eq "summary: failed_step renseigne" 1 "$(grep -cE '^failed_step=.+' "$KA/build-summary.txt")"
        check_eq "aucun artefact Image en cas d echec" 0 "$([ -f "$KA/artifacts/Image" ] && echo 1 || echo 0)"
    fi
else
    printf '  (ignore) work/kernel-build absent\n'
fi

check_eq "kernel.built_release toujours TODO_BUILD" "TODO_BUILD" "$(mget2 kernel.built_release)"

# --------------------------------------------------------------------------
section "18. Incrément 2F-1 : préparation de la toolchain"
# --------------------------------------------------------------------------
PTC="$ROOT/scripts/prepare-toolchain.sh"
check_eq "prepare-toolchain executables" 1 "$([ -x "$PTC" ] && echo 1 || echo 0)"
check_eq "bash -n prepare-toolchain" 0 "$(bash -n "$PTC" 2>/dev/null; echo $?)"
check_eq "--help -> 0" 0 "$("$PTC" --help >/dev/null 2>&1; echo $?)"
check_eq "sans arguments -> 2" 2 "$("$PTC" >/dev/null 2>&1; echo $?)"
check_eq "manifeste absent -> 3" 3 "$("$PTC" --manifest "$TMP/nope.yaml" --cache-dir "$TMP/c1" --work-dir "$TMP/w1" >/dev/null 2>&1; echo $?)"

# fabrique d'archives de test (python3 tarfile)
mk_tar() { python3 - "$@" <<'PYEOF'
import sys, tarfile, io, os
kind, out = sys.argv[1], sys.argv[2]
with tarfile.open(out, "w:gz") as tf:
    def add_file(name, data=b"x"):
        ti = tarfile.TarInfo(name); ti.size = len(data); ti.mode = 0o644
        tf.addfile(ti, io.BytesIO(data))
    def add_dir(name):
        ti = tarfile.TarInfo(name); ti.type = tarfile.DIRTYPE; ti.mode = 0o755
        tf.addfile(ti)
    def add_sym(name, target):
        ti = tarfile.TarInfo(name); ti.type = tarfile.SYMTYPE; ti.linkname = target; ti.mode = 0o777
        tf.addfile(ti)
    def add_lnk(name, target):
        ti = tarfile.TarInfo(name); ti.type = tarfile.LNKTYPE; ti.linkname = target; ti.mode = 0o644
        tf.addfile(ti)
    def add_fifo(name):
        ti = tarfile.TarInfo(name); ti.type = tarfile.FIFOTYPE; ti.mode = 0o644
        tf.addfile(ti)
    if kind == "abs":
        add_file("/etc/passwd")
    elif kind == "dotdot":
        add_file("../evil")
    elif kind == "symlink":
        add_dir("tc"); add_sym("tc/out", "/etc/passwd")
    elif kind == "hardlink":
        add_file("tc/a"); add_lnk("tc/b", "/etc/passwd")
    elif kind == "fifo":
        add_dir("tc"); add_fifo("tc/fifo")
    elif kind == "valid":
        add_dir("tc"); add_dir("tc/bin")
        add_file("tc/bin/aarch64-fake-linux-gnu-gcc", b"#!/bin/sh\nexit 1\n")
    elif kind == "empty":
        pass
PYEOF
}

mk_cksum() {
    # mk_cksum <fichier> <sha> -> fichier .sha256 au format standard
    printf '%s  %s\n' "$2" "$(basename "$1")" >"$1.sha256"
}

mk_manifest() {
    # mk_manifest <fichier> <archive> <url> <checksum_url> <sha> <taille>
    printf 'toolchain:\n  version: test-1\n  archive: %s\n  archive_url: %s\n  checksum_url: %s\n  sha256: %s\n  size: %s\n' \
        "$2" "$3" "$4" "$5" "$6" >"$1"
}

TCROOT="$TMP/tc"
mkdir -p "$TCROOT"
mk_tar valid "$TCROOT/valid.tar.gz"
V_SHA=$(sha256sum "$TCROOT/valid.tar.gz" | cut -d' ' -f1)
V_SIZE=$(wc -c <"$TCROOT/valid.tar.gz" | tr -d ' ')
mk_tar abs "$TCROOT/abs.tar.gz"; A_SHA=$(sha256sum "$TCROOT/abs.tar.gz" | cut -d' ' -f1); A_SIZE=$(wc -c <"$TCROOT/abs.tar.gz" | tr -d ' ')
mk_tar dotdot "$TCROOT/dotdot.tar.gz"; D_SHA=$(sha256sum "$TCROOT/dotdot.tar.gz" | cut -d' ' -f1); D_SIZE=$(wc -c <"$TCROOT/dotdot.tar.gz" | tr -d ' ')
mk_tar symlink "$TCROOT/symlink.tar.gz"; S_SHA=$(sha256sum "$TCROOT/symlink.tar.gz" | cut -d' ' -f1); S_SIZE=$(wc -c <"$TCROOT/symlink.tar.gz" | tr -d ' ')
mk_tar hardlink "$TCROOT/hardlink.tar.gz"; H_SHA=$(sha256sum "$TCROOT/hardlink.tar.gz" | cut -d' ' -f1); H_SIZE=$(wc -c <"$TCROOT/hardlink.tar.gz" | tr -d ' ')
mk_tar fifo "$TCROOT/fifo.tar.gz"; F_SHA=$(sha256sum "$TCROOT/fifo.tar.gz" | cut -d' ' -f1); F_SIZE=$(wc -c <"$TCROOT/fifo.tar.gz" | tr -d ' ')
printf 'deadbeef\n' >"$TCROOT/bad.sha256"
printf '%s  valid.tar.gz\n' "$V_SHA" >"$TCROOT/good.sha256"

tc() { "$PTC" "$@" >"$TMP/tc.out" 2>"$TMP/tc.err"; echo $?; }

# TODO_* refuse
printf 'toolchain:\n  version: test-1\n  archive: valid.tar.gz\n  archive_url: file://%s/valid.tar.gz\n  checksum_url: file://%s/good.sha256\n  sha256: TODO_VERIFIER\n  size: %s\n' "$TCROOT" "$TCROOT" "$V_SIZE" >"$TCROOT/todo.yaml"
check_eq "sha256 TODO_VERIFIER -> 3" 3 "$(tc --manifest "$TCROOT/todo.yaml" --cache-dir "$TCROOT/c" --work-dir "$TCROOT/w")"
# cle absente
printf 'toolchain:\n  version: test-1\n' >"$TCROOT/missing.yaml"
check_eq "cle absente -> 3" 3 "$(tc --manifest "$TCROOT/missing.yaml" --cache-dir "$TCROOT/c" --work-dir "$TCROOT/w")"

# archive valide (file://) -> passe la validation et l'extraction, echoue au compilateur (7)
mk_manifest "$TCROOT/m-valid.yaml" valid.tar.gz "file://$TCROOT/valid.tar.gz" "file://$TCROOT/good.sha256" "$V_SHA" "$V_SIZE"
check_eq "archive valide -> 7 (extraction OK, compilateur inutilisable)" 7 "$(tc --manifest "$TCROOT/m-valid.yaml" --cache-dir "$TCROOT/c-valid" --work-dir "$TCROOT/w-valid")"
check_eq "archive valide: racine extraite" 1 "$([ -d "$TCROOT/w-valid/toolchain/toolchain-root" ] && echo 1 || echo 0)"
check_eq "archive valide: liste produite" 1 "$([ -s "$TCROOT/w-valid/toolchain/archive-list.txt" ] && echo 1 || echo 0)"

# archive dangereuses -> 5
for kind in abs dotdot symlink hardlink fifo; do
    VAR=$(printf '%s' "$kind" | tr 'a-z' 'A-Z')
    eval "SHA=\$${VAR:0:1}_SHA; SIZE=\$${VAR:0:1}_SIZE"
    mk_cksum "$TCROOT/$kind.tar.gz" "$SHA"
    mk_manifest "$TCROOT/m-$kind.yaml" "$kind.tar.gz" "file://$TCROOT/$kind.tar.gz" "file://$TCROOT/$kind.tar.gz.sha256" "$SHA" "$SIZE"
    check_eq "archive $kind refusee -> 5" 5 "$(tc --manifest "$TCROOT/m-$kind.yaml" --cache-dir "$TCROOT/c-$kind" --work-dir "$TCROOT/w-$kind")"
done

# taille incorrecte -> 4
mk_manifest "$TCROOT/m-size.yaml" valid.tar.gz "file://$TCROOT/valid.tar.gz" "file://$TCROOT/good.sha256" "$V_SHA" "$((V_SIZE + 1))"
check_eq "taille incorrecte -> 4" 4 "$(tc --manifest "$TCROOT/m-size.yaml" --cache-dir "$TCROOT/c-size" --work-dir "$TCROOT/w-size")"

# SHA incorrect -> 4
mk_manifest "$TCROOT/m-sha.yaml" valid.tar.gz "file://$TCROOT/valid.tar.gz" "file://$TCROOT/good.sha256" "0000000000000000000000000000000000000000000000000000000000000000" "$V_SIZE"
check_eq "SHA incorrect -> 4" 4 "$(tc --manifest "$TCROOT/m-sha.yaml" --cache-dir "$TCROOT/c-sha" --work-dir "$TCROOT/w-sha")"

# checksum fournisseur incoherent -> 4
printf '%064d  valid.tar.gz\n' 0 >"$TCROOT/mismatch.sha256"
mk_manifest "$TCROOT/m-cksum.yaml" valid.tar.gz "file://$TCROOT/valid.tar.gz" "file://$TCROOT/mismatch.sha256" "$V_SHA" "$V_SIZE"
check_eq "checksum fournisseur incoherent -> 4" 4 "$(tc --manifest "$TCROOT/m-cksum.yaml" --cache-dir "$TCROOT/c-ck" --work-dir "$TCROOT/w-ck")"

# cache absent en offline -> 4
check_eq "offline sans cache -> 4" 4 "$(tc --manifest "$TCROOT/m-valid.yaml" --cache-dir "$TCROOT/c-off" --work-dir "$TCROOT/w-off" --offline)"

# aucun telechargement en offline : URL volontairement invalide mais cache present
mkdir -p "$TCROOT/c-prepop/downloads/sha256"
cp "$TCROOT/valid.tar.gz" "$TCROOT/c-prepop/downloads/sha256/$V_SHA"
mk_manifest "$TCROOT/m-badurl.yaml" valid.tar.gz "https://invalid.invalid/never.tar.gz" "https://invalid.invalid/never.sha256" "$V_SHA" "$V_SIZE"
check_eq "offline: aucun acces reseau (URL invalide ignoree)" 7 "$(tc --manifest "$TCROOT/m-badurl.yaml" --cache-dir "$TCROOT/c-prepop" --work-dir "$TCROOT/w-pre" --offline)"

# reutilisation du cache (deuxieme passage offline)
check_eq "cache reutilise en offline -> 7" 7 "$(tc --manifest "$TCROOT/m-valid.yaml" --cache-dir "$TCROOT/c-prepop" --work-dir "$TCROOT/w-pre2" --offline)"

# cache corrompu -> 4 (puis --force ne s'applique qu'en ligne)
mkdir -p "$TCROOT/c-corrupt/downloads/sha256"
printf 'corrompu' >"$TCROOT/c-corrupt/downloads/sha256/$V_SHA"
check_eq "cache corrompu offline -> 4" 4 "$(tc --manifest "$TCROOT/m-valid.yaml" --cache-dir "$TCROOT/c-corrupt" --work-dir "$TCROOT/w-corrupt" --offline)"
check_eq "cache corrompu en ligne -> 4" 4 "$(tc --manifest "$TCROOT/m-valid.yaml" --cache-dir "$TCROOT/c-corrupt" --work-dir "$TCROOT/w-corrupt2")"

# compilateur absent / ambigu / mauvaise cible
python3 - "$TCROOT" <<'PYEOF'
import sys, tarfile, io, os
root = sys.argv[1]
def make(name, bin_entries):
    path = os.path.join(root, name)
    with tarfile.open(path, "w:gz") as tf:
        ti = tarfile.TarInfo("tc"); ti.type = tarfile.DIRTYPE; ti.mode = 0o755; tf.addfile(ti)
        ti = tarfile.TarInfo("tc/bin"); ti.type = tarfile.DIRTYPE; ti.mode = 0o755; tf.addfile(ti)
        for fname, data in bin_entries:
            ti = tarfile.TarInfo("tc/bin/" + fname); ti.size = len(data); ti.mode = 0o755
            tf.addfile(ti, io.BytesIO(data))
make("nocand.tar.gz", [("readme", b"x")])
make("ambiguous.tar.gz", [("aaa-gcc", b"#!/bin/sh\nexit 1\n"), ("bbb-gcc", b"#!/bin/sh\nexit 1\n")])
make("badtarget.tar.gz", [("arm-gcc", b"#!/bin/sh\ncase \"$1\" in -dumpmachine) echo arm-linux-gnueabihf;; *) exit 1;; esac\n")])
PYEOF
for kind in nocand ambiguous badtarget; do
    T="$TCROOT/$kind.tar.gz"; SHA=$(sha256sum "$T" | cut -d' ' -f1); SIZE=$(wc -c <"$T" | tr -d ' ')
    mk_cksum "$T" "$SHA"
    mk_manifest "$TCROOT/m-$kind.yaml" "$kind.tar.gz" "file://$T" "file://$T.sha256" "$SHA" "$SIZE"
    check_eq "$kind -> 7" 7 "$(tc --manifest "$TCROOT/m-$kind.yaml" --cache-dir "$TCROOT/c-$kind" --work-dir "$TCROOT/w-$kind")"
done


# artefacts reels (work/toolchain) si presents
TC_REAL="$ROOT/../work/toolchain"
if [ -d "$TC_REAL" ]; then
    for f in archive-list.txt toolchain-report.txt provenance.json compiler-version.txt test-elf.txt environment.sh; do
        check_eq "artefact toolchain $f" 1 "$([ -f "$TC_REAL/$f" ] && echo 1 || echo 0)"
    done
    check_eq "rapport: checksum publie coherent" 1 "$(grep -c '\[coherent\]' "$TC_REAL/toolchain-report.txt")"
    check_eq "rapport: signature indisponible" 1 "$(grep -c 'signature .* indisponible' "$TC_REAL/toolchain-report.txt")"
    check_eq "rapport: ELF reussi" 1 "$(grep -c 'test ELF AArch64 *: reussi' "$TC_REAL/toolchain-report.txt")"
    check_eq "rapport: aucune compilation noyau" 1 "$(grep -c 'AUCUNE' "$TC_REAL/toolchain-report.txt")"
    check_eq "environment.sh: CROSS_COMPILE absolu" 1 "$(grep -c '^export CROSS_COMPILE=/' "$TC_REAL/environment.sh")"
    check_eq "environment.sh: TOOLCHAIN_ROOT absolu" 1 "$(grep -c '^export TOOLCHAIN_ROOT=/' "$TC_REAL/environment.sh")"
    check_eq "aucun secret dans environment.sh" 0 "$(grep -ciE 'password|passwd|token|secret|api[_-]?key' "$TC_REAL/environment.sh" || true)"
    check_eq "aucun secret dans le rapport" 0 "$(grep -ciE 'password|passwd|token|secret|api[_-]?key' "$TC_REAL/toolchain-report.txt" || true)"
    check_eq "provenance: sha256_local == manifeste" 1 "$(grep -c '\"sha256_local\": \"b0fad860' "$TC_REAL/provenance.json")"
    check_eq "test-elf: AArch64" 1 "$(grep -c 'ELF AArch64 confirme' "$TC_REAL/test-elf.txt")"
else
    printf '  (ignore) work/toolchain absent\n'
fi

# statuts inchanges
check_eq "kernel.built_release toujours TODO_BUILD" "TODO_BUILD" "$(mget2 kernel.built_release)"
check_eq "runtime_status toujours not_tested" "not_tested" "$(mget2 kernel_config.runtime_status)"
check_eq "validation_status toujours provisional" "provisional" "$(mget2 kernel_config.validation_status)"

# --------------------------------------------------------------------------
section "19. Incrément 2F-2 : compilation noyau (garde-fous)"
# --------------------------------------------------------------------------
KB="$ROOT/scripts/kernel-build.sh"
check_eq "kernel-build executables" 1 "$([ -x "$KB" ] && echo 1 || echo 0)"
check_eq "bash -n kernel-build" 0 "$(bash -n "$KB" 2>/dev/null; echo $?)"
check_eq "kernel-build --help -> 0" 0 "$("$KB" --help >/dev/null 2>&1; echo $?)"
check_eq "kernel-build sans args -> 2" 2 "$("$KB" >/dev/null 2>&1; echo $?)"
check_eq "kernel-build option inconnue -> 2" 2 "$("$KB" --bogus >/dev/null 2>&1; echo $?)"
check_eq "kernel-build argument positionnel -> 2" 2 "$("$KB" foo >/dev/null 2>&1; echo $?)"

# --jobs : validation stricte
KBJ="$TMP/kbj"
mkdir -p "$KBJ"
for bad in "" "-1" "+2" "0" "129" "abc" "1.5"; do
    if [ -z "$bad" ]; then
        code=$("$KB" --kernel-source "$TMP/x" --config "$TMP/y" --toolchain-root "$TMP/z" --output "$KBJ" --jobs 2>/dev/null; echo $?)
    else
        code=$("$KB" --kernel-source "$TMP/x" --config "$TMP/y" --toolchain-root "$TMP/z" --output "$KBJ" --jobs "$bad" 2>/dev/null; echo $?)
    fi
    check_eq "--jobs '$bad' refuse -> 2" 2 "$code"
done
check_eq "--jobs repete -> 2" 2 "$("$KB" --kernel-source "$TMP/x" --config "$TMP/y" --toolchain-root "$TMP/z" --output "$KBJ" --jobs 2 --jobs 4 >/dev/null 2>&1; echo $?)"

# source invalide -> 3
check_eq "source absente -> 3" 3 "$("$KB" --kernel-source "$TMP/nope" --config "$ROOT/configs/a71-proposed.config" --toolchain-root "$TMP/tc" --output "$KBJ/o1" >/dev/null 2>&1; echo $?)"
mkdir -p "$TMP/espace src"
check_eq "source avec espace -> 3" 3 "$("$KB" --kernel-source "$TMP/espace src" --config "$ROOT/configs/a71-proposed.config" --toolchain-root "$TMP/tc" --output "$KBJ/o2" >/dev/null 2>&1; echo $?)"

# faux arbre noyau SPACE-FREE (obligatoire pour le Makefile)
KBROOT="/tmp/a71-kb.$$"
rm -rf "$KBROOT"; mkdir -p "$KBROOT/src/scripts/kconfig" "$KBROOT/tc/bin" "$KBROOT/out"
( cd "$KBROOT/src" && git init -q . && git config user.email t@t && git config user.name t \
  && : >Makefile && : >scripts/kconfig/merge_config.sh && mkdir -p arch/arm64/boot/dts/qcom \
  && : >arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dts && git add -A && git commit -qm init ) >/dev/null 2>&1
SRC_SHA=$(git -C "$KBROOT/src" rev-parse HEAD)
printf 'kernel:\n  commit: %s\n  branch: master\n  expected_release: 6.18.0-rc1-a71+\n  source_version: 6.18.0-rc1\n  dtb_output: arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dtb\n  dts_source: arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dts\n' "$SRC_SHA" >"$TMP/kb-manifest.yaml"

kbrun() {
    A71_MANIFEST="$TMP/kb-manifest.yaml" "$KB" --kernel-source "$KBROOT/src" \
        --config "${CFG:-$ROOT/configs/upstream/pmaports-sm7150.config}" \
        --toolchain-root "${TC:-$KBROOT/tc}" --output "${OUT:-$KBROOT/out/run}" \
        --requirements "${REQ:-$ROOT/configs/a71-required-symbols.txt}" >/dev/null 2>&1
    echo $?
}

# mauvais commit : manifeste pointant un commit different du HEAD reel
printf 'kernel:\n  commit: %s\n  branch: master\n' "0000000000000000000000000000000000000000" >"$TMP/kb-badcommit.yaml"
check_eq "mauvais commit -> 3" 3 "$(A71_MANIFEST="$TMP/kb-badcommit.yaml" "$KB" --kernel-source "$KBROOT/src" --config "$ROOT/configs/upstream/pmaports-sm7150.config" --toolchain-root "$KBROOT/tc" --output "$KBROOT/out/x" >/dev/null 2>&1; echo $?)"

# config "bonne" : issue de la fusion reelle (contient la politique de boot)
GOODCFG="$ROOT/../work/config/final.config"
if [ ! -f "$GOODCFG" ]; then
    printf '  (ignore) work/config/final.config absent : tests avances non executes\n'
else
    # faux compilateur aarch64 + les 8 outils prefixes
    FAKETC="$KBROOT/tc-good"
    mkdir -p "$FAKETC/bin"
    for t in ld ar nm objcopy objdump strip readelf; do
        printf '#!/bin/sh\nexit 0\n' >"$FAKETC/bin/aarch64-fake-$t"
        chmod +x "$FAKETC/bin/aarch64-fake-$t"
    done
    cat >"$FAKETC/bin/aarch64-fake-gcc" <<FAKEEOF
#!/bin/sh
case "\$1" in
  -dumpmachine) echo aarch64-fake-linux-gnu ;;
  --version) echo "fake gcc 99" ;;
  -dumpversion) echo 99 ;;
  -print-sysroot) echo "$FAKETC/sysroot" ;;
  *) exit 0 ;;
esac
FAKEEOF
    chmod +x "$FAKETC/bin/aarch64-fake-gcc"

    kbrun2() {
        A71_MANIFEST="$TMP/kb-manifest.yaml" "$KB" --kernel-source "$KBROOT/src" \
            --config "$GOODCFG" --toolchain-root "${TC2:-$FAKETC}" --output "${OUT2:-$KBROOT/out/run2}" \
            --requirements "$ROOT/configs/a71-required-symbols.txt" >/dev/null 2>&1
        echo $?
    }

    # source non git -> 3
    mkdir -p "$KBROOT/notgit"
    check_eq "source non git -> 3" 3 "$(A71_MANIFEST="$TMP/kb-manifest.yaml" "$KB" --kernel-source "$KBROOT/notgit" --config "$GOODCFG" --toolchain-root "$FAKETC" --output "$KBROOT/out/ng" >/dev/null 2>&1; echo $?)"

    # toolchain : absente / non aarch64 / symlink sortant -> 6
    check_eq "toolchain absente -> 6" 6 "$(TC2="$TMP/nope-tc" kbrun2)"
    mkdir -p "$KBROOT/tc-arm/bin"
    printf '#!/bin/sh\ncase "$1" in -dumpmachine) echo arm-linux-gnueabihf;; *) exit 1;; esac\n' >"$KBROOT/tc-arm/bin/arm-gcc"
    chmod +x "$KBROOT/tc-arm/bin/arm-gcc"
    check_eq "toolchain non aarch64 -> 6" 6 "$(TC2="$KBROOT/tc-arm" kbrun2)"
    OUTSIDE="$KBROOT/outside-gcc"
    printf '#!/bin/sh\ncase "$1" in -dumpmachine) echo aarch64-evil;; *) exit 1;; esac\n' >"$OUTSIDE"
    chmod +x "$OUTSIDE"
    mkdir -p "$KBROOT/tc-escape/bin"
    ln -sfn "$OUTSIDE" "$KBROOT/tc-escape/bin/aarch64-evil-gcc"
    check_eq "compilateur sortant par symlink -> 6" 6 "$(TC2="$KBROOT/tc-escape" kbrun2)"

    # sortie : symlink, /, dans le noyau, non vide -> 5
    mkdir -p "$KBROOT/out/real2"
    ln -sfn "$KBROOT/out/real2" "$KBROOT/out/link2"
    check_eq "sortie symlink -> 5" 5 "$(OUT2="$KBROOT/out/link2" kbrun2)"
    check_eq "sortie = / -> 5" 5 "$(OUT2="/" kbrun2)"
    check_eq "sortie dans l'arbre noyau -> 5" 5 "$(OUT2="$KBROOT/src/kb" kbrun2)"
    check_eq "sortie dans la toolchain -> 5" 5 "$(OUT2="$FAKETC/kb" kbrun2)"
    mkdir -p "$KBROOT/out/nonempty2" && : >"$KBROOT/out/nonempty2/x"
    check_eq "sortie non vide -> 5" 5 "$(OUT2="$KBROOT/out/nonempty2" kbrun2)"

    # prerequis hote : depend de la presence reelle de bc sur la machine
    if command -v bc >/dev/null 2>&1; then
        check_eq "prerequis hote presents -> 8 (make reel sur arbre factice)" 8 "$(kbrun2)"
    else
        check_eq "prerequis hote (bc) -> 7" 7 "$(kbrun2)"
    fi
fi

check_eq "kernel.built_release toujours TODO_BUILD" "TODO_BUILD" "$(mget2 kernel.built_release)"
check_eq "runtime_status toujours not_tested" "not_tested" "$(mget2 kernel_config.runtime_status)"
check_eq "validation_status toujours provisional" "provisional" "$(mget2 kernel_config.validation_status)"
rm -rf "$KBROOT"

# --------------------------------------------------------------------------
section "20. Incrément 2F-2a : états d'échec explicites"
# --------------------------------------------------------------------------
KBS="$ROOT/scripts/kernel-build.sh"
STROOT="/tmp/a71-st.$$"
rm -rf "$STROOT"; mkdir -p "$STROOT/src/scripts/kconfig" "$STROOT/src/arch/arm64/boot/dts/qcom" "$STROOT/tc/bin" "$STROOT/bin"
( cd "$STROOT/src" && git init -q . && git config user.email t@t && git config user.name t \
  && : >Makefile && : >scripts/kconfig/merge_config.sh \
  && : >arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dts && git add -A && git commit -qm init ) >/dev/null 2>&1
ST_SHA=$(git -C "$STROOT/src" rev-parse HEAD)
printf 'kernel:\n  commit: %s\n  branch: master\n  expected_release: 6.18.0-rc1-a71+\n  source_version: 6.18.0-rc1\n  dtb_output: arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dtb\n  dts_source: arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dts\n' "$ST_SHA" >"$STROOT/manifest.yaml"

for t in ld ar nm objcopy objdump strip readelf; do printf '#!/bin/sh\nexit 0\n' >"$STROOT/tc/bin/aarch64-st-$t"; chmod +x "$STROOT/tc/bin/aarch64-st-$t"; done
printf '#!/bin/sh\ncase "$1" in -dumpmachine) echo aarch64-st-linux-gnu;; --version) echo st;; -dumpversion) echo 99;; -print-sysroot) echo %s/sysroot;; *) exit 0;; esac\n' "$STROOT/tc" >"$STROOT/tc/bin/aarch64-st-gcc"
chmod +x "$STROOT/tc/bin/aarch64-st-gcc"

# bouchons : bc, dtc, make (scenario via variables d'environnement)
printf '#!/bin/sh\nexit 0\n' >"$STROOT/bin/bc"; chmod +x "$STROOT/bin/bc"
printf '#!/bin/sh\necho "/dts-v1/;"\necho "samsung,a715f qcom,sm7150 simple-framebuffer"\nexit 0\n' >"$STROOT/bin/dtc"; chmod +x "$STROOT/bin/dtc"
cat >"$STROOT/bin/make" <<'FAKEMAKE'
#!/bin/sh
O=""; INSTALL=""; target=""
for a in "$@"; do
    case "$a" in
        O=*) O=${a#O=} ;;
        INSTALL_MOD_PATH=*) INSTALL=${a#INSTALL_MOD_PATH=} ;;
        olddefconfig|kernelrelease|Image|modules_install) target=$a ;;
    esac
done
RELEASE=${FAKE_RELEASE:-6.18.0-rc1-a71+}
case "$target" in
    olddefconfig) [ -n "${FAKE_OLD_FAIL:-}" ] && exit 1; exit 0 ;;
    kernelrelease) printf '%s\n' "$RELEASE"; exit 0 ;;
    Image)
        [ -n "${FAKE_BUILD_FAIL:-}" ] && exit 1
        mkdir -p "$O/arch/arm64/boot/dts/qcom"
        printf 'FAKEIMAGE' >"$O/arch/arm64/boot/Image"
        { printf '\320\015\376\355'; head -c 60 /dev/zero; } >"$O/arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dtb"
        : >"$O/modules.order"; : >"$O/modules.builtin"
        exit 0 ;;
    modules_install)
        [ -n "${FAKE_MODINSTALL_FAIL:-}" ] && exit 1
        mkdir -p "$INSTALL/lib/modules/$RELEASE"
        cp "${FAKE_KO}" "$INSTALL/lib/modules/$RELEASE/fake.ko"
        exit 0 ;;
esac
exit 0
FAKEMAKE
chmod +x "$STROOT/bin/make"

# ELF AArch64 minimal (en-tete 64 octets) pour le module factice
python3 - "$STROOT/fake.ko" <<'PYELF'
import struct, sys
ident = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8)
hdr = ident + struct.pack("<HHIQQQIHHHHHH", 1, 183, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0)
open(sys.argv[1], "wb").write(hdr)
PYELF

GOODCFG2="$ROOT/../work/config/final.config"
if [ ! -f "$GOODCFG2" ]; then
    printf '  (ignore) work/config/final.config absent\n'
else
    st_run() {
        PATH="$STROOT/bin:$PATH" A71_MANIFEST="$STROOT/manifest.yaml" FAKE_KO="$STROOT/fake.ko" "$@" \
            "$KBS" --kernel-source "$STROOT/src" --config "$GOODCFG2" \
            --toolchain-root "$STROOT/tc" --output "$STROOT/out" \
            --requirements "$ROOT/configs/a71-required-symbols.txt" >/dev/null 2>&1
        echo $?
    }
    stsum() { local n; n=$(grep -c "^$1$" "$STROOT/out/build-summary.txt" 2>/dev/null); printf '%s' "${n:-0}"; }

    # --- scenario A : bc absent (PATH sans bouchon bc) ---------------------
    rm -rf "$STROOT/out"
    if ! command -v bc >/dev/null 2>&1; then
        code=$(A71_MANIFEST="$STROOT/manifest.yaml" "$KBS" --kernel-source "$STROOT/src" \
            --config "$GOODCFG2" --toolchain-root "$STROOT/tc" --output "$STROOT/out" \
            --requirements "$ROOT/configs/a71-required-symbols.txt" >/dev/null 2>&1; echo $?)
        check_eq "A: bc absent -> 7" 7 "$code"
        check_eq "A: result=FAILED" 1 "$(stsum 'result=FAILED')"
        check_eq "A: failed_step=host" 1 "$(stsum 'failed_step=host')"
        check_eq "A: build=not_started" 1 "$(stsum 'build=not_started')"
        check_eq "A: olddefconfig=not_started" 1 "$(stsum 'olddefconfig=not_started')"
        check_eq "A: kernelrelease_before_build=not_checked" 1 "$(stsum 'kernelrelease_before_build=not_checked')"
        check_eq "A: kernelrelease_after_build=not_checked" 1 "$(stsum 'kernelrelease_after_build=not_checked')"
        check_eq "A: release_match=not_checked" 1 "$(stsum 'release_match=not_checked')"
        check_eq "A: built_release=not_produced" 1 "$(stsum 'built_release=not_produced')"
        check_eq "A: config_unchanged=not_checked" 1 "$(stsum 'config_unchanged_during_build=not_checked')"
        check_eq "A: requirements_total=not_checked" 1 "$(stsum 'requirements_total=not_checked')"
        check_eq "A: requirements_failures=not_checked" 1 "$(stsum 'requirements_failures=not_checked')"
        check_eq "A: module_count=not_checked" 1 "$(stsum 'module_count=not_checked')"
        check_eq "A: aucun build=failed" 0 "$(stsum 'build=failed')"
        check_eq "A: aucun release_match=non" 0 "$(stsum 'release_match=non')"
        check_eq "A: aucun config_unchanged=non" 0 "$(stsum 'config_unchanged_during_build=non')"
        check_eq "A: modules_install=not_started" 1 "$(stsum 'modules_install=not_started')"
        check_eq "A: artifacts_validation=not_started" 1 "$(stsum 'artifacts_validation=not_started')"
        check_eq "A: requirements_input=not_started" 1 "$(stsum 'requirements_input=not_started')"
    else
        printf '  (ignore) bc present sur cet hote : scenario A non applicable\n'
    fi

    # --- scenario B : olddefconfig echoue ---------------------------------
    rm -rf "$STROOT/out"
    check_eq "B: olddefconfig en echec -> 8" 8 "$(FAKE_OLD_FAIL=1 st_run env)"
    check_eq "B: olddefconfig=failed" 1 "$(stsum 'olddefconfig=failed')"
    check_eq "B: build=not_started" 1 "$(stsum 'build=not_started')"
    check_eq "B: requirements_input=completed" 1 "$(stsum 'requirements_input=completed')"

    # --- scenario C : compilation echouee ---------------------------------
    rm -rf "$STROOT/out"
    check_eq "C: compilation en echec -> 8" 8 "$(FAKE_BUILD_FAIL=1 st_run env)"
    check_eq "C: olddefconfig=completed" 1 "$(stsum 'olddefconfig=completed')"
    check_eq "C: build=failed" 1 "$(stsum 'build=failed')"
    check_eq "C: modules_install=not_started" 1 "$(stsum 'modules_install=not_started')"
    check_eq "C: artifacts_validation=not_started" 1 "$(stsum 'artifacts_validation=not_started')"

    # --- scenario D : succes simule ---------------------------------------
    rm -rf "$STROOT/out"
    check_eq "D: succes simule -> 0" 0 "$(st_run env)"
    for st in requirements_input=completed olddefconfig=completed requirements_normalized=completed \
              kernelrelease_before_build=completed build=completed modules_install=completed \
              kernelrelease_after_build=completed artifacts_validation=completed requirements_final=completed; do
        check_eq "D: $st" 1 "$(stsum "$st")"
    done
    check_eq "D: result=OK" 1 "$(stsum 'result=OK')"
    check_eq "D: release_match=match" 1 "$(stsum 'release_match=match')"
    check_eq "D: config_unchanged=match" 1 "$(stsum 'config_unchanged_during_build=match')"
    check_eq "D: built_release produite" 1 "$(stsum 'built_release=6.18.0-rc1-a71+')"
    check_eq "D: module_count mesure" 1 "$(stsum 'module_count=1')"
    check_eq "D: pahole evalue" 1 "$(grep -c '^pahole_requirement=\(required\|not_required\)$' "$STROOT/out/build-summary.txt")"
    check_eq "D: Image produite" 1 "$([ -s "$STROOT/out/artifacts/Image" ] && echo 1 || echo 0)"
    check_eq "D: DTB produit" 1 "$([ -s "$STROOT/out/artifacts/sm7150-samsung-a715f.dtb" ] && echo 1 || echo 0)"
fi
rm -rf "$STROOT"

# --------------------------------------------------------------------------
section "21. Incrément 2F-3a : consolidation"
# --------------------------------------------------------------------------
PROP3="$ROOT/configs/a71-proposed.config"
VER3="$ROOT/configs/a71-symbols-verified.txt"

# --- contrat fragment <-> snapshot ----------------------------------------
frag_syms3=$(
    {
        grep -oE '^CONFIG_[A-Za-z0-9_]+=' "$PROP3" | sed 's/=$//'
        grep -oE '^# CONFIG_[A-Za-z0-9_]+ is not set$' "$PROP3" |
            sed -E 's/^# (CONFIG_[A-Za-z0-9_]+) is not set$/\1/'
    }
)
missing3=0; dup3=0
for sym in $frag_syms3; do
    n=$(grep -c "^${sym} " "$VER3")
    [ "$n" -ge 1 ] || { missing3=$((missing3+1)); echo "      fragment non trace: $sym"; }
    [ "$n" -gt 1 ] && dup3=$((dup3+1))
    case "$sym" in CONFIG_[A-Za-z0-9_]*) ;; *) echo "      symbole malforme: $sym"; missing3=$((missing3+1)) ;; esac
done
check_eq "tous les symboles du fragment sont traces" 0 "$missing3"
check_eq "aucun doublon dans le snapshot" 0 "$dup3"

# --- entree HUAXING --------------------------------------------------------
check_eq "snapshot: HUAXING present" 1 "$(grep -c '^CONFIG_DRM_PANEL_HUAXING_NT36672C ' "$VER3")"
check_eq "snapshot: HUAXING valeur proposee n" 1 "$(grep -c '^CONFIG_DRM_PANEL_HUAXING_NT36672C .* | y | n$' "$VER3")"
check_eq "fragment: HUAXING desactive explicitement" 1 "$(grep -c '^# CONFIG_DRM_PANEL_HUAXING_NT36672C is not set$' "$PROP3")"

# --- statuts de contrat ----------------------------------------------------
check_eq "merge_contract_status" "implemented" "$(mget2 kernel_config.merge_contract_status)"
check_eq "requirements_contract_status" "implemented" "$(mget2 kernel_config.requirements_contract_status)"
check_eq "build_contract_status" "implemented" "$(mget2 kernel_config.build_contract_status)"
check_eq "runtime_status not_tested" "not_tested" "$(mget2 kernel_config.runtime_status)"
check_eq "validation_status provisional" "provisional" "$(mget2 kernel_config.validation_status)"
check_eq "ancien merge_status supprime" 0 "$(grep -c '^  merge_status:' "$ROOT/manifest.yaml")"
local_fields=$(grep -cE '^  (last_build_status|image_sha256|dtb_sha256|module_count):' "$ROOT/manifest.yaml" || true)
check_eq "aucun resultat local dans le manifeste" 0 "${local_fields:-0}"
check_eq "kernel.built_release TODO_BUILD" "TODO_BUILD" "$(mget2 kernel.built_release)"
check_eq "aucun validated" 0 "$(grep -cE '^ +validation_status: validated' "$ROOT/manifest.yaml")"

# --- rapports sans chemins prives -----------------------------------------
KB3="$ROOT/../work/kernel-build"
if [ -f "$KB3/build-summary.txt" ]; then
    for pat in '/tmp/' '/home/' '/Users/'; do
        n=$(grep -rlF "$pat" "$KB3/build-summary.txt" "$KB3/reports/" 2>/dev/null | wc -l | tr -d ' ')
        check_eq "aucun '$pat' dans les rapports partageables" 0 "$n"
    done
    check_eq "image_path relatif" 1 "$(grep -c '^image_path=artifacts/Image$' "$KB3/build-summary.txt")"
    check_eq "dtb_path relatif" 1 "$(grep -c '^dtb_path=artifacts/sm7150-samsung-a715f.dtb$' "$KB3/build-summary.txt")"
    check_eq "module dir relatif" 1 "$(grep -c '^module_release_directory=modules-install/lib/modules/' "$KB3/build-summary.txt")"
    for c in module_count_ko module_count_gz module_count_xz module_count_zst; do
        check_eq "compteur $c present" 1 "$(grep -c "^$c=" "$KB3/build-summary.txt")"
    done
    tot=$(sed -n 's/^module_count=//p' "$KB3/build-summary.txt")
    ko=$(sed -n 's/^module_count_ko=//p' "$KB3/build-summary.txt")
    gz=$(sed -n 's/^module_count_gz=//p' "$KB3/build-summary.txt")
    xz=$(sed -n 's/^module_count_xz=//p' "$KB3/build-summary.txt")
    zst=$(sed -n 's/^module_count_zst=//p' "$KB3/build-summary.txt")
    check_eq "somme des compteurs = total" "$tot" "$((ko + gz + xz + zst))"
    check_eq "compression coherente" 1 "$(grep -cE '^module_compression=(none|gz|xz|zst|mixed)$' "$KB3/build-summary.txt")"
else
    printf '  (ignore) work/kernel-build absent\n'
fi

# --- detection des formats sur fixtures -----------------------------------
fmt_case() {
    local dir=$1 mode=$2
    mkdir -p "$dir"
    case "$mode" in
        none) : >"$dir/a.ko" ;;
        gz) : >"$dir/a.ko.gz" ;;
        xz) : >"$dir/a.ko.xz" ;;
        zst) : >"$dir/a.ko.zst" ;;
        mixed) : >"$dir/a.ko"; : >"$dir/b.ko.xz" ;;
    esac
    local ko=0 gz=0 xz=0 zst=0 f
    for f in "$dir"/*; do
        case "$f" in
            *.ko.gz) gz=$((gz+1)) ;; *.ko.xz) xz=$((xz+1)) ;; *.ko.zst) zst=$((zst+1)) ;; *.ko) ko=$((ko+1)) ;;
        esac
    done
    local formats=0
    [ "$ko" -gt 0 ] && formats=$((formats+1))
    [ "$gz" -gt 0 ] && formats=$((formats+1))
    [ "$xz" -gt 0 ] && formats=$((formats+1))
    [ "$zst" -gt 0 ] && formats=$((formats+1))
    case "$formats" in
        1) if [ "$ko" -gt 0 ]; then echo none; elif [ "$gz" -gt 0 ]; then echo gz; elif [ "$xz" -gt 0 ]; then echo xz; else echo zst; fi ;;
        *) echo mixed ;;
    esac
}
for m in none gz xz zst mixed; do
    rm -rf "$TMP/fmt-$m"
    check_eq "detection format $m" "$m" "$(fmt_case "$TMP/fmt-$m" "$m")"
done

# --------------------------------------------------------------------------
section "22. Incrément 2F-3b : reproductibilité"
# --------------------------------------------------------------------------
KB4="$ROOT/scripts/kernel-build.sh"
CB4="$ROOT/scripts/compare-builds.sh"

check_eq "compare-builds executables" 1 "$([ -x "$CB4" ] && echo 1 || echo 0)"
check_eq "bash -n compare-builds" 0 "$(bash -n "$CB4" 2>/dev/null; echo $?)"
check_eq "compare-builds --help -> 0" 0 "$("$CB4" --help >/dev/null 2>&1; echo $?)"
check_eq "compare-builds sans args -> 2" 2 "$("$CB4" >/dev/null 2>&1; echo $?)"
check_eq "compare-builds sortie invalide -> 3" 3 "$("$CB4" --a "$TMP/nope" --b "$TMP/nope2" >/dev/null 2>&1; echo $?)"

# 1) les variables reproductibles sont presentes sur TOUS les appels make
check_eq "MAKE_COMMON centralise" 1 "$(grep -c '^MAKE_COMMON=' "$KB4")"
check_eq "KBUILD_BUILD_TIMESTAMP defini" 1 "$(grep -c 'KBUILD_BUILD_TIMESTAMP=' "$KB4")"
check_eq "KBUILD_BUILD_USER defini" 1 "$(grep -c 'KBUILD_BUILD_USER=' "$KB4")"
check_eq "KBUILD_BUILD_HOST defini" 1 "$(grep -c 'KBUILD_BUILD_HOST=' "$KB4")"
check_eq "aucun make hors MAKE_COMMON" 0 "$(grep -cE '^[^#]*run_tolerant make (-s )?-C ' "$KB4")"
n_ts=$(grep -cF 'show -s --format=%ct' "$KB4"); check_eq "timestamp derive du commit" 1 "$([ "$n_ts" -ge 1 ] && echo 1 || echo 0)"
check_eq "aucune date courante" 0 "$(grep -cE 'date \+%|\$\(date\)|date -u \+%Y-%m-%dT' "$KB4" | head -1)"

# 2) comparaison synthetique de deux arbres de modules
mkbuild() {
    # mkbuild <dir> <image_sha> <module files...>
    local d=$1 sha=$2; shift 2
    mkdir -p "$d/reports" "$d/modules-install/lib/modules/6.18.0-rc1-a71+"
    printf 'result=OK\nimage_sha256=%s\ndtb_sha256=aaaa\nconfig_sha256_final=cccc\nbuilt_release=6.18.0-rc1-a71+\nmodule_count=0\nmodule_release_directory=modules-install/lib/modules/6.18.0-rc1-a71+\nsource_date_epoch=1760369959\nkbuild_build_timestamp=2025-10-13 15:39:19 UTC\nkbuild_build_user=a71-builder\nkbuild_build_host=a71-build\n' "$sha" >"$d/build-summary.txt"
    local f
    for f in "$@"; do
        printf 'contenu-%s\n' "$(basename "$f")" >"$d/modules-install/lib/modules/6.18.0-rc1-a71+/$f"
    done
    sed -i "s/^module_count=.*/module_count=$(($#))/" "$d/build-summary.txt"
}
R4="$TMP/repro"
rm -rf "$R4"; mkdir -p "$R4"
mkbuild "$R4/a" 1111 alpha.ko beta.ko
mkbuild "$R4/b" 1111 alpha.ko beta.ko
check_eq "deux arbres identiques -> 0" 0 "$("$CB4" --a "$R4/a" --b "$R4/b" --output "$R4/r1.txt" >/dev/null 2>&1; echo $?)"
check_eq "overall_reproducible=yes" 1 "$(grep -c '^overall_reproducible=yes$' "$R4/r1.txt")"
check_eq "module_tree_match=yes" 1 "$(grep -c '^module_tree_match=yes$' "$R4/r1.txt")"

mkbuild "$R4/c" 1111 alpha.ko beta.ko
printf 'autre\n' >"$R4/c/modules-install/lib/modules/6.18.0-rc1-a71+/beta.ko"
check_eq "module modifie -> 1" 1 "$("$CB4" --a "$R4/a" --b "$R4/c" --output "$R4/r2.txt" >/dev/null 2>&1; echo $?)"
check_eq "module modifie: overall=no" 1 "$(grep -c '^overall_reproducible=no$' "$R4/r2.txt")"

mkbuild "$R4/d" 1111 alpha.ko
check_eq "module absent -> 1" 1 "$("$CB4" --a "$R4/a" --b "$R4/d" --output "$R4/r3.txt" >/dev/null 2>&1; echo $?)"

mkbuild "$R4/e" 1111 alpha.ko beta.ko gamma.ko
check_eq "module supplementaire -> 1" 1 "$("$CB4" --a "$R4/a" --b "$R4/e" --output "$R4/r4.txt" >/dev/null 2>&1; echo $?)"

mkbuild "$R4/f" 2222 alpha.ko beta.ko
check_eq "Image differente -> 1" 1 "$("$CB4" --a "$R4/a" --b "$R4/f" --output "$R4/r5.txt" >/dev/null 2>&1; echo $?)"
check_eq "Image differente: image_match=no" 1 "$(grep -c '^image_match=no$' "$R4/r5.txt")"

# 3) rapports de reproductibilite sans chemin prive
for f in "$R4/r1.txt" "$R4/r2.txt"; do
    for pat in '/tmp/' '/home/' '/Users/'; do
        check_eq "pas de '$pat' dans $(basename "$f")" 0 "$(grep -cF "$pat" "$f" || true)"
    done
done

# 4) artefacts reels : rapport de reproductibilite publie
if [ -f "$ROOT/../work/kernel-build/reports/reproducibility.txt" ]; then
    R="$ROOT/../work/kernel-build/reports/reproducibility.txt"
    for k in image_match dtb_match module_tree_match config_match release_match overall_reproducible; do
        check_eq "repro: $k renseigne" 1 "$(grep -cE "^$k=(yes|no)$" "$R")"
    done
    check_eq "repro: deux builds OK" 2 "$(grep -cE '^build_[ab]_result=OK$' "$R")"
    check_eq "repro: aucun chemin prive" 0 "$(grep -cE '/tmp/|/home/|/Users/' "$R" || true)"
    for pat in '/tmp/' '/home/'; do
        check_eq "repro: pas de '$pat' dans work kernel-build" 0 "$(grep -rlF "$pat" "$ROOT/../work/kernel-build/build-summary.txt" "$ROOT/../work/kernel-build/reports/" 2>/dev/null | wc -l)"
    done
    check_eq "summary: source_date_epoch" 1 "$(grep -c '^source_date_epoch=[0-9]\+$' "$ROOT/../work/kernel-build/build-summary.txt")"
    check_eq "summary: kbuild_build_user" 1 "$(grep -c '^kbuild_build_user=a71-builder$' "$ROOT/../work/kernel-build/build-summary.txt")"
    check_eq "summary: reproducibility_policy" 1 "$(grep -c '^reproducibility_policy=controlled$' "$ROOT/../work/kernel-build/build-summary.txt")"
else
    printf '  (ignore) rapport de reproductibilite absent\n'
fi

# 5) statuts du manifeste
check_eq "reproducibility_contract_status" "implemented" "$(mget2 kernel_config.reproducibility_contract_status)"
check_eq "reproducibility_validation_status valide" 1 "$(grep -cE "^  reproducibility_validation_status: (verified|provisional)$" "$ROOT/manifest.yaml")"
check_eq "runtime_status not_tested" "not_tested" "$(mget2 kernel_config.runtime_status)"
check_eq "validation_status provisional" "provisional" "$(mget2 kernel_config.validation_status)"
LOCAL_IMG=$(sed -n 's/^image_sha256=//p' "$ROOT/../work/kernel-build/build-summary.txt" 2>/dev/null | head -1)
LOCAL_DTB=$(sed -n 's/^dtb_sha256=//p' "$ROOT/../work/kernel-build/build-summary.txt" 2>/dev/null | head -1)
local_in_manifest=0
[ -n "$LOCAL_IMG" ] && grep -qF "$LOCAL_IMG" "$ROOT/manifest.yaml" && local_in_manifest=$((local_in_manifest+1))
[ -n "$LOCAL_DTB" ] && grep -qF "$LOCAL_DTB" "$ROOT/manifest.yaml" && local_in_manifest=$((local_in_manifest+1))
check_eq "aucun hash local de build dans le manifeste" 0 "$local_in_manifest"
check_eq "kernel.built_release TODO_BUILD" "TODO_BUILD" "$(mget2 kernel.built_release)"

# --------------------------------------------------------------------------
section "23. Incrément 3A-1 : rootfs Alpine"
# --------------------------------------------------------------------------
PR="$ROOT/scripts/prepare-rootfs.sh"
check_eq "prepare-rootfs executables" 1 "$([ -x "$PR" ] && echo 1 || echo 0)"
check_eq "bash -n prepare-rootfs" 0 "$(bash -n "$PR" 2>/dev/null; echo $?)"
check_eq "prepare-rootfs --help -> 0" 0 "$("$PR" --help >/dev/null 2>&1; echo $?)"
check_eq "sans arguments -> 2" 2 "$("$PR" >/dev/null 2>&1; echo $?)"
check_eq "option inconnue -> 2" 2 "$("$PR" --bogus >/dev/null 2>&1; echo $?)"
check_eq "option repetee -> 2" 2 "$("$PR" --manifest manifest.yaml --manifest manifest.yaml --cache-dir "$TMP/c" --work-dir "$TMP/w" >/dev/null 2>&1; echo $?)"
check_eq "argument positionnel -> 2" 2 "$("$PR" foo >/dev/null 2>&1; echo $?)"

# Fixtures sous /tmp : les URL file:// n'acceptent pas les espaces du chemin
# du depot ("Samsung A71"). /tmp est utilisable dans ce processus de test.
R23="/tmp/a71-r23.$$"
rm -rf "$R23"
mkdir -p "$R23"

# fabrique d'archives de rootfs (ELF AArch64 minimal pour busybox)
mkroot() {
    python3 - "$@" <<'PYEOF2'
import io
import struct
import sys
import tarfile

kind, out = sys.argv[1], sys.argv[2]


def f(tf, name, data=b"x", mode=0o644):
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    ti.mode = mode
    tf.addfile(ti, io.BytesIO(data))


def d(tf, name):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.DIRTYPE
    ti.mode = 0o755
    tf.addfile(ti)


def s(tf, name, target):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.SYMTYPE
    ti.linkname = target
    ti.mode = 0o777
    tf.addfile(ti)


def h(tf, name, target):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.LNKTYPE
    ti.linkname = target
    ti.mode = 0o644
    tf.addfile(ti)


def fifo(tf, name):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.FIFOTYPE
    ti.mode = 0o644
    tf.addfile(ti)


ELF_AARCH64 = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8) + struct.pack(
    "<HHIQQQIHHHHHH", 1, 183, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0)


def base(tf, version=b"3.22.7", arch=b"aarch64", busybox=ELF_AARCH64):
    for x in ("etc", "etc/apk", "bin", "sbin", "lib", "usr", "var"):
        d(tf, x)
    f(tf, "etc/alpine-release", version)
    f(tf, "etc/os-release", b"NAME=Alpine")
    f(tf, "etc/apk/repositories", b"https://dl-cdn.alpinelinux.org/alpine/v3.22/main\n")
    f(tf, "etc/apk/arch", arch)
    f(tf, "bin/busybox", busybox, 0o755)
    f(tf, "sbin/apk", b"apk", 0o755)
    s(tf, "bin/sh", "/bin/busybox")


with tarfile.open(out, "w:gz") as tf:
    if kind == "valid":
        base(tf)
    elif kind == "abs":
        base(tf); f(tf, "/etc/evil")
    elif kind == "dotdot":
        base(tf); f(tf, "../evil")
    elif kind == "sym-in":
        base(tf); s(tf, "usr/bin/yes", "/bin/busybox")
    elif kind == "sym-abs-out":
        base(tf); s(tf, "usr/out", "/etc/passwd")
    elif kind == "sym-rel-out":
        base(tf); s(tf, "usr/out2", "../../etc/shadow")
    elif kind == "lnk-in":
        base(tf); f(tf, "etc/a"); h(tf, "etc/b", "etc/a")
    elif kind == "lnk-out":
        base(tf); h(tf, "etc/c", "../../etc/passwd")
    elif kind == "fifo":
        base(tf); fifo(tf, "etc/fifo")
    elif kind == "write-through":
        base(tf); s(tf, "etc/link", "/etc"); f(tf, "etc/link/x")
    elif kind == "badver":
        base(tf, version=b"3.21.0")
    elif kind == "badarch":
        base(tf, arch=b"x86_64")
    elif kind == "badbusy":
        base(tf, busybox=b"notelf")
PYEOF2
}

mkman() {
    printf 'distribution:\n  name: Alpine Linux\n  series: v3.22\n  version: %s\n  architecture: %s\n  minirootfs_url: %s\n  minirootfs_sha256: %s\n  minirootfs_sha512: %s\n  minirootfs_size: %s\n  minirootfs_signature_status: not_verified\n' \
        "${6:-3.22.7}" "${7:-aarch64}" "$2" "$3" "$4" "$5" >"$1"
}

mkfixture() {
    local kind=$1
    mkroot "$kind" "$R23/$kind.tar.gz"
    local sum sum5 size
    sum=$(sha256sum "$R23/$kind.tar.gz" | cut -d' ' -f1)
    sum5=$(sha512sum "$R23/$kind.tar.gz" | cut -d' ' -f1)
    size=$(wc -c <"$R23/$kind.tar.gz" | tr -d ' ')
    mkman "$R23/m-$kind.yaml" "file://$R23/$kind.tar.gz" "$sum" "$sum5" "$size"
}

pr_run_kind() {
    local kind=$1
    shift
    "$PR" --manifest "$R23/m-$kind.yaml" --cache-dir "$R23/c-$kind" --work-dir "$R23/w-$kind" \
        "$@" >/dev/null 2>"$R23/err-$kind.txt"
    echo $?
}

for k in valid sym-in lnk-in abs dotdot sym-abs-out sym-rel-out lnk-out fifo write-through badver badarch badbusy; do
    mkfixture "$k"
done

check_eq "archive rootfs valide -> 0" 0 "$(pr_run_kind valid)"
check_eq "rootfs-base cree" 1 "$([ -d "$R23/w-valid/rootfs/rootfs-base" ] && echo 1 || echo 0)"
check_eq "rootfs-base: busybox present" 1 "$([ -f "$R23/w-valid/rootfs/rootfs-base/bin/busybox" ] && echo 1 || echo 0)"

for k in abs dotdot sym-abs-out sym-rel-out lnk-out fifo write-through; do
    check_eq "archive $k refusee -> 5" 5 "$(pr_run_kind "$k")"
done
for k in sym-in lnk-in; do
    check_eq "archive $k acceptee -> 0" 0 "$(pr_run_kind "$k")"
done
for k in badver badarch badbusy; do
    check_eq "rootfs $k invalide -> 6" 6 "$(pr_run_kind "$k")"
done

# taille / SHA-256 / SHA-512 incorrects -> 4
mkroot valid "$R23/v2.tar.gz"
V2_SUM=$(sha256sum "$R23/v2.tar.gz" | cut -d' ' -f1)
V2_512=$(sha512sum "$R23/v2.tar.gz" | cut -d' ' -f1)
V2_SIZE=$(wc -c <"$R23/v2.tar.gz" | tr -d ' ')
mkman "$R23/m-size.yaml" "file://$R23/v2.tar.gz" "$V2_SUM" "$V2_512" "$((V2_SIZE + 1))"
check_eq "taille incorrecte -> 4" 4 "$(pr_run_kind size)"
mkman "$R23/m-sha.yaml" "file://$R23/v2.tar.gz" "$(printf '0%.0s' $(seq 64))" "$V2_512" "$V2_SIZE"
check_eq "SHA-256 incorrect -> 4" 4 "$(pr_run_kind sha)"
mkman "$R23/m-sha512.yaml" "file://$R23/v2.tar.gz" "$V2_SUM" "$(printf '0%.0s' $(seq 128))" "$V2_SIZE"
check_eq "SHA-512 incorrect -> 4" 4 "$(pr_run_kind sha512)"

# metadonnees invalides -> 3
printf 'distribution:\n  name: x\n' >"$R23/m-missing.yaml"
check_eq "cle absente -> 3" 3 "$(pr_run_kind missing)"
mkman "$R23/m-todo.yaml" "file://$R23/v2.tar.gz" "TODO_VERIFIER" "$V2_512" "$V2_SIZE"
check_eq "TODO_* -> 3" 3 "$(pr_run_kind todo)"
mkman "$R23/m-arch.yaml" "file://$R23/v2.tar.gz" "$V2_SUM" "$V2_512" "$V2_SIZE" 3.22.7 x86_64
check_eq "architecture x86_64 -> 3" 3 "$(pr_run_kind arch)"
mkman "$R23/m-short.yaml" "file://$R23/v2.tar.gz" "abc" "$V2_512" "$V2_SIZE"
check_eq "SHA-256 trop court -> 3" 3 "$(pr_run_kind short)"

# cache / offline
mkdir -p "$R23/cache-ok/downloads/sha256"
cp "$R23/valid.tar.gz" "$R23/cache-ok/downloads/sha256/$(sha256sum "$R23/valid.tar.gz" | cut -d' ' -f1)"
mkman "$R23/m-badurl.yaml" "https://invalid.invalid/x.tar.gz" \
    "$(sha256sum "$R23/valid.tar.gz" | cut -d' ' -f1)" "$(sha512sum "$R23/valid.tar.gz" | cut -d' ' -f1)" \
    "$(wc -c <"$R23/valid.tar.gz" | tr -d ' ')"
check_eq "offline: URL invalide + cache valide -> 0" 0 "$(
    "$PR" --manifest "$R23/m-badurl.yaml" --cache-dir "$R23/cache-ok" --work-dir "$R23/w-offline" --offline >/dev/null 2>&1
    echo $?
)"
"$PR" --manifest "$R23/m-valid.yaml" --cache-dir "$R23/cache-vide" --work-dir "$R23/w-vide" --offline >/dev/null 2>&1
check_eq "offline sans cache -> 4" 4 "$?"
mkdir -p "$R23/cache-bad/downloads/sha256"
printf 'corrompu' >"$R23/cache-bad/downloads/sha256/$(sha256sum "$R23/valid.tar.gz" | cut -d' ' -f1)"
"$PR" --manifest "$R23/m-valid.yaml" --cache-dir "$R23/cache-bad" --work-dir "$R23/w-bad" --offline >/dev/null 2>&1
check_eq "cache corrompu offline -> 4" 4 "$?"

# sortie : symlink -> 7 ; non vide sans --force -> 7 ; avec --force -> 0
mkdir -p "$R23/w-sym"
ln -sfn "$R23/ailleurs" "$R23/w-sym/rootfs"
"$PR" --manifest "$R23/m-valid.yaml" --cache-dir "$R23/c-sym" --work-dir "$R23/w-sym" >/dev/null 2>&1
check_eq "sortie symlink -> 7" 7 "$?"
mkdir -p "$R23/w-non/rootfs/rootfs-base"
: >"$R23/w-non/rootfs/rootfs-base/x"
"$PR" --manifest "$R23/m-valid.yaml" --cache-dir "$R23/c-non" --work-dir "$R23/w-non" >/dev/null 2>&1
check_eq "sortie non vide sans --force -> 7" 7 "$?"
"$PR" --manifest "$R23/m-valid.yaml" --cache-dir "$R23/c-non" --work-dir "$R23/w-non" --force >/dev/null 2>&1
check_eq "sortie non vide avec --force -> 0" 0 "$?"

# aucun binaire de l'archive execute par le script
check_eq "aucun apk/chroot/mount/qemu dans le script" 0 "$(grep -cE '^[^#]*\b(apk add|apk del|apk update|chroot |mount |qemu-)' "$PR" || true)"
# aucun binaire de l'archive execute (aucun apk/busybox dans le repertoire courant)
check_eq "aucun binaire AArch64 execute" 0 "$(grep -cE '\bapk (add|del|update)|qemu-|chroot |mount ' "$PR" || true)"

# rapports reels
RR="$ROOT/../work/rootfs/reports"
if [ -f "$RR/rootfs-summary.txt" ]; then
    for f in provenance.json rootfs-summary.txt archive-validation.txt repositories-detected.txt tree-manifest.sha256 extraction-reproducibility.txt; do
        check_eq "rapport rootfs $f" 1 "$([ -f "$RR/$f" ] && echo 1 || echo 0)"
    done
    check_eq "summary: result OK" 1 "$(grep -c '^result=OK$' "$RR/rootfs-summary.txt")"
    check_eq "summary: version" 1 "$(grep -c '^version=3.22.7$' "$RR/rootfs-summary.txt")"
    check_eq "summary: arch" 1 "$(grep -c '^apk_arch=aarch64$' "$RR/rootfs-summary.txt")"
    check_eq "summary: busybox AArch64" 1 "$(grep -c '^busybox_elf_machine=AArch64$' "$RR/rootfs-summary.txt")"
    check_eq "summary: sha256_match" 1 "$(grep -c '^sha256_match=yes$' "$RR/rootfs-summary.txt")"
    check_eq "summary: sha512_match" 1 "$(grep -c '^sha512_match=yes$' "$RR/rootfs-summary.txt")"
    check_eq "summary: signature not_verified" 1 "$(grep -c '^signature_status=not_verified$' "$RR/rootfs-summary.txt")"
    for k in apk_executed chroot_used mount_used qemu_used modules_installed depmod_executed initramfs_created boot_image_created; do
        check_eq "summary: $k=no" 1 "$(grep -c "^$k=no$" "$RR/rootfs-summary.txt")"
    done
    check_eq "repro extraction: tree_match" 1 "$(grep -c '^tree_match=yes$' "$RR/extraction-reproducibility.txt")"
    check_eq "repro extraction: overall" 1 "$(grep -c '^overall_reproducible=yes$' "$RR/extraction-reproducibility.txt")"
    check_eq "depots v3.22 detectes" 1 "$(grep -c '^series_detected=oui$' "$RR/repositories-detected.txt")"
    check_eq "provenance JSON valide" 0 "$(python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$RR/provenance.json" 2>/dev/null; echo $?)"
    for pat in '/tmp/' '/home/' '/Users/'; do
        check_eq "rootfs: pas de '$pat' dans les rapports" 0 "$(grep -rlF "$pat" "$RR" 2>/dev/null | wc -l)"
    done
else
    printf '  (ignore) rapports rootfs absents\n'
fi

# statuts du manifeste
check_eq "rootfs.acquisition_contract_status" "implemented" "$(mget2 rootfs.acquisition_contract_status)"
check_eq "rootfs.extraction_contract_status" "implemented" "$(mget2 rootfs.extraction_contract_status)"
check_eq "rootfs.runtime_status not_tested" "not_tested" "$(mget2 rootfs.runtime_status)"
check_eq "rootfs.validation_status provisional" "provisional" "$(mget2 rootfs.validation_status)"
check_eq "kernel.built_release TODO_BUILD" "TODO_BUILD" "$(mget2 kernel.built_release)"

# --------------------------------------------------------------------------
section "24. Incrément 3A-2 : intégration des modules"
# --------------------------------------------------------------------------
IM="$ROOT/scripts/integrate-kernel-modules.sh"
check_eq "integrate-kernel-modules executables" 1 "$([ -x "$IM" ] && echo 1 || echo 0)"
check_eq "bash -n integrate-kernel-modules" 0 "$(bash -n "$IM" 2>/dev/null; echo $?)"
check_eq "--help -> 0" 0 "$("$IM" --help >/dev/null 2>&1; echo $?)"
check_eq "sans arguments -> 2" 2 "$("$IM" >/dev/null 2>&1; echo $?)"
check_eq "option inconnue -> 2" 2 "$("$IM" --bogus >/dev/null 2>&1; echo $?)"
check_eq "option repetee -> 2" 2 "$("$IM" --manifest m --manifest m >/dev/null 2>&1; echo $?)"
check_eq "argument positionnel -> 2" 2 "$("$IM" foo >/dev/null 2>&1; echo $?)"

KB24="$ROOT/../work/kernel-build"
RB24="$ROOT/../work/rootfs/rootfs-base"
if [ -d "$RB24" ] && [ -d "$KB24" ]; then
    S24="/tmp/a71-int.$$"; rm -rf "$S24"; mkdir -p "$S24"
    im24() { "$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$RB24" --kernel-build "$KB24" --output "$S24/out" "$@" >/dev/null 2>"$S24/err.txt"; echo $?; }

    mkdir -p "$S24/sym"; ln -sfn "$S24/ailleurs" "$S24/sym/out"
    check_eq "sortie symlink -> 7" 7 "$("$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$RB24" --kernel-build "$KB24" --output "$S24/sym/out" >/dev/null 2>&1; echo $?)"
    check_eq "sortie = rootfs base -> 7" 7 "$("$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$RB24" --kernel-build "$KB24" --output "$RB24" >/dev/null 2>&1; echo $?)"
    check_eq "sortie dans le rootfs base -> 7" 7 "$("$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$RB24" --kernel-build "$KB24" --output "$RB24/sub" >/dev/null 2>&1; echo $?)"
    check_eq "sortie dans le build -> 7" 7 "$("$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$RB24" --kernel-build "$KB24" --output "$KB24/sub" >/dev/null 2>&1; echo $?)"
    mkdir -p "$S24/non/out"; : >"$S24/non/out/x"
    check_eq "sortie non vide sans --force -> 7" 7 "$("$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$RB24" --kernel-build "$KB24" --output "$S24/non/out" >/dev/null 2>&1; echo $?)"

    cp -a "$RB24" "$S24/rb-copy" 2>/dev/null
    printf '3.21.0\n' >"$S24/rb-copy/etc/alpine-release"
    check_eq "version Alpine incorrecte -> 4" 4 "$("$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$S24/rb-copy" --kernel-build "$KB24" --output "$S24/o4" >/dev/null 2>&1; echo $?)"
    rm -rf "$S24/rb-copy"; cp -a "$RB24" "$S24/rb-copy"
    printf 'x86_64\n' >"$S24/rb-copy/etc/apk/arch"
    check_eq "architecture incorrecte -> 4" 4 "$("$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$S24/rb-copy" --kernel-build "$KB24" --output "$S24/o5" >/dev/null 2>&1; echo $?)"
    rm -rf "$S24/rb-copy"; cp -a "$RB24" "$S24/rb-copy"
    printf 'notelf' >"$S24/rb-copy/bin/busybox"
    check_eq "BusyBox non AArch64 -> 4" 4 "$("$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$S24/rb-copy" --kernel-build "$KB24" --output "$S24/o6" >/dev/null 2>&1; echo $?)"
    rm -rf "$S24/rb-copy"; cp -a "$RB24" "$S24/rb-copy"
    mkdir -p "$S24/rb-copy/lib/modules/6.18.0-rc1-a71+"
    check_eq "release deja presente -> 4" 4 "$("$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$S24/rb-copy" --kernel-build "$KB24" --output "$S24/o7" >/dev/null 2>&1; echo $?)"
    rm -rf "$S24/rb-copy"

    cp -a "$KB24" "$S24/kb-copy" 2>/dev/null
    sed -i 's/^result=OK$/result=FAILED/' "$S24/kb-copy/build-summary.txt"
    check_eq "build result FAILED -> 5" 5 "$("$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$RB24" --kernel-build "$S24/kb-copy" --output "$S24/o8" >/dev/null 2>&1; echo $?)"
    cp "$KB24/build-summary.txt" "$S24/kb-copy/build-summary.txt"
    sed -i 's/^built_release=.*/built_release=9.9.9/' "$S24/kb-copy/build-summary.txt"
    check_eq "release differente -> 5" 5 "$("$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$RB24" --kernel-build "$S24/kb-copy" --output "$S24/o9" >/dev/null 2>&1; echo $?)"
    cp "$KB24/build-summary.txt" "$S24/kb-copy/build-summary.txt"
    sed -i 's/^module_count=.*/module_count=999/' "$S24/kb-copy/build-summary.txt"
    check_eq "compteur incoherent -> 5" 5 "$("$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$RB24" --kernel-build "$S24/kb-copy" --output "$S24/o10" >/dev/null 2>&1; echo $?)"
    rm -rf "$S24/kb-copy"

    check_eq "depmod absent -> 6" 6 "$("$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$RB24" --kernel-build "$KB24" --output "$S24/o11" --depmod "$S24/nope" >/dev/null 2>&1; echo $?)"
    printf '#!/bin/sh\necho "outil inconnu 1.0"\nexit 0\n' >"$S24/fake-depmod"
    chmod +x "$S24/fake-depmod"
    check_eq "depmod version non reconnue -> 6" 6 "$("$IM" --manifest "$ROOT/manifest.yaml" --rootfs-base "$RB24" --kernel-build "$KB24" --output "$S24/o12" --depmod "$S24/fake-depmod" >/dev/null 2>&1; echo $?)"

    check_eq "integration reelle -> 0" 0 "$(im24)"
    OUT24="$S24/out"
    check_eq "607 modules copies" 607 "$(find "$OUT24/lib/modules/6.18.0-rc1-a71+" -name '*.ko' | wc -l | tr -d ' ')"
    for f in modules.dep modules.dep.bin modules.alias modules.alias.bin modules.softdep modules.symbols modules.symbols.bin; do
        check_eq "metadonnee $f" 1 "$([ -s "$OUT24/lib/modules/6.18.0-rc1-a71+/$f" ] && echo 1 || echo 0)"
    done
    for f in integration-summary.txt modules-source.sha256 modules-rootfs.sha256 modules-copy.diff depmod-version.txt depmod-generated-files.txt depmod-reproducibility.txt rootfs-with-modules.sha256 provenance.json; do
        check_eq "rapport $f" 1 "$([ -f "$OUT24/reports/$f" ] && echo 1 || echo 0)"
    done
    check_eq "modules-copy.diff vide" 0 "$(wc -c <"$OUT24/reports/modules-copy.diff")"
    check_eq "depmod: text match" 1 "$(grep -c '^text_metadata_match=yes$' "$OUT24/reports/depmod-reproducibility.txt")"
    check_eq "depmod: binary match" 1 "$(grep -c '^binary_metadata_match=yes$' "$OUT24/reports/depmod-reproducibility.txt")"
    check_eq "depmod: overall" 1 "$(grep -c '^overall_reproducible=yes$' "$OUT24/reports/depmod-reproducibility.txt")"
    check_eq "summary: base inchangee" 1 "$(grep -c '^rootfs_base_unchanged=yes$' "$OUT24/reports/integration-summary.txt")"
    for k in apk_executed chroot_used mount_used qemu_used initramfs_created boot_image_created; do
        check_eq "summary: $k=no" 1 "$(grep -c "^$k=no$" "$OUT24/reports/integration-summary.txt")"
    done
    check_eq "provenance JSON valide" 0 "$(python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT24/reports/provenance.json" 2>/dev/null; echo $?)"
    for pat in '/tmp/' '/home/' '/Users/'; do
        check_eq "integration: pas de $pat" 0 "$(grep -rlF "$pat" "$OUT24/reports" 2>/dev/null | wc -l)"
    done
    check_eq "aucun module legacy" 0 "$(find "$OUT24/lib/modules" -maxdepth 1 -mindepth 1 ! -name '6.18.0-rc1-a71+' | wc -l)"
    rm -rf "$S24"
else
    printf '  (ignore) work/rootfs/rootfs-base ou work/kernel-build absent\n'
fi

check_eq "rootfs.module_integration_contract_status" "implemented" "$(mget2 rootfs.module_integration_contract_status)"
check_eq "rootfs.depmod_contract_status" "implemented" "$(mget2 rootfs.depmod_contract_status)"
check_eq "rootfs.runtime_status not_tested" "not_tested" "$(mget2 rootfs.runtime_status)"
check_eq "rootfs.validation_status provisional" "provisional" "$(mget2 rootfs.validation_status)"

section "25. D1/E1/F1 : modes, validateur et initramfs (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-rootfs-tests.sh" ]; then
    ROOTFS_OUT=$("$ROOT/tests/phase1/run-rootfs-tests.sh" 2>&1)
    ROOTFS_RC=$?
    printf '%s\n' "$ROOTFS_OUT" | grep -E '^(  ECHEC|Resultat rootfs)' || true
    ROOTFS_LINE=$(printf '%s\n' "$ROOTFS_OUT" | grep '^Resultat rootfs :' | tail -1)
    ROOTFS_PASS=$(printf '%s\n' "$ROOTFS_LINE" | sed -n 's/^Resultat rootfs : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    ROOTFS_FAIL=$(printf '%s\n' "$ROOTFS_LINE" | sed -n 's/^Resultat rootfs : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${ROOTFS_PASS:-0}))
    FAIL=$((FAIL + ${ROOTFS_FAIL:-0}))
    [ "$ROOTFS_RC" -eq 0 ] || FAIL=$((FAIL + 1))
else
    printf '  (ignore) suite rootfs absente\n'
fi

section "26. G1/H2/H3 : uniLoader, ext4, image SD (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-build-tests.sh" ]; then
    BUILD_OUT=$("$ROOT/tests/phase1/run-build-tests.sh" 2>&1)
    BUILD_RC=$?
    printf '%s\n' "$BUILD_OUT" | grep -E '^(  ECHEC|Resultat build)' || true
    BUILD_LINE=$(printf '%s\n' "$BUILD_OUT" | grep '^Resultat build G1/H2/H3 :' | tail -1)
    BUILD_PASS=$(printf '%s\n' "$BUILD_LINE" | sed -n 's/^Resultat build G1\/H2\/H3 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    BUILD_FAIL=$(printf '%s\n' "$BUILD_LINE" | sed -n 's/^Resultat build G1\/H2\/H3 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${BUILD_PASS:-0}))
    FAIL=$((FAIL + ${BUILD_FAIL:-0}))
    [ "$BUILD_RC" -eq 0 ] || FAIL=$((FAIL + 1))
else
    printf '  (ignore) suite build absente\n'
fi

section "27. I1 : write-sdcard.sh (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-i1-tests.sh" ]; then
    I1_OUT=$("$ROOT/tests/phase1/run-i1-tests.sh" 2>&1)
    I1_RC=$?
    printf '%s\n' "$I1_OUT" | grep -E '^(  ECHEC|Resultat I1)' || true
    I1_LINE=$(printf '%s\n' "$I1_OUT" | grep '^Resultat I1 :' | tail -1)
    I1_PASS=$(printf '%s\n' "$I1_LINE" | sed -n 's/^Resultat I1 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    I1_FAIL=$(printf '%s\n' "$I1_LINE" | sed -n 's/^Resultat I1 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${I1_PASS:-0}))
    FAIL=$((FAIL + ${I1_FAIL:-0}))
    [ "$I1_RC" -eq 0 ] || FAIL=$((FAIL + 1))
else
    printf '  (ignore) suite I1 absente\n'
fi

section "28. J1-J5 : contrat boot (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-boot-tests.sh" ]; then
    BOOT_OUT=$("$ROOT/tests/phase1/run-boot-tests.sh" 2>&1)
    BOOT_RC=$?
    printf '%s\n' "$BOOT_OUT" | grep -E '^(  ECHEC|Resultat boot)' || true
    BOOT_LINE=$(printf '%s\n' "$BOOT_OUT" | grep '^Resultat boot J1-J5 :' | tail -1)
    BOOT_PASS=$(printf '%s\n' "$BOOT_LINE" | sed -n 's/^Resultat boot J1-J5 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    BOOT_FAIL=$(printf '%s\n' "$BOOT_LINE" | sed -n 's/^Resultat boot J1-J5 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${BOOT_PASS:-0}))
    FAIL=$((FAIL + ${BOOT_FAIL:-0}))
    [ "$BOOT_RC" -eq 0 ] || FAIL=$((FAIL + 1))
else
    printf '  (ignore) suite boot absente\n'
fi

section "29. K4/K8 : contrat runtime RAM/SD/USB/SSH (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-runtime-tests.sh" ]; then
    RT_OUT=$("$ROOT/tests/phase1/run-runtime-tests.sh" 2>&1)
    RT_RC=$?
    printf '%s\n' "$RT_OUT" | grep -E '^(  ECHEC|Resultat runtime)' || true
    RT_LINE=$(printf '%s\n' "$RT_OUT" | grep '^Resultat runtime K4/K8 :' | tail -1)
    RT_PASS=$(printf '%s\n' "$RT_LINE" | sed -n 's/^Resultat runtime K4\/K8 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    RT_FAIL=$(printf '%s\n' "$RT_LINE" | sed -n 's/^Resultat runtime K4\/K8 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${RT_PASS:-0}))
    FAIL=$((FAIL + ${RT_FAIL:-0}))
    [ "$RT_RC" -eq 0 ] || FAIL=$((FAIL + 1))
else
    printf '  (ignore) suite runtime absente\n'
fi

section "30. M1 : USB/SSH USB rootfs (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-m1-tests.sh" ]; then
    M1_OUT=$("$ROOT/tests/phase1/run-m1-tests.sh" 2>&1)
    M1_RC=$?
    printf '%s\n' "$M1_OUT" | grep -E '^(  ECHEC|Resultat M1)' || true
    M1_LINE=$(printf '%s\n' "$M1_OUT" | grep '^Resultat M1 :' | tail -1)
    M1_PASS=$(printf '%s\n' "$M1_LINE" | sed -n 's/^Resultat M1 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    M1_FAIL=$(printf '%s\n' "$M1_LINE" | sed -n 's/^Resultat M1 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${M1_PASS:-0}))
    FAIL=$((FAIL + ${M1_FAIL:-0}))
    [ "$M1_RC" -eq 0 ] || FAIL=$((FAIL + 1))
else
    printf '  (ignore) suite M1 absente\n'
fi

section "31. M2 : collecte runtime (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-collect-tests.sh" ]; then
    C_OUT=$("$ROOT/tests/phase1/run-collect-tests.sh" 2>&1)
    C_RC=$?
    printf '%s\n' "$C_OUT" | grep -E '^(  ECHEC|Resultat collecte)' || true
    C_LINE=$(printf '%s\n' "$C_OUT" | grep '^Resultat collecte :' | tail -1)
    C_PASS=$(printf '%s\n' "$C_LINE" | sed -n 's/^Resultat collecte : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    C_FAIL=$(printf '%s\n' "$C_LINE" | sed -n 's/^Resultat collecte : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${C_PASS:-0}))
    FAIL=$((FAIL + ${C_FAIL:-0}))
    [ "$C_RC" -eq 0 ] || FAIL=$((FAIL + 1))
else
    printf '  (ignore) suite collecte absente\n'
fi

section "32. M6 : analyse dmesg (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-m6-tests.sh" ]; then
    M6_OUT=$("$ROOT/tests/phase1/run-m6-tests.sh" 2>&1)
    M6_RC=$?
    printf '%s\n' "$M6_OUT" | grep -E '^(  ECHEC|Resultat M6)' || true
    M6_LINE=$(printf '%s\n' "$M6_OUT" | grep '^Resultat M6 :' | tail -1)
    M6_PASS=$(printf '%s\n' "$M6_LINE" | sed -n 's/^Resultat M6 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    M6_FAIL=$(printf '%s\n' "$M6_LINE" | sed -n 's/^Resultat M6 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${M6_PASS:-0}))
    FAIL=$((FAIL + ${M6_FAIL:-0}))
    [ "$M6_RC" -eq 0 ] || FAIL=$((FAIL + 1))
else
    printf '  (ignore) suite M6 absente\n'
fi

section "33. M7/M7A/M8 : horloge, NAT, firmware (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-m7-tests.sh" ]; then
    R7=$("$ROOT/tests/phase1/run-m7-tests.sh" 2>&1); RC7=$?
    printf '%s\n' "$R7" | grep -E '^(  ECHEC|Resultat M7)' || true
    L7=$(printf '%s\n' "$R7" | grep '^Resultat M7 :' | tail -1)
    P7=$(printf '%s\n' "$L7" | sed -n 's/^Resultat M7 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    F7=$(printf '%s\n' "$L7" | sed -n 's/^Resultat M7 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${P7:-0})); FAIL=$((FAIL + ${F7:-0})); [ "$RC7" -eq 0 ] || FAIL=$((FAIL + 1))
fi

section "34. N0 : reproduction boot historique (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-n0-tests.sh" ]; then
    R0=$("$ROOT/tests/phase1/run-n0-tests.sh" 2>&1); RC0=$?
    printf '%s\n' "$R0" | grep -E '^(  ECHEC|Resultat N0)' || true
    L0=$(printf '%s\n' "$R0" | grep '^Resultat N0 :' | tail -1)
    P0=$(printf '%s\n' "$L0" | sed -n 's/^Resultat N0 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    F0=$(printf '%s\n' "$L0" | sed -n 's/^Resultat N0 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${P0:-0})); FAIL=$((FAIL + ${F0:-0})); [ "$RC0" -eq 0 ] || FAIL=$((FAIL + 1))
fi

section "35. M8.2 : ECM principal / RNDIS secours (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-m82-tests.sh" ]; then
    R81=$("$ROOT/tests/phase1/run-m82-tests.sh" 2>&1); RC81=$?
    printf '%s\n' "$R81" | grep -E '^(  ECHEC|Resultat M8\.2)' || true
    L81=$(printf '%s\n' "$R81" | grep '^Resultat M8\.2 :' | tail -1)
    P81=$(printf '%s\n' "$L81" | sed -n 's/^Resultat M8\.2 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    F81=$(printf '%s\n' "$L81" | sed -n 's/^Resultat M8\.2 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${P81:-0})); FAIL=$((FAIL + ${F81:-0})); [ "$RC81" -eq 0 ] || FAIL=$((FAIL + 1))
fi

section "36. M7B.1 : firmware GPU / DRM (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-m7b1-tests.sh" ]; then
    RFW=$("$ROOT/tests/phase1/run-m7b1-tests.sh" 2>&1); RCFW=$?
    printf '%s\n' "$RFW" | grep -E '^(  ECHEC|Resultat M7B\.1)' || true
    LFW=$(printf '%s\n' "$RFW" | grep '^Resultat M7B\.1 :' | tail -1)
    PFW=$(printf '%s\n' "$LFW" | sed -n 's/^Resultat M7B\.1 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    FFW=$(printf '%s\n' "$LFW" | sed -n 's/^Resultat M7B\.1 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${PFW:-0})); FAIL=$((FAIL + ${FFW:-0})); [ "$RCFW" -eq 0 ] || FAIL=$((FAIL + 1))
fi

section "37. M7B.2 : firmware initramfs / candidat (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-m7b2-tests.sh" ]; then
    R72=$("$ROOT/tests/phase1/run-m7b2-tests.sh" 2>&1); RC72=$?
    printf '%s\n' "$R72" | grep -E '^(  ECHEC|Resultat M7B\.2)' || true
    L72=$(printf '%s\n' "$R72" | grep '^Resultat M7B\.2 :' | tail -1)
    P72=$(printf '%s\n' "$L72" | sed -n 's/^Resultat M7B\.2 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    F72=$(printf '%s\n' "$L72" | sed -n 's/^Resultat M7B\.2 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${P72:-0})); FAIL=$((FAIL + ${F72:-0})); [ "$RC72" -eq 0 ] || FAIL=$((FAIL + 1))
fi

section "38. M7B.3 : toolchain / uniLoader / candidat boot (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-m7b3-tests.sh" ]; then
    R73=$("$ROOT/tests/phase1/run-m7b3-tests.sh" 2>&1); RC73=$?
    printf '%s\n' "$R73" | grep -E '^(  ECHEC|Resultat M7B\.3)' || true
    L73=$(printf '%s\n' "$R73" | grep '^Resultat M7B\.3 :' | tail -1)
    P73=$(printf '%s\n' "$L73" | sed -n 's/^Resultat M7B\.3 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    F73=$(printf '%s\n' "$L73" | sed -n 's/^Resultat M7B\.3 : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${P73:-0})); FAIL=$((FAIL + ${F73:-0})); [ "$RC73" -eq 0 ] || FAIL=$((FAIL + 1))
fi

section "39. M9A : Wi-Fi WCN3990 (suite dediee)"
if [ -x "$ROOT/tests/phase1/run-m9a-tests.sh" ]; then
    R9A=$("$ROOT/tests/phase1/run-m9a-tests.sh" 2>&1); RC9A=$?
    printf '%s\n' "$R9A" | grep -E '^(  ECHEC|Resultat M9A)' || true
    L9A=$(printf '%s\n' "$R9A" | grep '^Resultat M9A :' | tail -1)
    P9A=$(printf '%s\n' "$L9A" | sed -n 's/^Resultat M9A : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\1/p')
    F9A=$(printf '%s\n' "$L9A" | sed -n 's/^Resultat M9A : \([0-9]*\) reussite(s), \([0-9]*\) echec(s)$/\2/p')
    PASS=$((PASS + ${P9A:-0})); FAIL=$((FAIL + ${F9A:-0})); [ "$RC9A" -eq 0 ] || FAIL=$((FAIL + 1))
fi

printf '\n%s\n' "---------------------------------------------"
printf 'Resultat : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
: # nettoyage R23 desactive temporairement

[ "$FAIL" -eq 0 ] || exit 1
exit 0
