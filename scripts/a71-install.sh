#!/bin/sh
# a71-install.sh - installateur interactif pour le Galaxy A71
#
#   ./scripts/a71-install.sh                 menu
#   ./scripts/a71-install.sh sd /dev/sdX     installer le système sur une carte SD
#   ./scripts/a71-install.sh userdata        installer dans la partition USERDATA
#   ./scripts/a71-install.sh boot            flasher le noyau (partition BOOT)
#   ./scripts/a71-install.sh status          état du système qui tourne
#   ./scripts/a71-install.sh logs            récupérer les journaux
#
# Variables : A71_ROOTFS (tar.gz), A71_BOOT (boot.img), A71_HOST (172.16.42.1)
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TARBALL=${A71_ROOTFS:-$ROOT/work/a71-rootfs.tar.gz}
BOOTIMG=${A71_BOOT:-$ROOT/work/boot-ext4b.img}
HEIMDALL=${HEIMDALL:-$ROOT/work/heimdall-src/build/bin/heimdall}
HOST=${A71_HOST:-172.16.42.1}
SSH="ssh -i $HOME/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$HOST"

msg()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

need_root() { [ "$(id -u)" = 0 ] || die "cette opération demande root (relance avec sudo)"; }
need_file() { [ -f "$1" ] || die "fichier manquant : $1"; }
confirm() {
    warn "!! $*"
    printf 'Tape OUI pour confirmer : '
    read ans
    [ "$ans" = "OUI" ] || die "annulé"
}

# ---------------------------------------------------------------- SD (ext4)
install_sd() {
    dev=${1:-}
    [ -n "$dev" ] || die "usage: a71-install.sh sd /dev/sdX"
    case "$dev" in /dev/sd*|/dev/mmcblk*) ;; *) die "périphérique refusé : $dev" ;; esac
    need_root
    need_file "$TARBALL"
    echo "Cible : $dev ($(lsblk -dno SIZE "$dev" 2>/dev/null || echo '?'))"
    confirm "TOUT sera effacé sur $dev (ext4, label a71root)"
    umount "${dev}"* 2>/dev/null || true
    msg ">> formatage ext4"
    mkfs.ext4 -q -F -L a71root "$dev"
    mnt=$(mktemp -d)
    msg ">> montage et extraction du rootfs"
    mount "$dev" "$mnt"
    tar -xzf "$TARBALL" -C "$mnt"
    echo "userdata" >/dev/null
    printf 'mode=ext4\ntarget=%s\ndate=%s\n' "$dev" "$(date -Is)" > "$mnt/etc/a71-install"
    sync
    umount "$mnt"; rmdir "$mnt"
    msg ">> installé sur $dev"
    msg "   flashe le noyau si besoin : ./scripts/a71-install.sh boot"
}

# ------------------------------------------------------------ USERDATA (SSH)
install_userdata() {
    need_file "$TARBALL"
    msg ">> vérification de la connexion au téléphone"
    $SSH 'true' 2>/dev/null || die "téléphone injoignable (SSH $HOST)"
    warn "la partition USERDATA (/dev/sda32) contient Android : tout sera effacé"
    confirm "effacer USERDATA et installer le système ?"
    msg ">> copie de l'archive sur le téléphone"
    scp -i "$HOME/.ssh/id_ed25519" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null "$TARBALL" "root@$HOST:/tmp/a71-rootfs.tar.gz"
    msg ">> formatage (ext2/4 selon busybox) et extraction"
    $SSH '
        set -e
        umount /mnt/ud 2>/dev/null || true
        mkdir -p /mnt/ud
        if ! mkfs.ext4 -F /dev/sda32 2>/dev/null; then
            busybox mkfs.ext2 -F /dev/sda32
        fi
        mount -t ext4 /dev/sda32 /mnt/ud || mount /dev/sda32 /mnt/ud
        tar -xzf /tmp/a71-rootfs.tar.gz -C /mnt/ud
        printf "mode=userdata\ntarget=/dev/sda32\n" > /mnt/ud/etc/a71-install
        sync
        umount /mnt/ud
        rm -f /tmp/a71-rootfs.tar.gz
        echo "installé sur /dev/sda32"
    '
    msg ">> terminé (au prochain démarrage, le sélecteur trouvera userdata)"
}

# ------------------------------------------------------------------- BOOT
flash_boot() {
    need_file "$BOOTIMG"
    [ -x "$HEIMDALL" ] || die "heimdall introuvable : $HEIMDALL"
    msg ">> attente du Download mode"
    i=0
    while ! lsusb 2>/dev/null | grep -q '04e8:685d'; do
        i=$((i+1))
        [ $i -lt 60 ] || die "téléphone absent (Download mode : Power 15 s, Vol+ et Vol-, câble)"
        sleep 1
    done
    msg ">> flash de $(basename "$BOOTIMG") sur BOOT"
    "$HEIMDALL" flash --BOOT "$BOOTIMG" --no-reboot
    msg ">> flash terminé — maintiens Power 20 s pour démarrer"
}

# ----------------------------------------------------------------- STATUS
show_status() {
    $SSH '
        echo "système   : $(cat /etc/a71-install 2>/dev/null | tr "\n" " ")"
        echo "noyau     : $(uname -r)"
        echo "racine    : $(mount | awk "\$3==\"/\"{print \$1, \$5}")"
        echo "espace    : $(df -h / | awk "NR==2{print \$2\" total, \"\$4\" libres\"}")"
        echo "mémoire   : $(free -h | awk "/Mem:/{print \$2\" total, \"\$7\" dispo\"}")"
        echo "réseau    : $(ip -br addr | awk "\$1!=\"lo\"{printf \"%s %s \", \$1, \$3}")"
        echo "route     : $(ip route | awk "/default/{print \$3, \$5}")"
        echo "udc       : $(ls /sys/class/udc 2>/dev/null | tr "\n" " ")"
        echo "uptime    : $(uptime | sed "s/.*up //;s/,.*//")"
    '
}

# ---------------------------------------------------------------- PACKAGES
install_pkgs() {
    [ $# -gt 0 ] || die "usage: a71-install.sh pkgs <paquet> [paquet...]"
    $SSH 'true' 2>/dev/null || die "téléphone injoignable"
    msg ">> apk update"
    $SSH 'apk update 2>&1 | tail -2'
    msg ">> installation : $*"
    $SSH "apk add --no-cache $* 2>&1 | tail -6"
}

# ------------------------------------------------------------------- LOGS
fetch_logs() {
    out=${1:-$ROOT/work/logs-$(date +%Y%m%d-%H%M%S)}
    mkdir -p "$out"
    msg ">> récupération vers $out"
    $SSH 'dmesg' > "$out/dmesg.txt" 2>/dev/null || warn "dmesg indisponible"
    $SSH 'ls -la /sys/fs/pstore 2>/dev/null; cat /sys/fs/pstore/console-ramoops-0 2>/dev/null' \
        > "$out/pstore.txt" 2>/dev/null || true
    $SSH 'ip -br addr; ip route; cat /proc/meminfo | head -3' > "$out/state.txt" 2>/dev/null || true
    msg ">> $(ls "$out" | tr '\n' ' ')"
}

# ------------------------------------------------------------------- MENU
menu() {
    while :; do
        cat <<EOF

=== Galaxy A71 — installateur ===
 1) installer le système sur une carte SD (ext4, persistant)
 2) installer dans USERDATA (eMMC, écrase Android)
 3) flasher le noyau (partition BOOT)
 4) état du système qui tourne
 5) récupérer les journaux
 6) installer des paquets Alpine (apk)
 q) quitter
EOF
        printf 'choix : '
        read c
        case "$c" in
            1) printf 'périphérique de la carte (ex. /dev/sde) : '; read d; install_sd "$d" ;;
            2) install_userdata ;;
            3) flash_boot ;;
            4) show_status ;;
            5) fetch_logs ;;
            6) printf 'paquets (ex. nano htop curl) : '; read p; install_pkgs $p ;;
            q|Q) exit 0 ;;
            *) warn "choix inconnu" ;;
        esac
    done
}

case "${1:-menu}" in
    menu)      menu ;;
    sd)        shift; install_sd "$@" ;;
    userdata)  install_userdata ;;
    boot)      flash_boot ;;
    status)    show_status ;;
    logs)      shift; fetch_logs "$@" ;;
    pkgs)      shift; install_pkgs "$@" ;;
    *)         sed -n '2,14p' "$0"; exit 1 ;;
esac
