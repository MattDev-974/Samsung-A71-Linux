#!/usr/bin/env bash
# provision-ssh-key.sh - installe une cle PUBLIQUE dans un rootfs A71 monte.
#
# Aucun sudo, aucun peripherique devine, aucun secret affiche.
# Le rootfs doit etre monte par l'utilisateur et deja valide E1.

set -Eeuo pipefail

PROG=$(basename "$0")
ROOTFS=""
KEYFILE=""
ALLOW_ROOT=${A71_PROVISION_ALLOW_ROOT:-0}

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die() { say "$1"; exit "${2:-1}"; }
usage() {
    cat <<EOF
Usage: $PROG --rootfs DIR --public-key FILE

Installe atomiquement une cle publique dans DIR/root/.ssh/authorized_keys.
DIR doit etre un rootfs Alpine A71 avec /init -> /sbin/init.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --rootfs) [ $# -ge 2 ] || die "--rootfs attend un repertoire" 2; ROOTFS=$2; shift ;;
        --public-key) [ $# -ge 2 ] || die "--public-key attend un fichier" 2; KEYFILE=$2; shift ;;
        -*) die "option inconnue : $1" 2 ;;
        *) die "argument inattendu : $1" 2 ;;
    esac
    shift
done

[ -n "$ROOTFS" ] || { usage >&2; exit 2; }
[ -n "$KEYFILE" ] || { usage >&2; exit 2; }
[ "$EUID" -ne 0 ] || [ "$ALLOW_ROOT" = "1" ] ||
    die "execution root refusee (A71_PROVISION_ALLOW_ROOT=1 pour necessite documentee)"

[ -d "$ROOTFS" ] || die "rootfs absent"
ROOTFS=$(cd "$ROOTFS" && pwd -P) || die "rootfs inaccessible"
case "$ROOTFS" in /dev/*) die "refus d'un chemin /dev" ;; esac
[ -L "$ROOTFS/init" ] && [ "$(readlink "$ROOTFS/init")" = "/sbin/init" ] ||
    die "rootfs incompatible: /init -> /sbin/init absent"
VERSION=$(tr -d '\r\n' <"$ROOTFS/etc/alpine-release" 2>/dev/null || true)
[ "$VERSION" = "3.22.7" ] || die "version Alpine inattendue : ${VERSION:-absente}"
[ -f "$ROOTFS/etc/ssh/sshd_config" ] || die "sshd_config absent"
[ -f "$ROOTFS/reports/ownership-manifest.txt" ] || die "manifeste de proprietaires absent"
[ -f "$KEYFILE" ] && [ ! -L "$KEYFILE" ] || die "cle publique absente, non reguliere ou symlink"
[ "$(stat -c '%s' "$KEYFILE")" -le 16384 ] || die "cle publique trop volumineuse"

TMP=$(mktemp) || die "temporaire impossible"
TMP_KEY=""
trap 'rm -f "$TMP" "$TMP_KEY"' EXIT
if grep -q 'PRIVATE KEY' "$KEYFILE"; then die "fichier de cle privee refuse"; fi
awk 'NF {n++} END {exit n==1 ? 0 : 1}' "$KEYFILE" || die "une seule ligne de cle attendue"
tr -d '\r' <"$KEYFILE" | sed '/^[[:space:]]*$/d' >"$TMP"
LINE=$(cat "$TMP")
TYPE=${LINE%% *}
case "$TYPE" in
    ssh-ed25519 | sk-ssh-ed25519@openssh.com | ssh-rsa | rsa-sha2-256 | rsa-sha2-512) ;;
    *) die "type de cle non accepte : $TYPE" ;;
esac
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen absent"
ssh-keygen -lf "$TMP" >/dev/null 2>&1 || die "cle publique invalide"
FINGERPRINT=$(ssh-keygen -lf "$TMP" | awk '{print $2}')
[ -n "$FINGERPRINT" ] || die "empreinte impossible"

SSH_DIR="$ROOTFS/root/.ssh"
AUTH="$SSH_DIR/authorized_keys"
[ ! -L "$SSH_DIR" ] || die "root/.ssh est un symlink"
mkdir -p "$SSH_DIR"
chmod 0700 "$SSH_DIR"
if [ -e "$AUTH" ] && [ ! -f "$AUTH" ]; then die "authorized_keys non regulier"; fi
if [ -s "$AUTH" ]; then die "authorized_keys deja non vide : refus (aucun historique importe)"; fi
TMP_KEY=$(mktemp "$SSH_DIR/.authorized_keys.XXXXXXXX") || die "temporaire SSH impossible"
trap 'rm -f "$TMP" "$TMP_KEY"' EXIT
cat "$TMP" >"$TMP_KEY"
chmod 0600 "$TMP_KEY"
mv -f "$TMP_KEY" "$AUTH"
TMP_KEY=""
chmod 0600 "$AUTH"

CONF="$ROOTFS/etc/ssh/sshd_config"
if grep -q '^PermitRootLogin[[:space:]]' "$CONF"; then
    sed 's/^PermitRootLogin[[:space:]].*/PermitRootLogin prohibit-password/' "$CONF" >"$CONF.tmp.$$"
else
    { cat "$CONF"; printf '\nPermitRootLogin prohibit-password\n'; } >"$CONF.tmp.$$"
fi
mv -f "$CONF.tmp.$$" "$CONF"

MAN="$ROOTFS/reports/ownership-manifest.txt"
for entry in '0:0:0700:d:/root/.ssh' '0:0:0600:f:/root/.ssh/authorized_keys'; do
    grep -qxF "$entry" "$MAN" || printf '%s\n' "$entry" >>"$MAN"
done
chmod 0600 "$MAN"

printf 'installed=%s\n' "$AUTH"
printf 'key_type=%s\n' "$TYPE"
printf 'fingerprint=%s\n' "$FINGERPRINT"
printf 'password_authentication=no\n'
printf 'permit_root_login=prohibit-password\n'
exit 0
