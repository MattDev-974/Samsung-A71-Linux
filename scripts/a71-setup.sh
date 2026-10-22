#!/bin/sh
# a71-setup.sh - fabrique une image *prête à l'emploi* pour le Galaxy A71.
#
# Le rootfs de base contient déjà Alpine + OpenRC + apk + SSH + le réseau USB.
# L'assistant ne fait que de la configuration (fichiers), puis installe sur la
# carte SD. Après le flash du noyau, le téléphone est utilisable directement.
#
#   ./scripts/a71-setup.sh            assistant interactif
#   ./scripts/a71-setup.sh --defaults  tout par défaut (clé SSH de l'utilisateur)
#   ./scripts/a71-setup.sh --flash     installe puis flashe le noyau
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE=${A71_BASE:-$ROOT/../work/a71-ready-rootfs.tar.gz}
OUT=${A71_OUT:-$ROOT/../work/a71-custom-rootfs.tar.gz}
FLASH=0

for a in "$@"; do
    case "$a" in
        --flash) FLASH=1 ;;
        --defaults) DEFAULTS=1 ;;
    esac
done

msg()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
ask()  { printf '%s [%s] : ' "$1" "$2"; read v; [ -n "$v" ] && echo "$v" || echo "$2"; }

[ -f "$BASE" ] || die "rootfs de base manquant : $BASE"

# ------------------------------------------------------------------ défauts
HOSTNAME=a71
TIMEZONE=UTC
SSH_SERVER=openssh           # openssh | none
SSH_AUTH=key                 # key | password | both
ROOT_LOGIN=prohibit-password # yes | prohibit-password | no
KEYFILE=$HOME/.ssh/id_ed25519.pub
ROOTPASS=
USERNAME=
USERPASS=
PACKAGES=""
TARGET_KIND=sd
TARGET_DEV=/dev/sde

if [ "${DEFAULTS:-0}" != "1" ]; then
    msg "=== Installation du système (image prête à l'emploi) ==="
    HOSTNAME=$(ask "Nom d'hôte" "$HOSTNAME")

    echo "Fuseau horaire — exemples : Indian/Reunion, Europe/Paris, UTC"
    TIMEZONE=$(ask "Fuseau" "$TIMEZONE")

    echo "Serveur SSH :"
    echo "  1) OpenSSH (recommandé)"
    echo "  2) aucun (pas d'accès réseau à distance)"
    S=$(ask "choix" "1"); [ "$S" = "2" ] && SSH_SERVER=none || SSH_SERVER=openssh

    if [ "$SSH_SERVER" = "openssh" ]; then
        echo "Authentification SSH :"
        echo "  1) clé publique seulement (recommandé)"
        echo "  2) mot de passe seulement"
        echo "  3) clé + mot de passe"
        A=$(ask "choix" "1")
        case "$A" in 1) SSH_AUTH=key ;; 2) SSH_AUTH=password ;; 3) SSH_AUTH=both ;; *) SSH_AUTH=key ;; esac

        if [ "$SSH_AUTH" != "password" ]; then
            KEYFILE=$(ask "Clé publique à autoriser" "$KEYFILE")
            [ -f "$KEYFILE" ] || die "clé introuvable : $KEYFILE"
        fi

        echo "Connexion root :"
        echo "  1) par clé uniquement (prohibit-password, recommandé)"
        echo "  2) autorisée avec mot de passe (yes)"
        echo "  3) interdite (no)"
        R=$(ask "choix" "1")
        case "$R" in 1) ROOT_LOGIN=prohibit-password ;; 2) ROOT_LOGIN=yes ;; 3) ROOT_LOGIN=no ;; *) ROOT_LOGIN=prohibit-password ;; esac
    fi

    if [ "$SSH_AUTH" != "key" ] || [ "$ROOT_LOGIN" = "yes" ]; then
        printf 'Mot de passe root (vide = aucun) : '; read -r ROOTPASS
    fi

    printf 'Utilisateur normal à créer (nom, vide = aucun) : '; read -r USERNAME
    if [ -n "$USERNAME" ]; then
        printf 'Mot de passe de %s : ' "$USERNAME"; read -r USERPASS
    fi

    PACKAGES=$(ask "Paquets supplémentaires (installés au 1er démarrage, espace)" "")

    echo "Cible : 1) carte SD   2) USERDATA (écrase Android)"
    T=$(ask "choix" "1")
    if [ "$T" = "2" ]; then TARGET_KIND=userdata; else
        TARGET_KIND=sd
        TARGET_DEV=$(ask "périphérique de la carte (ex. /dev/sde)" "$TARGET_DEV")
    fi
fi

# ------------------------------------------------------- génération rootfs
msg ">> préparation de l'image"
STAGE=$(mktemp -d)
tar -xzf "$BASE" -C "$STAGE"

# --- identité
echo "$HOSTNAME" > "$STAGE/etc/hostname"
printf '127.0.0.1\tlocalhost %s\n::1\t\tlocalhost %s\n' "$HOSTNAME" "$HOSTNAME" > "$STAGE/etc/hosts"

# --- fuseau horaire (tzdata est présent dans la base)
echo "$TIMEZONE" > "$STAGE/etc/timezone"
if [ -f "$STAGE/usr/share/zoneinfo/$TIMEZONE" ]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$STAGE/etc/localtime"
    msg "   fuseau : $TIMEZONE"
else
    warn "   fuseau inconnu : $TIMEZONE (UTC conservé)"
fi

# --- mot de passe root
if [ -n "$ROOTPASS" ]; then
    hash=$(openssl passwd -6 "$ROOTPASS") || die "openssl requis"
    sed -i "s|^root:[^:]*:|root:$hash:|" "$STAGE/etc/shadow"
    msg "   mot de passe root défini"
else
    sed -i 's|^root:[^:]*:|root:*:|' "$STAGE/etc/shadow"
fi

# --- utilisateur normal
if [ -n "$USERNAME" ]; then
    echo "$USERNAME:x:1000:1000:$USERNAME:/home/$USERNAME:/bin/ash" >> "$STAGE/etc/passwd"
    echo "$USERNAME:x:1000:" >> "$STAGE/etc/group"
    if [ -n "$USERPASS" ]; then
        hash=$(openssl passwd -6 "$USERPASS")
        echo "$USERNAME:$hash:0:0:99999:7:::" >> "$STAGE/etc/shadow"
    else
        echo "$USERNAME:!:0:0:99999:7:::" >> "$STAGE/etc/shadow"
    fi
    # groupe wheel (administrateurs)
    if grep -q '^wheel:' "$STAGE/etc/group"; then
        sed -i "s|^wheel:\([^:]*\):\([^:]*\):.*|wheel:\1:\2:$USERNAME|" "$STAGE/etc/group"
    else
        echo "wheel:x:10:$USERNAME" >> "$STAGE/etc/group"
    fi
    mkdir -p "$STAGE/home/$USERNAME/.ssh"
    chmod 700 "$STAGE/home/$USERNAME/.ssh"
    mkdir -p "$STAGE/etc/sudoers.d"
    printf '%s ALL=(ALL) ALL\n' "$USERNAME" > "$STAGE/etc/sudoers.d/10-$USERNAME"
    chmod 440 "$STAGE/etc/sudoers.d/10-$USERNAME"
    if [ "$SSH_AUTH" != "password" ] && [ -f "$KEYFILE" ]; then
        cat "$KEYFILE" > "$STAGE/home/$USERNAME/.ssh/authorized_keys"
        chmod 600 "$STAGE/home/$USERNAME/.ssh/authorized_keys"
    fi
    msg "   utilisateur : $USERNAME (sudo)"
fi

# --- SSH
mkdir -p "$STAGE/etc/ssh/sshd_config.d"
case "$SSH_AUTH" in key) PW=no ;; password) PW=yes ;; both) PW=yes ;; *) PW=no ;; esac
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

if [ "$SSH_SERVER" = "none" ]; then
    rm -f "$STAGE/etc/runlevels/default/sshd" 2>/dev/null || true
    msg "   SSH désactivé"
fi

# --- paquets supplémentaires (premier démarrage, si réseau disponible)
if [ -n "$PACKAGES" ]; then
    echo "$PACKAGES" > "$STAGE/etc/a71-packages"
    cat > "$STAGE/etc/a71-firstboot.sh" <<'EOF'
#!/bin/sh
if [ -f /etc/a71-packages ]; then
    apk update >/dev/null 2>&1
    apk add --no-cache $(cat /etc/a71-packages) >/dev/null 2>&1
fi
rm -f /etc/a71-firstboot /etc/a71-firstboot.sh
EOF
    chmod +x "$STAGE/etc/a71-firstboot.sh"
    ln -sf /etc/a71-firstboot.sh "$STAGE/etc/a71-firstboot"
fi

# --- trace
printf 'mode=image\nhostname=%s\ntimezone=%s\nssh=%s\nauth=%s\nroot_login=%s\nuser=%s\ndate=%s\n' \
    "$HOSTNAME" "$TIMEZONE" "$SSH_SERVER" "$SSH_AUTH" "$ROOT_LOGIN" "$USERNAME" "$(date -Is)" \
    > "$STAGE/etc/a71-install"

msg ">> création de l'archive"
tar -czf "$OUT" -C "$STAGE" --owner=0 --group=0 .
rm -rf "$STAGE"
ls -lh "$OUT"

# ------------------------------------------------------------- installation
if [ "${A71_NO_INSTALL:-0}" = "1" ]; then
    msg ">> image prête : $OUT (installation ignorée)"
    exit 0
fi

if [ "$(id -u)" = 0 ]; then
    A71_ROOTFS="$OUT" "$ROOT/scripts/a71-install.sh" "$TARGET_KIND" ${TARGET_DEV:+"$TARGET_DEV"}
else
    sudo env A71_ROOTFS="$OUT" "$ROOT/scripts/a71-install.sh" "$TARGET_KIND" ${TARGET_DEV:+"$TARGET_DEV"}
fi

if [ "$FLASH" = 1 ]; then
    msg ">> flash du noyau"
    if [ "$(id -u)" = 0 ]; then
        "$ROOT/scripts/a71-install.sh" boot
    else
        sudo "$ROOT/scripts/a71-install.sh" boot
    fi
fi

msg ">> terminé"
echo "   carte prête, noyau flashé (ou : ./scripts/a71-install.sh boot)"
echo "   démarre le téléphone puis : ssh root@172.16.42.1"
