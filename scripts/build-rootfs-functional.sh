#!/usr/bin/env bash
# shellcheck shell=bash
#
# build-rootfs-functional.sh - rootfs fonctionnel Alpine aarch64 a partir de
#                              work/rootfs/rootfs-with-modules (jamais modifie).
#
# Ce script est le successeur du script legacy scripts/build-rootfs.sh, qu'il ne
# remplace pas et ne modifie pas.
#
# Aucun chroot, montage, QEMU, proot, sudo ; aucun binaire aarch64 execute.
# Les paquets sont installes par apk x86_64 authentifie, signatures verifiees
# avec les cles du minirootfs aarch64 valide, sans --allow-untrusted.
#
# Usage :
#   ./scripts/build-rootfs-functional.sh --manifest manifest.yaml \
#       --rootfs-in work/rootfs/rootfs-with-modules \
#       --apk-root work/apk-bootstrap/root \
#       --output work/rootfs/rootfs-functional [--force]
#
# Modes (D1) : les modes du rootfs cible ne viennent JAMAIS de l'umask de
# l'hote. Ils viennent de l'archive minirootfs verifiee et des metadonnees tar
# des paquets .apk signes, via scripts/rootfs-modes.py, avec les surcharges
# explicites de configs/rootfs-mode-policy.txt. L'umask 077 ne s'applique
# qu'aux temporaires et rapports prives.
#
# Codes : 0 ok, 2 usage, 3 manifeste, 4 entree, 5 apk, 6 paquets,
#         7 sortie, 8 validation finale

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PROG=$(basename "$0")

EXIT_OK=0
EXIT_USAGE=2
EXIT_MANIFEST=3
EXIT_INPUT=4
EXIT_APK=5
EXIT_PKGS=6
EXIT_OUTPUT=7
EXIT_FINAL=8

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
usage_error() { say "$1"; printf 'Utilise --help.\n' >&2; exit "$EXIT_USAGE"; }
die_code() { local c=$1; shift; say "$*"; exit "$c"; }

usage() {
    cat <<EOF
$PROG - rootfs fonctionnel Alpine aarch64 (sans chroot)

Usage
  $PROG --manifest FILE --rootfs-in DIR --apk-root DIR --output DIR [options]

Options
  --manifest FILE          manifeste du projet
  --rootfs-in DIR          rootfs avec modules (jamais modifie)
  --apk-root DIR           minirootfs x86_64 contenant sbin/apk + chargeur musl
  --output DIR             rootfs fonctionnel a produire
  --minirootfs-archive F   archive Alpine minirootfs verifiee
  --apk-cache DIR          cache des paquets .apk conserves (metadonnees)
  --policy FILE            politique de modes (configs/rootfs-mode-policy.txt)
  --force                  remplace la sortie apres sauvegarde .pre-d1
  -h, --help               cette aide
EOF
}

# Paquets : liste justifiee dans docs/ROOTFS.md
PACKAGES=(
    alpine-base openrc busybox busybox-openrc ca-certificates
    iproute2 openssh-server e2fsprogs util-linux kmod dhcpcd chrony dnsmasq
)

MANIFEST_FILE=""
ROOTFS_IN=""
APK_ROOT=""
OUT_DIR=""
MINIROOTFS_ARCHIVE=""
APK_CACHE=""
POLICY_FILE=""
FORCE=0
SEEN=" "
mark_opt() { case "$SEEN" in *" $1 "*) usage_error "option repetee : --$1" ;; esac; SEEN="$SEEN$1 "; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit "$EXIT_OK" ;;
        --manifest) mark_opt manifest; [ $# -ge 2 ] || usage_error "--manifest attend un fichier"; MANIFEST_FILE=$2; shift ;;
        --rootfs-in) mark_opt rootfs-in; [ $# -ge 2 ] || usage_error "--rootfs-in attend un repertoire"; ROOTFS_IN=$2; shift ;;
        --apk-root) mark_opt apk-root; [ $# -ge 2 ] || usage_error "--apk-root attend un repertoire"; APK_ROOT=$2; shift ;;
        --output) mark_opt output; [ $# -ge 2 ] || usage_error "--output attend un repertoire"; OUT_DIR=$2; shift ;;
        --minirootfs-archive) mark_opt minirootfs-archive; [ $# -ge 2 ] || usage_error "--minirootfs-archive attend un fichier"; MINIROOTFS_ARCHIVE=$2; shift ;;
        --apk-cache) mark_opt apk-cache; [ $# -ge 2 ] || usage_error "--apk-cache attend un repertoire"; APK_CACHE=$2; shift ;;
        --policy) mark_opt policy; [ $# -ge 2 ] || usage_error "--policy attend un fichier"; POLICY_FILE=$2; shift ;;
        --force) mark_opt force; FORCE=1 ;;
        -*) usage_error "option inconnue : $1" ;;
        *) usage_error "argument inattendu : $1" ;;
    esac
    shift
done

[ -n "$MANIFEST_FILE" ] || usage_error "--manifest est obligatoire"
[ -n "$ROOTFS_IN" ] || usage_error "--rootfs-in est obligatoire"
[ -n "$APK_ROOT" ] || usage_error "--apk-root est obligatoire"
[ -n "$OUT_DIR" ] || usage_error "--output est obligatoire"

umask 077

[ -f "$MANIFEST_FILE" ] || die_code "$EXIT_MANIFEST" "manifeste absent"
mval() {
    local k=$1 v rc=0
    v=$(A71_MANIFEST="$MANIFEST_FILE" bash -c '. "$1/scripts/common.sh"; manifest_get "$A71_MANIFEST" "$2"' _ "$REPO_ROOT" "$k") || rc=$?
    [ "$rc" -eq 0 ] || die_code "$EXIT_MANIFEST" "manifeste : cle absente ($k)"
    case "$v" in '' | TODO_*) die_code "$EXIT_MANIFEST" "manifeste : $k non resolu" ;; esac
    printf '%s\n' "$v"
}
EXPECTED_RELEASE=$(mval kernel.expected_release)
DIST_VERSION=$(mval distribution.version)
MINIROOTFS_SHA=$(mval distribution.minirootfs_sha256)
MINIROOTFS_ARCHIVE=${MINIROOTFS_ARCHIVE:-"$REPO_ROOT/../work/rootfs-cache/downloads/sha256/$MINIROOTFS_SHA"}
APK_CACHE=${APK_CACHE:-"$REPO_ROOT/../work/rootfs-cache/apk"}
POLICY_FILE=${POLICY_FILE:-"$REPO_ROOT/configs/rootfs-mode-policy.txt"}
MODE_HELPER="$REPO_ROOT/scripts/rootfs-modes.py"

[ -f "$MINIROOTFS_ARCHIVE" ] || die_code "$EXIT_INPUT" "archive minirootfs absente : $MINIROOTFS_ARCHIVE"
[ "$(sha256sum "$MINIROOTFS_ARCHIVE" | awk '{print $1}')" = "$MINIROOTFS_SHA" ] ||
    die_code "$EXIT_INPUT" "archive minirootfs : SHA-256 different du manifeste"
[ -f "$POLICY_FILE" ] || die_code "$EXIT_INPUT" "politique de modes absente : $POLICY_FILE"
[ -f "$MODE_HELPER" ] || die_code "$EXIT_INPUT" "helper de modes absent : $MODE_HELPER"
mkdir -p "$APK_CACHE" || die_code "$EXIT_OUTPUT" "cache APK impossible"

[ -d "$ROOTFS_IN" ] || die_code "$EXIT_INPUT" "rootfs d'entree absent"
[ -L "$ROOTFS_IN" ] && die_code "$EXIT_INPUT" "rootfs d'entree est un lien symbolique"
ROOTFS_IN=$(cd "$ROOTFS_IN" && pwd -P)
[ -d "$APK_ROOT/sbin" ] || die_code "$EXIT_INPUT" "minirootfs apk absent"
APK_ROOT=$(cd "$APK_ROOT" && pwd -P)
LOADER="$APK_ROOT/lib/ld-musl-x86_64.so.1"
APK_BIN="$APK_ROOT/sbin/apk"
[ -x "$LOADER" ] || die_code "$EXIT_APK" "chargeur musl absent"
[ -f "$APK_BIN" ] || die_code "$EXIT_APK" "apk absent"

KEYS_DIR="$ROOTFS_IN/etc/apk/keys"
[ -d "$KEYS_DIR" ] || die_code "$EXIT_INPUT" "cles apk absentes du rootfs d'entree"
[ "$(ls -1 "$KEYS_DIR"/*.rsa.pub 2>/dev/null | wc -l)" -ge 1 ] ||
    die_code "$EXIT_INPUT" "aucune cle apk"

case "$OUT_DIR" in /*) ;; *) OUT_DIR="$PWD/$OUT_DIR" ;; esac
[ -L "$OUT_DIR" ] && die_code "$EXIT_OUTPUT" "sortie est un lien symbolique"
OUT_DIR=$(realpath -m -- "$OUT_DIR") || die_code "$EXIT_OUTPUT" "chemin de sortie invalide"
[ "$OUT_DIR" = "$ROOTFS_IN" ] && die_code "$EXIT_OUTPUT" "sortie = rootfs d'entree"
case "$OUT_DIR" in "$ROOTFS_IN"/*) die_code "$EXIT_OUTPUT" "sortie dans le rootfs d'entree" ;; esac

OUT_PARENT=$(dirname "$OUT_DIR")
mkdir -p "$OUT_PARENT" || die_code "$EXIT_OUTPUT" "parent de sortie impossible"
WORK=$(mktemp -d "$OUT_PARENT/.a71-rootfs-func-XXXXXXXX") || die_code "$EXIT_OUTPUT" "temporaire impossible"
SIDE_DIR=$(mktemp -d "$OUT_PARENT/.a71-d1-side-XXXXXXXX") || die_code "$EXIT_OUTPUT" "temporaire de travail impossible"
MODE_DB="$SIDE_DIR/mode-db.tsv"
SOURCE_BEFORE="$SIDE_DIR/source-before.sha256"
SOURCE_AFTER="$SIDE_DIR/source-after.sha256"
cleanup() {
    [ -n "${WORK:-}" ] && rm -rf "$WORK"
    [ -n "${SIDE_DIR:-}" ] && rm -rf "$SIDE_DIR"
}
trap cleanup EXIT
REPORTS="$WORK/reports"
mkdir -p "$REPORTS"

# Le rootfs source ne doit jamais etre modifie : empreinte avant/apres.
python3 "$MODE_HELPER" fingerprint --root "$ROOTFS_IN" --output "$SOURCE_BEFORE" ||
    die_code "$EXIT_INPUT" "empreinte du rootfs source impossible"

cp -a "$ROOTFS_IN/." "$WORK/" || die_code "$EXIT_OUTPUT" "copie impossible"
# les rapports de l'etape precedente ne font pas partie du rootfs
rm -rf "${WORK:?}/reports"
mkdir -p "$REPORTS"

APK_RUN=("$LOADER" --library-path "$APK_ROOT/lib:$APK_ROOT/usr/lib" "$APK_BIN")
"${APK_RUN[@]}" --version >"$REPORTS/apk-version.txt" 2>&1 ||
    die_code "$EXIT_APK" "apk inutilisable"

REPOS="$WORK/etc/apk/repositories"
printf 'https://dl-cdn.alpinelinux.org/alpine/v3.22/main\nhttps://dl-cdn.alpinelinux.org/alpine/v3.22/community\n' >"$REPOS"

set +e
( umask 022
  env -i LC_ALL=C LANG=C TZ=UTC PATH=/usr/bin:/bin \
      "${APK_RUN[@]}" --root "$WORK" --arch aarch64 --keys-dir "$KEYS_DIR" \
      --repositories-file "$REPOS" --cache-dir "$APK_CACHE" \
      --no-scripts --no-progress --initdb \
      add "${PACKAGES[@]}" >"$REPORTS/apk-install.log" 2>&1 )
rc=$?
set -e
[ "$rc" -eq 0 ] || die_code "$EXIT_PKGS" "installation apk echouee (code $rc)"

# A partir d'ici, le rootfs cible est construit avec umask 022 (modes
# conformes aux paquets) ; les rapports prives repassent en 077 plus bas.
umask 022

LC_ALL=C "${APK_RUN[@]}" --root "$WORK" info -v 2>/dev/null | LC_ALL=C sort >"$REPORTS/packages.txt" || true
grep -q "alpine-base" "$REPORTS/packages.txt" || die_code "$EXIT_PKGS" "alpine-base absent"

# Metadonnees de modes : on force la recuperation de TOUS les .apk du world
# (le cache d'installation peut etre partiel et suffixer les noms par un hash).
META_DIR="$SIDE_DIR/apk-meta"
mkdir -p "$META_DIR"
set +e
( umask 077
  env -i LC_ALL=C LANG=C TZ=UTC PATH=/usr/bin:/bin \
      "${APK_RUN[@]}" fetch --root "$WORK" --arch aarch64 --keys-dir "$KEYS_DIR" \
      --repositories-file "$REPOS" --cache-dir "$APK_CACHE" --world -R \
      -o "$META_DIR" >"$REPORTS/apk-fetch.log" 2>&1 )
rc=$?
set -e
[ "$rc" -eq 0 ] || die_code "$EXIT_PKGS" "recuperation des metadonnees .apk echouee (code $rc)"

# scripts et triggers ignores par --no-scripts : inventaire
if [ -f "$WORK/lib/apk/db/installed" ]; then
    awk '/^S:/{s=1} s&&/^$/{s=0}' "$WORK/lib/apk/db/installed" |
        grep -E '^\.(pre|post)-(install|upgrade|deinstall)\.sh|^\.trigger' |
        sort -u >"$REPORTS/apk-scripts.txt" || true
fi
[ -s "$REPORTS/apk-scripts.txt" ] || printf '# aucun script/trigger dans les paquets installes\n' >"$REPORTS/apk-scripts.txt"

printf 'a71\n' >"$WORK/etc/hostname"
cat >"$WORK/etc/hosts" <<'EOF'
127.0.0.1	localhost.localdomain localhost
::1		localhost.localdomain localhost ip6-localhost ip6-loopback
172.16.42.1	a71.localdomain a71
EOF
cat >"$WORK/etc/fstab" <<'EOF'
LABEL=A71ROOT	/	ext4	rw,relatime	0 1
proc		/proc	proc	defaults	0 0
sysfs		/sys	sysfs	defaults	0 0
devtmpfs	/dev	devtmpfs	mode=0755,nosuid	0 0
tmpfs		/run	tmpfs	mode=0755,nosuid,nodev	0 0
EOF
ln -sfn /usr/share/zoneinfo/UTC "$WORK/etc/localtime"
printf 'UTC\n' >"$WORK/etc/timezone"

mkdir -p "$WORK/etc/network" "$WORK/etc/conf.d" "$WORK/etc/runlevels"/{boot,sysinit,default,shutdown}
cat >"$WORK/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
EOF

cat >"$WORK/etc/inittab" <<'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

tty0::respawn:/sbin/getty 38400 tty0
# ttyMSM0 n'est pas enregistre sur ce noyau (absent de /proc/consoles et /dev).
#ttyMSM0::respawn:/sbin/getty -L 115200 ttyMSM0 vt100

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

mkdir -p "$WORK/etc/ssh"
cat >"$WORK/etc/ssh/sshd_config" <<'EOF'
Port 22
Protocol 2
PermitRootLogin prohibit-password
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding no
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
Subsystem	sftp	/usr/lib/ssh/sftp-server
EOF
rm -f "$WORK"/etc/ssh/ssh_host_* 2>/dev/null || true

mkdir -p "$WORK/etc/local.d"
cat >"$WORK/etc/local.d/firstboot.start" <<'EOF'
#!/bin/sh
# Idempotent : genere les cles SSH hote si absentes. Aucun secret embarque.
set -e
for t in ed25519 rsa; do
    k=/etc/ssh/ssh_host_${t}_key
    [ -f "$k" ] || ssh-keygen -q -t "$t" -N '' -f "$k"
done
rc-update add sshd default 2>/dev/null || true
EOF
chmod 755 "$WORK/etc/local.d/firstboot.start"
printf 'rc_verbose=yes\n' >"$WORK/etc/conf.d/local"
[ -e "$WORK/etc/init.d/local" ] &&
    ln -sfn /etc/init.d/local "$WORK/etc/runlevels/default/local" 2>/dev/null || true

for svc in devfs procfs sysfs mdev; do
    [ -e "$WORK/etc/init.d/$svc" ] && ln -sfn "/etc/init.d/$svc" "$WORK/etc/runlevels/sysinit/$svc"
done
[ -e "$WORK/etc/init.d/sshd" ] && ln -sfn /etc/init.d/sshd "$WORK/etc/runlevels/default/sshd"
[ -e "$WORK/etc/init.d/chronyd" ] && ln -sfn /etc/init.d/chronyd "$WORK/etc/runlevels/default/chronyd"
[ -e "$WORK/etc/init.d/syslog" ] && ln -sfn /etc/init.d/syslog "$WORK/etc/runlevels/boot/syslog"
for svc in a71-usb a71-net a71-ssh-keys a71-bootlog a71-clock; do
    [ -e "$WORK/etc/init.d/$svc" ] && ln -sfn "/etc/init.d/$svc" "$WORK/etc/runlevels/default/$svc"
done
mkdir -p "$WORK/root/.ssh"
chmod 0700 "$WORK/root/.ssh"

if [ -f "$WORK/etc/shadow" ]; then
    awk -F: 'BEGIN{OFS=":"} $1=="root"{$2="*"} {print}' "$WORK/etc/shadow" >"$WORK/etc/shadow.new" &&
        mv "$WORK/etc/shadow.new" "$WORK/etc/shadow"
    chmod 640 "$WORK/etc/shadow"
fi

# --- contrat historique switch_root /newroot /init ----------------------
# Le selecteur historique appelle exactement /init. Un seul lien suffit :
# /init -> /sbin/init ; /sbin/init est le lien Alpine vers BusyBox init.
if [ -L "$WORK/init" ]; then
    [ "$(readlink "$WORK/init")" = "/sbin/init" ] ||
        die_code "$EXIT_FINAL" "/init existe deja avec une autre cible"
elif [ -e "$WORK/init" ]; then
    die_code "$EXIT_FINAL" "/init existe deja comme fichier non-lien"
else
    ln -s /sbin/init "$WORK/init" || die_code "$EXIT_FINAL" "creation de /init impossible"
fi
[ -L "$WORK/init" ] && [ "$(readlink "$WORK/init")" = "/sbin/init" ] ||
    die_code "$EXIT_FINAL" "/init n'est pas le lien exact /sbin/init"
if [ -L "$WORK/sbin/init" ]; then
    [ "$(readlink "$WORK/sbin/init")" = "/bin/busybox" ] ||
        die_code "$EXIT_FINAL" "/sbin/init ne pointe pas vers /bin/busybox"
else
    [ -f "$WORK/sbin/init" ] && [ -x "$WORK/sbin/init" ] ||
        die_code "$EXIT_FINAL" "/sbin/init absent ou non executable"
fi
[ -x "$WORK/bin/busybox" ] || die_code "$EXIT_FINAL" "BusyBox absent"
[ -x "$WORK/lib/ld-musl-aarch64.so.1" ] || die_code "$EXIT_FINAL" "chargeur musl absent"
[ -x "$WORK/sbin/openrc" ] || die_code "$EXIT_FINAL" "OpenRC absent"
[ -f "$WORK/etc/inittab" ] || die_code "$EXIT_FINAL" "/etc/inittab absent"
{
    printf 'type=symlink\n'
    printf 'path=/init\n'
    printf 'target=/sbin/init\n'
    printf 'uid=0\n'
    printf 'gid=0\n'
    printf 'resolved=/bin/busybox\n'
    printf 'resolved_kind=file\n'
    printf 'resolved_executable=yes\n'
} >"$REPORTS/init-link.txt"

# Surcouche A71 : scripts/services audites, sans secret.
if [ -d "$REPO_ROOT/rootfs" ]; then
    cp -a "$REPO_ROOT/rootfs/." "$WORK/" || die_code "$EXIT_FINAL" "surcouche rootfs impossible"
fi
mkdir -p "$WORK/root/.ssh"
chmod 0700 "$WORK/root/.ssh"
for svc in a71-usb a71-net a71-ssh-keys a71-bootlog a71-clock; do
    [ -e "$WORK/etc/init.d/$svc" ] && ln -sfn "/etc/init.d/$svc" "$WORK/etc/runlevels/default/$svc"
done

# Base de modes : archive minirootfs verifiee + metadonnees tar des .apk
# signes conserves dans le cache. Aucun mode n'est deduit de l'hote.
python3 "$MODE_HELPER" build-db \
    --archive "$MINIROOTFS_ARCHIVE" \
    --apk-dir "$META_DIR" \
    --packages "$REPORTS/packages.txt" \
    --version "$DIST_VERSION" \
    --output "$MODE_DB" \
    --summary "$REPORTS/mode-db-summary.txt" ||
    die_code "$EXIT_FINAL" "base de modes impossible"

# Application chemin par chemin (jamais de chmod recursif) + manifeste
# logique UID/GID/mode cible.
( umask 077
  python3 "$MODE_HELPER" apply \
      --root "$WORK" \
      --db "$MODE_DB" \
      --policy "$POLICY_FILE" \
      --manifest "$REPORTS/ownership-manifest.txt" \
      --report "$REPORTS/mode-application.txt" \
      --changes "$REPORTS/mode-changes.txt" \
      --policy-report "$REPORTS/mode-policy.txt" ) ||
    die_code "$EXIT_FINAL" "application des modes impossible"

# Preuve des modes sensibles : la source doit etre le paquet signe, pas une
# valeur inventee par la politique.
awk -F'\t' '$1=="bin/bbsuid" && $2=="f" && $3=="4111" && $6 ~ /^apk:busybox-suid-/ {found=1} END {exit !found}' "$MODE_DB" ||
    die_code "$EXIT_FINAL" "mode exact de bin/bbsuid non prouve par le paquet busybox-suid"
awk -F'\t' '$1=="bin/busybox" && $2=="f" && $3=="0755" && $6 ~ /^apk:busybox-/ {found=1} END {exit !found}' "$MODE_DB" ||
    die_code "$EXIT_FINAL" "mode exact de bin/busybox non prouve par le paquet busybox"
[ "$(stat -c '%a' "$WORK/bin/bbsuid")" = "4111" ] ||
    die_code "$EXIT_FINAL" "bin/bbsuid n'est pas en 04111 apres application"

[ "$(tr -d '\r\n' <"$WORK/etc/alpine-release")" = "$DIST_VERSION" ] ||
    die_code "$EXIT_FINAL" "version Alpine modifiee"
[ "$(tr -d '\r\n' <"$WORK/etc/apk/arch")" = "aarch64" ] ||
    die_code "$EXIT_FINAL" "architecture modifiee"
[ -d "$WORK/lib/modules/$EXPECTED_RELEASE" ] || die_code "$EXIT_FINAL" "modules absents"
[ "$(find "$WORK/lib/modules/$EXPECTED_RELEASE" -name '*.ko' | wc -l)" = "607" ] ||
    die_code "$EXIT_FINAL" "comptage de modules inattendu"
if find "$WORK" \( -type b -o -type c -o -type p -o -type s \) 2>/dev/null | grep -q .; then
    die_code "$EXIT_FINAL" "fichier special dans la sortie"
fi
# Recherche de blocs PEM : grep -I ignore les fichiers binaires (donc les ELF).
# Une chaine constante dans ssh-keygen/sshd ne doit jamais faire echouer.
if grep -rIl \
    -e 'BEGIN OPENSSH PRIVATE KEY' \
    -e 'BEGIN RSA PRIVATE KEY' \
    -e 'BEGIN EC PRIVATE KEY' \
    -e 'BEGIN PRIVATE KEY' \
    "$WORK" 2>/dev/null | grep -q .; then
    die_code "$EXIT_FINAL" "bloc PEM de cle privee detecte dans un fichier texte"
fi
if find "$WORK/etc/ssh" -maxdepth 1 \( -name 'ssh_host_*_key' -o -name 'id_rsa' -o -name 'id_ed25519' -o -name 'id_ecdsa' \) 2>/dev/null | grep -q .; then
    die_code "$EXIT_FINAL" "cle SSH prefabriquee detectee"
fi
if find "$WORK" -name 'boot*.img' 2>/dev/null | grep -q .; then
    die_code "$EXIT_FINAL" "boot.img present dans le rootfs"
fi
[ "$(find "$WORK/lib/modules" -mindepth 1 -maxdepth 1 -type d | wc -l)" = "1" ] ||
    die_code "$EXIT_FINAL" "plusieurs releases de modules"
if find "$WORK" -name '*.ko' -not -path "$WORK/lib/modules/$EXPECTED_RELEASE/*" | grep -q .; then
    die_code "$EXIT_FINAL" "module legacy hors de la release attendue"
fi

# Inventaire de contenu. bbsuid (04111) n'est pas lisible : on ajoute u+r
# uniquement pour le hash, puis on restaure le mode cible exact.
umask 077
find "$WORK" -type f -not -path "$WORK/reports/*" ! -readable -printf '%P\n' | sort \
    >"$REPORTS/unreadable-files.txt"
: >"$REPORTS/tree-manifest.sha256"
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    p="$WORK/$rel"
    old_mode=$(stat -c '%a' "$p") || die_code "$EXIT_FINAL" "stat impossible : $rel"
    if [ ! -r "$p" ]; then chmod u+r "$p" || die_code "$EXIT_FINAL" "lecture temporaire impossible : $rel"; fi
    h=$(sha256sum "$p" | awk '{print $1}') || die_code "$EXIT_FINAL" "hash impossible : $rel"
    [ "$(stat -c '%a' "$p")" = "$old_mode" ] || chmod "$old_mode" "$p" ||
        die_code "$EXIT_FINAL" "restauration de mode impossible : $rel"
    printf '%s  %s\n' "$h" "$rel" >>"$REPORTS/tree-manifest.sha256"
done < <(cd "$WORK" && find . -type f -not -path './reports/*' -printf '%P\n' | sort)
( cd "$WORK" && find . -type l -printf '%p -> %l\n' | sort ) >"$REPORTS/symlinks.txt"

# Le rootfs source doit etre bit-a-bit inchange.
python3 "$MODE_HELPER" fingerprint --root "$ROOTFS_IN" --output "$SOURCE_AFTER" ||
    die_code "$EXIT_FINAL" "empreinte finale du rootfs source impossible"
cmp -s "$SOURCE_BEFORE" "$SOURCE_AFTER" ||
    die_code "$EXIT_FINAL" "rootfs source modifie pendant la construction"

{
    printf 'result=OK\n'
    printf 'rootfs_version=%s\n' "$DIST_VERSION"
    printf 'rootfs_architecture=aarch64\n'
    printf 'kernel_release=%s\n' "$EXPECTED_RELEASE"
    printf 'module_count=607\n'
    printf 'packages_installed=%s\n' "$(wc -l <"$REPORTS/packages.txt")"
    printf 'apk_signatures=verified_by_apk\n'
    printf 'apk_no_scripts=yes\n'
    printf 'root_remote_login=disabled\n'
    printf 'password_auth=disabled\n'
    printf 'host_keys=generated_on_first_boot\n'
    printf 'private_keys=none\n'
    printf 'init_link=/init -> /sbin/init\n'
    printf 'init_link_target=/sbin/init\n'
    printf 'chroot_used=no\n'
    printf 'mount_used=no\n'
    printf 'qemu_used=no\n'
    printf 'mode_policy=configs/rootfs-mode-policy.txt\n'
    printf 'mode_db_entries=%s\n' "$(awk -F= '/^entries=/{print $2}' "$REPORTS/mode-db-summary.txt")"
    printf 'mode_changes=%s\n' "$(awk -F= '/^mode_changes=/{print $2}' "$REPORTS/mode-application.txt")"
    printf 'chmod_recursive=no\n'
    printf 'rootfs_source_unchanged=yes\n'
    printf 'unreadable_files=%s\n' "$(wc -l <"$REPORTS/unreadable-files.txt")"
    printf 'runtime=not_tested\n'
    printf 'validation=provisional\n'
} >"$REPORTS/rootfs-functional-summary.txt"

# Publication atomique : l'ancienne sortie est renommee, jamais supprimee.
if [ -e "$OUT_DIR" ]; then
    [ "$FORCE" = "1" ] || die_code "$EXIT_OUTPUT" "sortie non vide (--force)"
    if [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
        BACKUP="${OUT_DIR}.pre-d1"
        [ ! -e "$BACKUP" ] || die_code "$EXIT_OUTPUT" "sauvegarde deja presente : $BACKUP"
        mv "$OUT_DIR" "$BACKUP" || die_code "$EXIT_OUTPUT" "sauvegarde impossible"
        say "ancien rootfs sauvegarde : $BACKUP"
    else
        rmdir "$OUT_DIR" || die_code "$EXIT_OUTPUT" "sortie vide non supprimable"
    fi
fi
mv "$WORK" "$OUT_DIR" || die_code "$EXIT_OUTPUT" "publication atomique impossible"
WORK=""

say "rootfs fonctionnel : $OUT_DIR"
say "paquets : $(wc -l <"$OUT_DIR/reports/packages.txt") · modules : 607"
say "modes : $(awk -F= '/^mode_changes=/{print $2}' "$OUT_DIR/reports/mode-application.txt") correction(s), source inchangee"
exit "$EXIT_OK"
