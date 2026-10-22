#!/bin/sh
# build-base.sh - construit le rootfs de base aarch64 de façon reproductible.
#
# Aucun privilège root, aucun émulateur : les paquets Alpine sont installés
# avec apk.static pour l'architecture étrangère (scripts post-install sautés),
# puis les étapes que ces scripts feraient sont rejouées explicitement ici.
#
#   ./scripts/build-base.sh [sortie.tar.gz]
#
# Résultat par défaut : out/a71-base.tar.gz
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ALPINE_BRANCH=${ALPINE_BRANCH:-v3.22}
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
ARCH=aarch64
OUT=${1:-$ROOT/out/a71-base.tar.gz}
TOOLS="$ROOT/build/tools/$ALPINE_BRANCH"
R="$ROOT/build/base-$ARCH"
KEYS="$TOOLS/alpine-keys"
APK="$TOOLS/apk.static"

PKGS="alpine-base openrc openssh chrony tzdata nano htop curl btop sudo
      ca-certificates dnsmasq musl-locales ncurses-terminfo e2fsprogs
      util-linux e2fsprogs-extra"

say() { printf '\033[1;36m>> %s\033[0m\n' "$*"; }

mkdir -p "$TOOLS" "$(dirname "$OUT")" "$KEYS"

# --- apk.static (hôte x86_64) + clés --------------------------------------
if [ ! -x "$APK" ]; then
    say "récupération de apk.static"
    idx="$TOOLS/APKINDEX.tar.gz"
    curl -sSL -o "$idx" "$MIRROR/$ALPINE_BRANCH/main/x86_64/APKINDEX.tar.gz"
    tar -xzf "$idx" -C "$TOOLS" APKINDEX
    ver=$(awk '/^P:apk-tools-static$/{getline; print substr($0,3); exit}' "$TOOLS/APKINDEX")
    curl -sSL -o "$TOOLS/apk-tools-static.apk" \
        "$MIRROR/$ALPINE_BRANCH/main/x86_64/apk-tools-static-$ver.apk"
    tar -xzf "$TOOLS/apk-tools-static.apk" -C "$TOOLS" 2>/dev/null || true
    cp "$TOOLS/sbin/apk.static" "$APK"; chmod +x "$APK"
fi
if [ -z "$(ls -A "$KEYS" 2>/dev/null || true)" ]; then
    say "récupération des clés"
    ver=$(awk '/^P:alpine-keys$/{getline; print substr($0,3); exit}' "$TOOLS/APKINDEX")
    curl -sSL -o "$TOOLS/alpine-keys.apk" "$MIRROR/$ALPINE_BRANCH/main/x86_64/alpine-keys-$ver.apk"
    mkdir -p "$TOOLS/akeys"
    tar -xzf "$TOOLS/alpine-keys.apk" -C "$TOOLS/akeys" 2>/dev/null || true
    cp "$TOOLS"/akeys/etc/apk/keys/*.pub "$KEYS"/
fi

# --- paquets ---------------------------------------------------------------
say "installation des paquets $ARCH dans $R"
rm -rf "$R"; mkdir -p "$R"
"$APK" --root "$R" --arch "$ARCH" --initdb --allow-untrusted -U --no-scripts \
    --keys-dir "$KEYS" \
    --repository "$MIRROR/$ALPINE_BRANCH/main" \
    --repository "$MIRROR/$ALPINE_BRANCH/community" \
    add $PKGS 2>&1 | tail -3

# --- rejeu des scripts post-install ---------------------------------------
say "post-installation (utilisateurs, runlevels, dépôts)"
mkdir -p "$R/dev" "$R/proc" "$R/sys" "$R/run" "$R/tmp" "$R/var/log" "$R/var/empty" "$R/mnt/sd"
chmod 1777 "$R/tmp"

# utilisateur sshd (privilege separation)
grep -q '^sshd:' "$R/etc/passwd" || \
    echo 'sshd:x:74:74:privsep:/var/empty:/sbin/nologin' >> "$R/etc/passwd"
grep -q '^sshd:' "$R/etc/group" || echo 'sshd:x:74:' >> "$R/etc/group"

# utilisateur chrony (créé par le script post-install du paquet, sauté ici)
grep -q '^chrony:' "$R/etc/passwd" || \
    echo 'chrony:x:101:101:chrony:/var/lib/chrony:/sbin/nologin' >> "$R/etc/passwd"
grep -q '^chrony:' "$R/etc/group" || echo 'chrony:101:' >> "$R/etc/group"
mkdir -p "$R/var/lib/chrony"

# dépôts + clés dans l'image
mkdir -p "$R/etc/apk/keys"
cp "$KEYS"/*.pub "$R/etc/apk/keys"/ 2>/dev/null || true
cat > "$R/etc/apk/repositories" <<EOF
$MIRROR/$ALPINE_BRANCH/main
$MIRROR/$ALPINE_BRANCH/community
EOF

# runlevels OpenRC
for d in sysinit boot default shutdown; do mkdir -p "$R/etc/runlevels/$d"; done
link() { ln -sf "/etc/init.d/$2" "$R/etc/runlevels/$1/$2"; }
for s in devfs dmesg hwdrivers; do link sysinit "$s"; done
for s in bootmisc hostname modules sysctl swap syslog; do link boot "$s"; done
for s in sshd chronyd crond local a71-usb a71-net a71-route a71-clock; do link default "$s"; done

# liens busybox (créés par le script post-install du paquet, sauté ici)
say "création des liens busybox"
while IFS="$(printf '\t')" read -r name target; do
    [ -n "$name" ] || continue
    rel=${name#./}
    mkdir -p "$R/$(dirname "$rel")"
    ln -sf "$target" "$R/$rel"
done < "$ROOT/scripts/data/busybox-links.txt"

# --- surcouche A71 --------------------------------------------------------
say "surcouche A71"
cp -a "$ROOT/base/." "$R/"

# OpenRC ignore silencieusement les scripts non executables : forcer les modes
chmod 0755 "$R"/etc/init.d/* 2>/dev/null || true
chmod 0755 "$R"/etc/local.d/*.start 2>/dev/null || true
chmod 0755 "$R"/init "$R"/usr/local/sbin/* "$R"/usr/local/bin/* "$R"/sbin/a71-system 2>/dev/null || true

# ntp par IP + makestep chrony
[ -f "$R/etc/chrony/chrony.conf" ] && {
    grep -q '^makestep' "$R/etc/chrony/chrony.conf" || echo 'makestep 1.0 3' >> "$R/etc/chrony/chrony.conf"
}

# locale
grep -q 'LANG=C.UTF-8' "$R/etc/profile" 2>/dev/null || \
    printf '\nexport LANG=C.UTF-8\nexport LC_ALL=C.UTF-8\n' >> "$R/etc/profile"

# certificats (CAfile attendu par OpenSSL)
mkdir -p "$R/etc/ssl/certs"
[ -e "$R/etc/ssl/cert.pem" ] || ln -sf certs/ca-certificates.crt "$R/etc/ssl/cert.pem"

# mot de passe root verrouillé par défaut (clé SSH / console via la config)
sed -i 's|^root:[^:]*:|root:*:|' "$R/etc/shadow"

# sshd par défaut : clé uniquement, locale UTF-8
cat > "$R/etc/ssh/sshd_config.d/10-a71.conf" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
UseDNS no
X11Forwarding no
StrictModes no
SetEnv LANG=C.UTF-8 LC_ALL=C.UTF-8
EOF

# modules au démarrage
grep -qx 'rtc-pm8xxx' "$R/etc/modules" 2>/dev/null || echo 'rtc-pm8xxx' >> "$R/etc/modules"

# version de l'image
cat > "$R/etc/a71-version" <<EOF
image=a71-base
alpine=$ALPINE_BRANCH
arch=$ARCH
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# --- archive reproductible ------------------------------------------------
say "création de l'archive $OUT"
(cd "$R" && find . -type f -o -type l | LC_ALL=C sort | cpio -o -H newc --quiet --owner=0:0 2>/dev/null) | \
    gzip -9n > "${OUT%.tar.gz}.cpio.gz"
tar --numeric-owner --owner=0 --group=0 --sort=name --mtime='2026-01-01 00:00:00Z' \
    -czf "$OUT" -C "$R" . 2>/dev/null
rm -f "${OUT%.tar.gz}.cpio.gz"
ls -lh "$OUT"
say "base prête : $OUT"
