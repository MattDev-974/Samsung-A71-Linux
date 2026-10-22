#!/bin/sh
# a71-setup.sh - assistant d'installation (façon setup-alpine) pour le Galaxy A71
#
# Génère un rootfs personnalisé puis l'installe sur la carte SD ou USERDATA.
#
#   ./scripts/a71-setup.sh              assistant interactif
#   ./scripts/a71-setup.sh --defaults   tout par défaut (clé SSH de l'utilisateur)
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE=${A71_BASE:-$ROOT/../work/a71-base-rootfs.tar.gz}
OUT=${A71_OUT:-$ROOT/../work/a71-custom-rootfs.tar.gz}

msg()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
ask()  { printf '%s [%s] : ' "$1" "$2"; read v; [ -n "$v" ] && echo "$v" || echo "$2"; }
asky() { printf '%s [%s] : ' "$1" "$2"; read v; [ -n "$v" ] && echo "$v" || echo "$2"; }

[ -f "$BASE" ] || die "rootfs de base manquant : $BASE"

# ------------------------------------------------------------------ défauts
HOSTNAME=a71
TIMEZONE=UTC
SSH_SERVER=openssh
SSH_AUTH=key                 # key | password | both
ROOT_LOGIN=prohibit-password # yes | prohibit-password | no
KEYFILE=$HOME/.ssh/id_ed25519.pub
ROOTPASS=
USERNAME=
USERPASS=
PACKAGES="nano htop"
INIT_SYSTEM=openrc            # openrc | script
TARGET_KIND=                 # sd | userdata
TARGET_DEV=

if [ "${1:-}" != "--defaults" ]; then
    msg "=== Assistant d'installation — Galaxy A71 ==="
    HOSTNAME=$(ask "Nom d'hôte" "$HOSTNAME")
    TIMEZONE=$(ask "Fuseau horaire (ex. Indian/Reunion, UTC)" "$TIMEZONE")

    echo "Serveur SSH : openssh (seul proposé pour l'instant)"
    SSH_SERVER=openssh

    echo "Authentification SSH :"
    echo "  1) clé publique seulement (recommandé)"
    echo "  2) mot de passe seulement"
    echo "  3) clé + mot de passe"
    SH=$(ask "choix" "1")
    case "$SH" in 1) SSH_AUTH=key ;; 2) SSH_AUTH=password ;; 3) SSH_AUTH=both ;; *) SSH_AUTH=key ;; esac

    if [ "$SSH_AUTH" != "password" ]; then
        KEYFILE=$(ask "Clé publique à autoriser" "$KEYFILE")
        [ -f "$KEYFILE" ] || die "clé introuvable : $KEYFILE"
    fi

    echo "Connexion root :"
    echo "  1) par clé uniquement (prohibit-password, recommandé)"
    echo "  2) autorisée avec mot de passe (yes)"
    echo "  3) interdite (no)"
    RL=$(ask "choix" "1")
    case "$RL" in 1) ROOT_LOGIN=prohibit-password ;; 2) ROOT_LOGIN=yes ;; 3) ROOT_LOGIN=no ;; *) ROOT_LOGIN=prohibit-password ;; esac

    if [ "$SSH_AUTH" != "key" ]; then
        printf 'Mot de passe root (vide = aucun) : '; read -r ROOTPASS
    fi

    printf 'Créer un utilisateur normal (nom, vide = aucun) : '; read -r USERNAME
    if [ -n "$USERNAME" ]; then
        printf 'Mot de passe de %s : ' "$USERNAME"; read -r USERPASS
    fi

        echo "Système d'init :"
    echo "  1) OpenRC (vrai Alpine, services rc-service) — recommandé"
    echo "  2) script simple (comme avant)"
    INIT=$(ask "choix" "1")
    case "$INIT" in 1) INIT_SYSTEM=openrc ;; *) INIT_SYSTEM=script ;; esac

PACKAGES=$(ask "Paquets supplémentaires (espace)" "$PACKAGES")

    echo "Cible d'installation :"
    echo "  1) carte SD (ext4)"
    echo "  2) USERDATA (eMMC, écrase Android)"
    TK=$(ask "choix" "1")
    case "$TK" in
        1) TARGET_KIND=sd; TARGET_DEV=$(ask "périphérique de la carte (ex. /dev/sde)" "/dev/sde") ;;
        2) TARGET_KIND=userdata ;;
        *) die "choix invalide" ;;
    esac
fi

# ------------------------------------------------------- génération rootfs
msg ">> préparation du rootfs personnalisé"
STAGE=$(mktemp -d)
tar -xzf "$BASE" -C "$STAGE"

have_pkg() { echo " $PACKAGES " | grep -q " $1 "; }
add_pkg()  { have_pkg "$1" || PACKAGES="$PACKAGES $1"; }

# --- identité
echo "$HOSTNAME" > "$STAGE/etc/hostname"
printf '127.0.0.1\tlocalhost %s\n::1\t\tlocalhost %s\n' "$HOSTNAME" "$HOSTNAME" > "$STAGE/etc/hosts"

# --- fuseau horaire
echo "$TIMEZONE" > "$STAGE/etc/timezone"
mkdir -p "$STAGE/etc"
# tzdata sera installé au premier démarrage ; le lien est posé s'il existe
if [ -f "$STAGE/usr/share/zoneinfo/$TIMEZONE" ]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$STAGE/etc/localtime"
else
    add_pkg tzdata
fi

# --- mot de passe root
if [ -n "$ROOTPASS" ]; then
    hash=$(openssl passwd -6 "$ROOTPASS" 2>/dev/null) || die "openssl requis pour le mot de passe"
    sed -i "s|^root:[^:]*:|root:$hash:|" "$STAGE/etc/shadow"
    msg "   mot de passe root défini"
else
    sed -i 's|^root:[^:]*:|root:*:|' "$STAGE/etc/shadow"
fi

# --- utilisateur normal
if [ -n "$USERNAME" ]; then
    add_pkg doas
    echo "$USERNAME:x:1000:1000:$USERNAME:/home/$USERNAME:/bin/ash" >> "$STAGE/etc/passwd"
    echo "$USERNAME:x:1000:" >> "$STAGE/etc/group"
    if [ -n "$USERPASS" ]; then
        hash=$(openssl passwd -6 "$USERPASS" 2>/dev/null)
        echo "$USERNAME:$hash:0:0:99999:7:::" >> "$STAGE/etc/shadow"
    else
        echo "$USERNAME:!:0:0:99999:7:::" >> "$STAGE/etc/shadow"
    fi
    mkdir -p "$STAGE/home/$USERNAME"
    mkdir -p "$STAGE/etc/doas.d"
    printf 'permit persist %s as root\n' "$USERNAME" > "$STAGE/etc/doas.d/10-$USERNAME.conf"
fi

# --- SSH
mkdir -p "$STAGE/etc/ssh/sshd_config.d"
case "$SSH_AUTH" in
    key)      PW=no ;;
    password) PW=yes ;;
    both)     PW=yes ;;
esac
{
    echo "# généré par a71-setup.sh"
    echo "PermitRootLogin $ROOT_LOGIN"
    echo "PasswordAuthentication $PW"
    echo "PubkeyAuthentication yes"
    echo "PermitEmptyPasswords no"
    echo "UseDNS no"
    echo "X11Forwarding no"
    echo "StrictModes no"
    echo "SetEnv LANG=C.UTF-8 LC_ALL=C.UTF-8"
} > "$STAGE/etc/ssh/sshd_config.d/10-a71.conf"

mkdir -p "$STAGE/root/.ssh"
chmod 700 "$STAGE/root/.ssh"
if [ "$SSH_AUTH" != "password" ] && [ -f "$KEYFILE" ]; then
    cat "$KEYFILE" > "$STAGE/root/.ssh/authorized_keys"
    chmod 600 "$STAGE/root/.ssh/authorized_keys"
fi
if [ -n "$USERNAME" ] && [ "$SSH_AUTH" != "password" ] && [ -f "$KEYFILE" ]; then
    mkdir -p "$STAGE/home/$USERNAME/.ssh"
    cp "$KEYFILE" "$STAGE/home/$USERNAME/.ssh/authorized_keys"
    chmod 700 "$STAGE/home/$USERNAME/.ssh"
    chmod 600 "$STAGE/home/$USERNAME/.ssh/authorized_keys"
fi

# --- init system
if [ "$INIT_SYSTEM" = "openrc" ]; then
    add_pkg openrc
    add_pkg alpine-conf
    add_pkg chrony
    cp "$ROOT/scripts/a71-openrc-setup.sh" "$STAGE/etc/a71-openrc-setup.sh"
    chmod +x "$STAGE/etc/a71-openrc-setup.sh"
    echo "openrc" > "$STAGE/etc/a71-init"
else
    echo "script" > "$STAGE/etc/a71-init"
fi

# --- paquets à installer au premier démarrage
if [ -n "$PACKAGES" ]; then
    echo "$PACKAGES" > "$STAGE/etc/a71-packages"
fi

# --- marqueur d'installation
printf 'mode=custom\nhostname=%s\ntimezone=%s\nssh=%s\nauth=%s\nroot_login=%s\ndate=%s\n' \
    "$HOSTNAME" "$TIMEZONE" "$SSH_SERVER" "$SSH_AUTH" "$ROOT_LOGIN" "$(date -Is)" \
    > "$STAGE/etc/a71-install"

# --- premier démarrage : propriétaires, paquets, fuseau
cat > "$STAGE/etc/a71-firstboot.sh" <<'EOF'
#!/bin/sh
# exécuté une seule fois, par l'init, au premier démarrage
set -e
echo "a71: premier démarrage" > /dev/kmsg
chown -R 0:0 /root /home /etc/ssh /etc/apk /etc/ssl 2>/dev/null || true
chmod 700 /root/.ssh 2>/dev/null || true
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
tz=$(cat /etc/timezone 2>/dev/null)
[ -n "$tz" ] && [ -f "/usr/share/zoneinfo/$tz" ] && ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
if [ -f /etc/a71-packages ]; then
    apk update 2>&1 | tail -2
    apk add --no-cache $(cat /etc/a71-packages) 2>&1 | tail -4 || true
fi
if [ "$(cat /etc/a71-init 2>/dev/null)" = "openrc" ] && [ -x /etc/a71-openrc-setup.sh ]; then
    echo "a71: bascule vers OpenRC" > /dev/kmsg
    /etc/a71-openrc-setup.sh >>/var/log/a71-openrc.log 2>&1 || true
    rm -f /etc/a71-openrc-setup.sh
fi
rm -f /etc/a71-firstboot
echo "a71: premier démarrage terminé" > /dev/kmsg
EOF
chmod +x "$STAGE/etc/a71-firstboot.sh"
ln -sf /etc/a71-firstboot.sh "$STAGE/etc/a71-firstboot"

msg ">> création de l'archive"
tar -czf "$OUT" -C "$STAGE" --owner=0 --group=0 .
rm -rf "$STAGE"
ls -lh "$OUT"
if [ "${A71_NO_INSTALL:-0}" = "1" ]; then
    msg ">> archive prête : $OUT (installation ignorée)"
    exit 0
fi

msg ">> installation"
if [ "$(id -u)" = 0 ]; then
    A71_ROOTFS="$OUT" exec "$ROOT/scripts/a71-install.sh" "$TARGET_KIND" ${TARGET_DEV:+"$TARGET_DEV"}
else
    exec sudo env A71_ROOTFS="$OUT" "$ROOT/scripts/a71-install.sh" "$TARGET_KIND" ${TARGET_DEV:+"$TARGET_DEV"}
fi
