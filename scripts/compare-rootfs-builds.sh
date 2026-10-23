#!/usr/bin/env bash
# shellcheck shell=bash
#
# compare-rootfs-builds.sh - compare deux rootfs fonctionnels independants (D1).
#
# Lecture seule. Compare : chemins, contenu, liens, modes, UID/GID logiques,
# base APK, paquets, modules et fichiers de configuration. Le rapport est
# deterministe et ne contient aucun chemin absolu.
#
# Codes : 0 identiques, 1 difference, 2 usage, 3 entree invalide.

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PROG=$(basename "$0")

EXIT_OK=0
EXIT_DIFF=1
EXIT_USAGE=2
EXIT_INPUT=3

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() { say "$1"; printf 'Utilise --help.\n' >&2; exit "$EXIT_USAGE"; }
die_input() { say "$1"; exit "$EXIT_INPUT"; }

usage() {
    cat <<EOF
$PROG - compare deux rootfs fonctionnels (lecture seule)

Usage
  $PROG --a DIR --b DIR --report FILE

Options
  --a DIR        premier rootfs
  --b DIR        second rootfs
  --report FILE  rapport deterministe a ecrire
  -h, --help     cette aide
EOF
}

A=""
B=""
REPORT=""
SEEN=" "
mark_opt() { case "$SEEN" in *" $1 "*) usage_error "option repetee : --$1" ;; esac; SEEN="$SEEN$1 "; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit "$EXIT_OK" ;;
        --a) mark_opt a; [ $# -ge 2 ] || usage_error "--a attend un repertoire"; A=$2; shift ;;
        --b) mark_opt b; [ $# -ge 2 ] || usage_error "--b attend un repertoire"; B=$2; shift ;;
        --report) mark_opt report; [ $# -ge 2 ] || usage_error "--report attend un fichier"; REPORT=$2; shift ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

[ -n "$A" ] || usage_error "--a est obligatoire"
[ -n "$B" ] || usage_error "--b est obligatoire"
[ -n "$REPORT" ] || usage_error "--report est obligatoire"
[ -d "$A" ] || die_input "rootfs A absent"
[ -d "$B" ] || die_input "rootfs B absent"
[ ! -L "$A" ] || die_input "rootfs A est un lien symbolique"
[ ! -L "$B" ] || die_input "rootfs B est un lien symbolique"
[ ! -L "$REPORT" ] || die_input "rapport est un lien symbolique"
A=$(cd "$A" && pwd -P) || die_input "rootfs A inaccessible"
B=$(cd "$B" && pwd -P) || die_input "rootfs B inaccessible"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/a71-cmp-rootfs-XXXXXXXX") || die_input "temporaire impossible"
trap 'rm -rf "$TMP"' EXIT

python3 "$REPO_ROOT/scripts/rootfs-modes.py" fingerprint --root "$A" --output "$TMP/a.fp" --exclude-reports ||
    die_input "empreinte A impossible"
python3 "$REPO_ROOT/scripts/rootfs-modes.py" fingerprint --root "$B" --output "$TMP/b.fp" --exclude-reports ||
    die_input "empreinte B impossible"

same() { cmp -s "$1" "$2"; }
result=yes

check_file() {
    local label=$1 fa=$2 fb=$3
    if same "$fa" "$fb"; then
        printf '%s=match\n' "$label"
    else
        printf '%s=DIFF\n' "$label"
        result=no
    fi
}

check_tree() {
    local label=$1 rel=$2
    ( cd "$A" && find "$rel" -type f -printf '%P\n' | sort | while IFS= read -r p; do
        [ -n "$p" ] || continue
        printf '%s  %s\n' "$(sha256sum "$A/$rel/$p" | awk '{print $1}')" "$p"
    done ) >"$TMP/a.$label"
    ( cd "$B" && find "$rel" -type f -printf '%P\n' | sort | while IFS= read -r p; do
        [ -n "$p" ] || continue
        printf '%s  %s\n' "$(sha256sum "$B/$rel/$p" | awk '{print $1}')" "$p"
    done ) >"$TMP/b.$label"
    check_file "$label" "$TMP/a.$label" "$TMP/b.$label"
}

{
    printf 'rootfs_a=%s\n' "$(basename "$A")"
    printf 'rootfs_b=%s\n' "$(basename "$B")"
    check_file tree_content_modes_links "$TMP/a.fp" "$TMP/b.fp"
    check_file ownership_manifest "$A/reports/ownership-manifest.txt" "$B/reports/ownership-manifest.txt"
    check_file packages "$A/reports/packages.txt" "$B/reports/packages.txt"
    check_file symlinks "$A/reports/symlinks.txt" "$B/reports/symlinks.txt"
    check_file init_link "$A/reports/init-link.txt" "$B/reports/init-link.txt"
    check_file mode_policy_application "$A/reports/mode-policy.txt" "$B/reports/mode-policy.txt"
    check_file mode_application "$A/reports/mode-application.txt" "$B/reports/mode-application.txt"
    check_file mode_changes "$A/reports/mode-changes.txt" "$B/reports/mode-changes.txt"
    check_file tree_manifest "$A/reports/tree-manifest.sha256" "$B/reports/tree-manifest.sha256"
    check_file apk_installed_db "$A/lib/apk/db/installed" "$B/lib/apk/db/installed"
    check_file apk_world "$A/etc/apk/world" "$B/etc/apk/world"
    check_tree modules lib/modules
    check_tree etc_config etc
    check_tree init_scripts etc/init.d
    printf 'overall_reproducible=%s\n' "$result"
} >"$TMP/report"

if [ -e "$REPORT" ] && [ -d "$REPORT" ]; then
    say "rapport est un repertoire"
    exit "$EXIT_INPUT"
fi
mv "$TMP/report" "$REPORT" || { say "ecriture du rapport impossible"; exit "$EXIT_INPUT"; }

if [ "$result" = "yes" ]; then
    say "rootfs reproductibles"
    exit "$EXIT_OK"
fi
say "difference(s) detectee(s), voir $REPORT"
exit "$EXIT_DIFF"
