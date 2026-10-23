#!/usr/bin/env bash
# shellcheck shell=bash
#
# prepare-toolchain.sh - acquisition, validation, extraction sure et inspection
#                        de la toolchain Bootlin epinglee.
#
# Aucune compilation de noyau, aucun chroot, aucun montage, aucun flash.
# Aucun `curl | shell` : l'archive n'est JAMAIS executee avant validation.
#
# Usage :
#   ./scripts/prepare-toolchain.sh --manifest FILE --cache-dir DIR --work-dir DIR
#                                  [--offline] [--force] [--help]
#
# Etapes :
#   1. lecture des valeurs epinglees dans le manifeste (refus des TODO_*) ;
#   2. acquisition dans un cache adresse par contenu (SHA-256) ;
#   3. verification taille + SHA-256 local + comparaison au .sha256 publie ;
#   4. inspection de la liste de l'archive (chemins, liens, fichiers speciaux) ;
#   5. extraction dans un repertoire temporaire prive puis renommage atomique ;
#   6. decouverte du compilateur (aucune hypothese sur le prefixe) ;
#   7. test minimal produisant un ELF AArch64 (verification par readelf) ;
#   8. rapports + environment.sh.
#
# Codes de sortie :
#   0 succes
#   1 echec inattendu
#   2 erreur d'usage
#   3 manifeste invalide / valeur non resolue
#   4 acquisition ou verification de l'archive echouee
#   5 archive refusee (contenu dangereux)
#   6 extraction echouee
#   7 toolchain inutilisable (compilateur absent, ambigu, mauvaise cible)
#   8 test ELF echoue

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PROG=$(basename "$0")

EXIT_OK=0
EXIT_FAIL=1
EXIT_USAGE=2
EXIT_MANIFEST=3
EXIT_ARCHIVE=4
EXIT_UNSAFE=5
EXIT_EXTRACT=6
EXIT_TOOLCHAIN=7
EXIT_ELF=8

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die_code() { local c=$1; shift; say "$*"; exit "$c"; }
usage_error() { say "$1"; printf 'Utilise --help.\n' >&2; exit "$EXIT_USAGE"; }

usage() {
    cat <<EOF
$PROG - acquisition et validation de la toolchain Bootlin

Usage
  $PROG --manifest FILE --cache-dir DIR --work-dir DIR [--offline] [--force]

Options
  --manifest FILE  manifeste du projet (valeurs epinglees)
  --cache-dir DIR  cache adresse par contenu
  --work-dir DIR   repertoire de travail (toolchain + rapports)
  --offline        aucun acces reseau ; exige une archive deja en cache
  --force          re-telecharge / re-extrait meme si deja present
  -h, --help       affiche cette aide

Sorties (dans --work-dir/toolchain)
  archive-list.txt       liste brute de l'archive
  toolchain-report.txt   rapport detaille
  provenance.json        provenance machine-lisible
  compiler-version.txt   versions du compilateur
  test-elf.txt           preuve du test ELF AArch64
  environment.sh         exports verifies (CROSS_COMPILE, TOOLCHAIN_ROOT)

Codes de sortie
  0 succes        1 echec        2 usage      3 manifeste
  4 archive       5 archive dangereuse         6 extraction
  7 toolchain     8 test ELF
EOF
}

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
MANIFEST_FILE=""
CACHE_DIR=""
WORK_DIR=""
OFFLINE=0
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
        --manifest) mark_opt manifest; [ $# -ge 2 ] || usage_error "--manifest attend un fichier"; MANIFEST_FILE=$2; shift ;;
        --cache-dir) mark_opt cache-dir; [ $# -ge 2 ] || usage_error "--cache-dir attend un repertoire"; CACHE_DIR=$2; shift ;;
        --work-dir) mark_opt work-dir; [ $# -ge 2 ] || usage_error "--work-dir attend un repertoire"; WORK_DIR=$2; shift ;;
        --offline) mark_opt offline; OFFLINE=1 ;;
        --force) mark_opt force; FORCE=1 ;;
        --manifest=*) mark_opt manifest; MANIFEST_FILE=${1#--manifest=} ;;
        --cache-dir=*) mark_opt cache-dir; CACHE_DIR=${1#--cache-dir=} ;;
        --work-dir=*) mark_opt work-dir; WORK_DIR=${1#--work-dir=} ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

[ -n "$MANIFEST_FILE" ] || usage_error "--manifest est obligatoire"
[ -n "$CACHE_DIR" ] || usage_error "--cache-dir est obligatoire"
[ -n "$WORK_DIR" ] || usage_error "--work-dir est obligatoire"

# --------------------------------------------------------------------------
# Manifeste
# --------------------------------------------------------------------------
[ -f "$MANIFEST_FILE" ] || die_code "$EXIT_MANIFEST" "manifeste absent : $(basename "$MANIFEST_FILE")"
[ -r "$MANIFEST_FILE" ] || die_code "$EXIT_MANIFEST" "manifeste illisible : $(basename "$MANIFEST_FILE")"

mval() {
    # mval <cle> -> valeur ; refuse TODO_*, vide ou absence
    local key=$1 val rc=0
    val=$(A71_MANIFEST="$MANIFEST_FILE" bash -c '
        . "$1/scripts/common.sh" 2>/dev/null
        manifest_get "$A71_MANIFEST" "$2"
    ' _ "$REPO_ROOT" "$key") || rc=$?
    if [ "$rc" -ne 0 ]; then
        die_code "$EXIT_MANIFEST" "manifeste : cle absente ou invalide ($key)"
    fi
    case "$val" in
        '' | TODO_*) die_code "$EXIT_MANIFEST" "manifeste : $key non resolu ($val)" ;;
    esac
    printf '%s\n' "$val"
}

ARCHIVE_NAME=$(mval toolchain.archive)
ARCHIVE_URL=$(mval toolchain.archive_url)
CHECKSUM_URL=$(mval toolchain.checksum_url)
EXPECTED_SHA=$(mval toolchain.sha256)
EXPECTED_SIZE=$(mval toolchain.size)
TOOLCHAIN_VERSION=$(mval toolchain.version)

case "$EXPECTED_SHA" in
    *[!0-9a-f]* | '') die_code "$EXIT_MANIFEST" "toolchain.sha256 n'est pas un SHA-256 hexadecimal" ;;
esac
[ "${#EXPECTED_SHA}" -eq 64 ] || die_code "$EXIT_MANIFEST" "toolchain.sha256 doit faire 64 caracteres"
case "$EXPECTED_SIZE" in
    '' | *[!0-9]*) die_code "$EXIT_MANIFEST" "toolchain.size doit etre un entier" ;;
esac
case "$ARCHIVE_NAME" in
    */* | '') die_code "$EXIT_MANIFEST" "toolchain.archive doit etre un nom de fichier simple" ;;
esac

# --------------------------------------------------------------------------
# Repertoires
# --------------------------------------------------------------------------
mkdir -p "$CACHE_DIR" "$WORK_DIR" || die_code "$EXIT_FAIL" "creation des repertoires impossible"
chmod 700 "$CACHE_DIR" "$WORK_DIR" 2>/dev/null || true
CACHE_DIR=$(cd "$CACHE_DIR" && pwd -P)
WORK_DIR=$(cd "$WORK_DIR" && pwd -P)

CACHE_FILE="$CACHE_DIR/downloads/sha256/$EXPECTED_SHA"
OUT_DIR="$WORK_DIR/toolchain"
ARCHIVE_LIST="$OUT_DIR/archive-list.txt"
REPORT="$OUT_DIR/toolchain-report.txt"
PROVENANCE="$OUT_DIR/provenance.json"
COMPILER_VERSION="$OUT_DIR/compiler-version.txt"
TEST_ELF_TXT="$OUT_DIR/test-elf.txt"
ENV_FILE="$OUT_DIR/environment.sh"

mkdir -p "$(dirname "$CACHE_FILE")" "$OUT_DIR"
chmod 700 "$(dirname "$CACHE_FILE")" "$OUT_DIR" 2>/dev/null || true

# --------------------------------------------------------------------------
# 1. Checksum publie par Bootlin
# --------------------------------------------------------------------------
PUBLISHED_SHA=""
PUBLISHED_STATUS="non_consulte"
if [ "$OFFLINE" = "1" ]; then
    PUBLISHED_STATUS="non_consulte_offline"
else
    sha_tmp=$(umask 077 && mktemp "$OUT_DIR/.sha256-XXXXXXXX") ||
        die_code "$EXIT_ARCHIVE" "temporaire impossible dans $OUT_DIR"
    if curl --fail --show-error --silent --location --max-time 120 \
        "$CHECKSUM_URL" -o "$sha_tmp" 2>/dev/null; then
        # Le fichier .sha256 est analyse comme TEXTE : premier jeton 64 hex.
        PUBLISHED_SHA=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-f]{64}$/) { print $i; exit } }' "$sha_tmp")
        if [ "$PUBLISHED_SHA" = "$EXPECTED_SHA" ]; then
            PUBLISHED_STATUS="coherent"
        elif [ -n "$PUBLISHED_SHA" ]; then
            PUBLISHED_STATUS="incoherent"
        else
            PUBLISHED_STATUS="illisible"
        fi
    else
        PUBLISHED_STATUS="indisponible"
    fi
    rm -f "$sha_tmp"
fi

if [ "$PUBLISHED_STATUS" = "incoherent" ]; then
    die_code "$EXIT_ARCHIVE" "checksum Bootlin ($PUBLISHED_SHA) different du manifeste ($EXPECTED_SHA)"
fi

# --------------------------------------------------------------------------
# 2. Cache adresse par contenu
# --------------------------------------------------------------------------
verify_file() {
    # verify_file <fichier> <sha> <taille> -> 0 si conforme
    local f=$1 sha=$2 size=$3 actual_size actual_sha
    [ -f "$f" ] || return 1
    actual_size=$(wc -c <"$f" | tr -d ' ')
    [ "$actual_size" = "$size" ] || return 1
    actual_sha=$(sha256sum "$f" | cut -d' ' -f1)
    [ "$actual_sha" = "$sha" ] || return 1
    return 0
}

CACHE_STATE="absent"
if [ -f "$CACHE_FILE" ]; then
    if verify_file "$CACHE_FILE" "$EXPECTED_SHA" "$EXPECTED_SIZE"; then
        CACHE_STATE="valide"
    else
        CACHE_STATE="corrompu"
    fi
fi

if [ "$CACHE_STATE" = "corrompu" ]; then
    if [ "$OFFLINE" = "1" ]; then
        die_code "$EXIT_ARCHIVE" "cache corrompu et mode offline : suppression manuelle requise"
    fi
    if [ "$FORCE" = "1" ]; then
        rm -f "$CACHE_FILE"
        CACHE_STATE="absent"
    else
        die_code "$EXIT_ARCHIVE" "cache corrompu (taille ou SHA-256) : relancer avec --force pour re-telecharger"
    fi
fi

if [ "$CACHE_STATE" = "absent" ]; then
    if [ "$OFFLINE" = "1" ]; then
        die_code "$EXIT_ARCHIVE" "mode offline : archive absente du cache ($EXPECTED_SHA)"
    fi
    dl_tmp=$(umask 077 && mktemp "$CACHE_DIR/.download-XXXXXXXX") ||
        die_code "$EXIT_ARCHIVE" "temporaire de telechargement impossible"
    say "telechargement de $ARCHIVE_NAME"
    if ! curl --fail --show-error --silent --location --max-time 900 \
        --retry 2 --retry-delay 2 "$ARCHIVE_URL" -o "$dl_tmp"; then
        rm -f "$dl_tmp"
        die_code "$EXIT_ARCHIVE" "telechargement echoue"
    fi
    dl_size=$(wc -c <"$dl_tmp" | tr -d ' ')
    if [ "$dl_size" != "$EXPECTED_SIZE" ]; then
        rm -f "$dl_tmp"
        die_code "$EXIT_ARCHIVE" "taille telechargee $dl_size != attendue $EXPECTED_SIZE"
    fi
    dl_sha=$(sha256sum "$dl_tmp" | cut -d' ' -f1)
    if [ "$dl_sha" != "$EXPECTED_SHA" ]; then
        rm -f "$dl_tmp"
        die_code "$EXIT_ARCHIVE" "SHA-256 telecharge $dl_sha != attendu $EXPECTED_SHA"
    fi
    mv -f "$dl_tmp" "$CACHE_FILE" || die_code "$EXIT_ARCHIVE" "renommage atomique impossible"
    CACHE_STATE="telecharge"
fi

LOCAL_SHA=$(sha256sum "$CACHE_FILE" | cut -d' ' -f1)
LOCAL_SIZE=$(wc -c <"$CACHE_FILE" | tr -d ' ')

# --------------------------------------------------------------------------
# 3. Inspection de l'archive (avant toute extraction)
# --------------------------------------------------------------------------
# Verification precise par python3 (types, liens, chemins) : aucune execution.
python3 - "$CACHE_FILE" "$ARCHIVE_LIST" <<'PY' || die_code "$EXIT_UNSAFE" "archive refusee (voir le detail ci-dessus)"
import sys, tarfile

path, listing = sys.argv[1], sys.argv[2]
problems = []
lines = []

def bad(msg):
    problems.append(msg)

with tarfile.open(path, "r:*") as tf:
    for m in tf.getmembers():
        lines.append(
            "%s %s %s" % (
                {"dir": "d", "file": "-", "sym": "l", "lnk": "h", "chr": "c",
                 "blk": "b", "fifo": "p", "cont": "-"}.get(
                    ("sym" if m.issym() else "lnk" if m.islnk() else
                     "dir" if m.isdir() else "chr" if m.ischr() else
                     "blk" if m.isblk() else "fifo" if m.isfifo() else "file"),
                    "?"),
                m.size, m.name,
            )
        )
        name = m.name
        if name.startswith("/"):
            bad("chemin absolu : %s" % name)
        parts = name.split("/")
        if ".." in parts:
            bad("composant '..' : %s" % name)
        if not (m.isfile() or m.isdir() or m.issym() or m.islnk()):
            bad("entree speciale : %s" % name)
        if m.issym() or m.islnk():
            target = m.linkname
            if target.startswith("/"):
                bad("lien absolu : %s -> %s" % (name, target))
            # cible remontant hors de l'archive
            depth = len([p for p in name.split("/")[:-1] if p])
            for comp in target.split("/"):
                if comp == "..":
                    depth -= 1
                elif comp not in ("", "."):
                    depth += 1
            if depth < 0:
                bad("lien sortant : %s -> %s" % (name, target))

with open(listing, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + ("\n" if lines else ""))

if problems:
    for p in problems[:20]:
        print("archive: " + p, file=sys.stderr)
    if len(problems) > 20:
        print("archive: ... %d problemes au total" % len(problems), file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY

# --------------------------------------------------------------------------
# 4. Extraction sure puis renommage atomique
# --------------------------------------------------------------------------
TOOLCHAIN_ROOT=""
if [ -d "$OUT_DIR/toolchain-root" ] && [ "$FORCE" != "1" ]; then
    TOOLCHAIN_ROOT="$OUT_DIR/toolchain-root"
    EXTRACT_STATE="reutilise"
else
    tmp_extract=$(umask 077 && mktemp -d "$WORK_DIR/.a71-extract-XXXXXXXX") ||
        die_code "$EXIT_EXTRACT" "repertoire temporaire impossible"
    if ! tar -xf "$CACHE_FILE" -C "$tmp_extract" --no-same-owner --no-same-permissions 2>"$OUT_DIR/.extract.err"; then
        rm -rf "$tmp_extract"
        die_code "$EXIT_EXTRACT" "extraction echouee (voir .extract.err)"
    fi
    entries=()
    while IFS= read -r e; do entries+=("$e"); done < <(cd "$tmp_extract" && ls -A)
    if [ "${#entries[@]}" -ne 1 ]; then
        rm -rf "$tmp_extract"
        die_code "$EXIT_EXTRACT" "l'archive doit contenir exactement un repertoire racine (${#entries[@]} entree(s))"
    fi
    root_entry=${entries[0]}
    if [ ! -d "$tmp_extract/$root_entry" ]; then
        rm -rf "$tmp_extract"
        die_code "$EXIT_EXTRACT" "l'entree racine de l'archive n'est pas un repertoire"
    fi
    rm -rf "$OUT_DIR/toolchain-root"
    mv "$tmp_extract/$root_entry" "$OUT_DIR/toolchain-root" ||
        { rm -rf "$tmp_extract"; die_code "$EXIT_EXTRACT" "renommage atomique impossible"; }
    rmdir "$tmp_extract" 2>/dev/null || rm -rf "$tmp_extract"
    TOOLCHAIN_ROOT="$OUT_DIR/toolchain-root"
    EXTRACT_STATE="extrait"
fi

# --------------------------------------------------------------------------
# 5. Decouverte du compilateur (aucune hypothese de prefixe)
# --------------------------------------------------------------------------
[ -d "$TOOLCHAIN_ROOT/bin" ] || die_code "$EXIT_TOOLCHAIN" "pas de repertoire bin/ dans la toolchain"

# Les toolchains buildroot exposent gcc comme un LIEN SYMBOLIQUE vers
# toolchain-wrapper : on accepte fichiers et liens, mais la cible doit rester
# dans la racine de la toolchain une fois resolue.
candidates=()
while IFS= read -r c; do
    [ -x "$c" ] || continue
    resolved=$(readlink -f "$c" 2>/dev/null || true)
    case "$resolved" in
        "$TOOLCHAIN_ROOT"/*) ;;
        *) say "candidat ignore (cible hors toolchain) : $(basename "$c")"; continue ;;
    esac
    candidates+=("$c")
done < <(find "$TOOLCHAIN_ROOT/bin" -maxdepth 1 \( -type f -o -type l \) -name '*-gcc' | sort)
if [ "${#candidates[@]}" -eq 0 ]; then
    die_code "$EXIT_TOOLCHAIN" "aucun compilateur '*-gcc' trouve dans bin/"
fi
# Les toolchains buildroot fournissent plusieurs ALIAS du meme compilateur
# (triplet complet + alias court). Regle deterministe : on retient le prefixe
# le plus long (le plus specifique) ; une egalite de longueur entre prefixes
# differents est une vraie ambiguite et fait echouer.
CC_ABS=""
BEST_LEN=-1
ALIASES=""
for c in "${candidates[@]}"; do
    base=$(basename "$c")
    prefix=${base%gcc}
    plen=${#prefix}
    if [ "$plen" -gt "$BEST_LEN" ]; then
        if [ -n "$CC_ABS" ]; then ALIASES="$ALIASES $(basename "$CC_ABS")"; fi
        BEST_LEN=$plen
        CC_ABS=$c
    elif [ "$plen" -eq "$BEST_LEN" ] && [ "$(basename "$c")" != "$(basename "$CC_ABS")" ]; then
        say "ambiguite : deux prefixes de meme longueur (${BEST_LEN})"
        say "  - $(basename "$CC_ABS")"
        say "  - $(basename "$c")"
        die_code "$EXIT_TOOLCHAIN" "plusieurs compilateurs de meme specificite : choix impossible"
    else
        ALIASES="$ALIASES $(basename "$c")"
    fi
done
CC_BASENAME=$(basename "$CC_ABS")
CROSS_COMPILE_ABS="${CC_ABS%gcc}"

TARGET=$("$CC_ABS" -dumpmachine 2>/dev/null || true)
case "$TARGET" in
    aarch64*) ;;
    *) die_code "$EXIT_TOOLCHAIN" "cible inattendue : '${TARGET:-inconnue}' (aarch64 attendu)" ;;
esac

CC_VERSION_LINE=$("$CC_ABS" --version 2>/dev/null | head -1 || true)
SYSROOT=$("$CC_ABS" -print-sysroot 2>/dev/null || true)
HOST_KIND=$(file -Lb "$CC_ABS" 2>/dev/null || echo inconnu)

# --------------------------------------------------------------------------
# 6. Test minimal : ELF AArch64 produit, sans compiler le noyau
# --------------------------------------------------------------------------
TEST_SRC="$OUT_DIR/.hello.c"
TEST_BIN="$OUT_DIR/hello-aarch64"
cat >"$TEST_SRC" <<'EOF'
int main(void) { return 0; }
EOF
if ! "$CC_ABS" -O2 -o "$TEST_BIN" "$TEST_SRC" 2>"$OUT_DIR/.compile.err"; then
    rm -f "$TEST_SRC"
    die_code "$EXIT_ELF" "compilation du programme de test echouee (voir .compile.err)"
fi
rm -f "$TEST_SRC"

readelf_out=$(LC_ALL=C readelf -h "$TEST_BIN" 2>/dev/null || true)
if ! printf '%s\n' "$readelf_out" | grep -qE 'Machine:[[:space:]]+AArch64'; then
    die_code "$EXIT_ELF" "le binaire produit n'est pas un ELF AArch64"
fi
file_out=$(LC_ALL=C file -b "$TEST_BIN" 2>/dev/null || echo inconnu)

{
    printf 'programme de test : int main(void){return 0;}\n'
    printf 'compilateur       : %s\n' "$CROSS_COMPILE_ABS"
    printf 'resultat          : ELF AArch64 confirme\n\n'
    printf '%s\n' "--- file ---"
    printf '%s\n' "$file_out"
    printf '%s\n' "--- readelf -h ---"
    printf '%s\n' "$readelf_out"
} >"$TEST_ELF_TXT"

{
    printf '# versions du compilateur\n'
    printf 'compilateur : %s\n' "$CC_BASENAME"
    printf 'binaire     : %s\n' "$HOST_KIND"
    printf '\n--- --version ---\n'
    "$CC_ABS" --version 2>/dev/null || true
    printf '\n--- -dumpmachine ---\n%s\n' "$TARGET"
    printf '\n--- -print-sysroot ---\n%s\n' "$SYSROOT"
} >"$COMPILER_VERSION"

# --------------------------------------------------------------------------
# 7. environment.sh (aucun secret, chemins verifies)
# --------------------------------------------------------------------------
{
    printf '# environment.sh - genere par %s\n' "$PROG"
    printf '# chemins verifies ; aucun identifiant ni jeton n y figure\n'
    printf 'export TOOLCHAIN_ROOT=%q\n' "$TOOLCHAIN_ROOT"
    printf 'export CROSS_COMPILE=%q\n' "$CROSS_COMPILE_ABS"
    printf 'export TOOLCHAIN_TARGET=%q\n' "$TARGET"
} >"$ENV_FILE"
chmod 600 "$ENV_FILE"

# --------------------------------------------------------------------------
# 8. Rapports
# --------------------------------------------------------------------------
{
    printf '# toolchain Bootlin - rapport de preparation\n\n'
    printf 'version declaree        : %s\n' "$TOOLCHAIN_VERSION"
    printf 'archive                 : %s\n' "$ARCHIVE_NAME"
    printf 'sha256 manifeste        : %s\n' "$EXPECTED_SHA"
    printf 'sha256 publie (Bootlin) : %s [%s]\n' "${PUBLISHED_SHA:-<aucun>}" "$PUBLISHED_STATUS"
    printf 'sha256 calcule local    : %s\n' "$LOCAL_SHA"
    printf 'taille attendue         : %s\n' "$EXPECTED_SIZE"
    printf 'taille locale           : %s\n' "$LOCAL_SIZE"
    printf 'signature               : indisponible (aucun .asc publie)\n'
    printf 'etat du cache           : %s\n' "$CACHE_STATE"
    printf 'archive validee         : oui (taille + SHA-256)\n'
    printf 'extraction              : %s\n' "$EXTRACT_STATE"
    printf 'racine toolchain        : %s\n' "$TOOLCHAIN_ROOT"
    printf 'compilateur             : %s\n' "$CC_BASENAME"
    printf 'alias ignores           :%s\n' "${ALIASES:- aucun}"
    printf 'CROSS_COMPILE           : %s\n' "$CROSS_COMPILE_ABS"
    printf 'cible (-dumpmachine)    : %s\n' "$TARGET"
    printf 'sysroot                 : %s\n' "${SYSROOT:-<vide>}"
    printf 'hote du binaire         : %s\n' "$HOST_KIND"
    printf 'test ELF AArch64        : reussi\n'
    printf 'compilation du noyau    : AUCUNE\n'
} >"$REPORT"

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
{
    printf '{\n'
    printf '  "name": "toolchain-bootlin",\n'
    printf '  "version": "%s",\n' "$(esc "$TOOLCHAIN_VERSION")"
    printf '  "archive": "%s",\n' "$(esc "$ARCHIVE_NAME")"
    printf '  "archive_url": "%s",\n' "$(esc "$ARCHIVE_URL")"
    printf '  "checksum_url": "%s",\n' "$(esc "$CHECKSUM_URL")"
    printf '  "sha256_manifest": "%s",\n' "$EXPECTED_SHA"
    printf '  "sha256_published": "%s",\n' "${PUBLISHED_SHA:-}"
    printf '  "sha256_published_status": "%s",\n' "$PUBLISHED_STATUS"
    printf '  "sha256_local": "%s",\n' "$LOCAL_SHA"
    printf '  "size_expected": %s,\n' "$EXPECTED_SIZE"
    printf '  "size_local": %s,\n' "$LOCAL_SIZE"
    printf '  "signature_status": "unavailable",\n'
    printf '  "archive_validated": true,\n'
    printf '  "extraction_validated": true,\n'
    printf '  "cache_state": "%s",\n' "$CACHE_STATE"
    printf '  "compiler": "%s",\n' "$(esc "$CC_BASENAME")"
    printf '  "cross_compile": "%s",\n' "$(esc "$CROSS_COMPILE_ABS")"
    printf '  "target": "%s",\n' "$(esc "$TARGET")"
    printf '  "sysroot": "%s",\n' "$(esc "$SYSROOT")"
    printf '  "host_binary": "%s",\n' "$(esc "$HOST_KIND")"
    printf '  "compiler_version": "%s",\n' "$(esc "$CC_VERSION_LINE")"
    printf '  "elf_test": "aarch64_ok",\n'
    printf '  "kernel_build": "none",\n'
    printf '  "retrieved_at": "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '}\n'
} >"$PROVENANCE"

# nettoyage des traces d'erreur vides (succes)
for f in "$OUT_DIR/.compile.err" "$OUT_DIR/.extract.err"; do
    [ -f "$f" ] && [ ! -s "$f" ] && rm -f "$f"
done

printf 'toolchain prete : %s\n' "$CROSS_COMPILE_ABS"
printf 'environment     : %s\n' "$ENV_FILE"
exit "$EXIT_OK"
