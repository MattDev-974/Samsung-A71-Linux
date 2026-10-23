#!/usr/bin/env bash
# collect-a71-runtime-logs.sh - copie en lecture seule des journaux A71.
# Aucune cle privee, aucun authorized_keys en clair, aucun secret.

set -Eeuo pipefail
PROG=$(basename "$0")
ROOTFS=""
OUT=""
FORCE=0
say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die() { say "$1"; exit "${2:-1}"; }

usage() {
    cat <<EOT
Usage: $PROG --rootfs DIR --output DIR [--force]

DIR doit etre un rootfs A71 monte, en lecture seule.
EOT
}
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --rootfs) [ $# -ge 2 ] || die "--rootfs" 2; ROOTFS=$2; shift ;;
        --output) [ $# -ge 2 ] || die "--output" 2; OUT=$2; shift ;;
        --force) FORCE=1 ;;
        *) die "argument inattendu : $1" 2 ;;
    esac
    shift
done
[ -n "$ROOTFS" ] || { usage >&2; exit 2; }
[ -n "$OUT" ] || { usage >&2; exit 2; }
[ -d "$ROOTFS" ] || die "rootfs absent"
ROOTFS=$(cd "$ROOTFS" && pwd -P)
[ -L "$ROOTFS/init" ] && [ "$(readlink "$ROOTFS/init")" = "/sbin/init" ] ||
    die "rootfs incompatible: /init -> /sbin/init absent"
VER=$(tr -d '\r\n' <"$ROOTFS/etc/alpine-release" 2>/dev/null || true)
[ "$VER" = "3.22.7" ] || die "version Alpine inattendue : ${VER:-absente}"
LABEL=$(findmnt -n -o LABEL --target "$ROOTFS" 2>/dev/null || true)
[ -z "$LABEL" ] || [ "$LABEL" = "A71ROOT" ] || die "label inattendu : $LABEL"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
[ ! -L "$OUT" ] || die "sortie symlink refusee"
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null || true)" ]; then
    [ "$FORCE" = 1 ] || die "sortie non vide (--force)"
fi
mkdir -p "$OUT" || die "sortie impossible"
umask 077
OUT=$(cd "$OUT" && pwd -P)
case "$OUT" in "$ROOTFS"/*) die "sortie dans le rootfs interdite" ;; esac
LOGS="$ROOTFS/var/log/a71"
[ -d "$LOGS" ] || die "journaux /var/log/a71 absents"
find "$LOGS" -maxdepth 1 -type f -print0 | LC_ALL=C sort -z |
while IFS= read -r -d '' f; do
    name=$(basename "$f")
    case "$name" in
        *authorized*|*private*|*ssh_host*_key*) continue ;;
    esac
    [ -r "$f" ] || die "journal illisible : $name"
    if grep -q 'PRIVATE KEY' "$f" 2>/dev/null; then
        die "bloc de cle privee detecte dans le journal : $name"
    fi
    cp -- "$f" "$OUT/$name"
done
{
    printf 'rootfs=%s\n' "$(basename "$ROOTFS")"
    printf 'alpine=%s\n' "$VER"
    printf 'label=%s\n' "${LABEL:-unknown}"
    printf 'runtime_status=not_tested\nvalidation_status=provisional\n'
} >"$OUT/summary.txt"
{
    printf 'path=root/.ssh/authorized_keys\n'
    if [ -f "$ROOTFS/root/.ssh/authorized_keys" ]; then
        stat -c 'mode=%a size=%s' "$ROOTFS/root/.ssh/authorized_keys"
        printf 'lines=%s\n' "$(wc -l <"$ROOTFS/root/.ssh/authorized_keys")"
        if command -v ssh-keygen >/dev/null 2>&1; then
            ssh-keygen -lf "$ROOTFS/root/.ssh/authorized_keys" 2>/dev/null |
                awk '{print "fingerprint=" $2}' || true
        fi
    else
        printf 'present=no\n'
    fi
} >"$OUT/ssh-metadata.txt"
{
    printf 'host_private_keys=absent\n'
    for pub in "$ROOTFS"/etc/ssh/ssh_host_*_key.pub; do
        [ -f "$pub" ] || continue
        printf 'name=%s mode=%s\n' "$(basename "$pub")" "$(stat -c '%a' "$pub")"
        ssh-keygen -lf "$pub" 2>/dev/null | awk '{print "fingerprint=" $2}' || true
    done
} >"$OUT/host-key-metadata.txt"
# Manifeste des seuls fichiers copies.
( cd "$OUT" && find . -type f -not -name 'manifest.sha256' -printf '%P\0' |
  LC_ALL=C sort -z | xargs -0 -r sha256sum ) >"$OUT/manifest.sha256"
( cd "$OUT" && sha256sum -c manifest.sha256 >/dev/null ) || die "manifeste invalide"
printf 'collected=%s\n' "$OUT"
printf 'files=%s\n' "$(find "$OUT" -type f | wc -l)"
printf 'no_private_key=yes\n'
