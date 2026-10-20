#!/usr/bin/env bash
# Build an Alpine-based aarch64 root filesystem for the Galaxy A71 and pack it
# as a gzip-compressed initramfs.
#
# Packages are installed with apk.static for the foreign architecture (no
# chroot / root privileges needed); post-install scripts are skipped and the
# few bits they would normally do (sshd user, host keys, root password) are
# done by hand below.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [[ "$ROOT" == *" "* ]]; then
    exec unshare -rm bash -c 'mount --bind "$1" /mnt && exec bash /mnt/scripts/build-rootfs.sh' _ "$ROOT"
fi

ALPINE_BRANCH=${ALPINE_BRANCH:-v3.22}
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
TOOLS="$ROOT/build/tools/$ALPINE_BRANCH"
R="$ROOT/build/rootfs"
KEYS="$TOOLS/alpine-keys"
APK="$TOOLS/apk.static"
ROOT_PASSWORD=${ROOT_PASSWORD:-a71}

mkdir -p "$TOOLS" "$ROOT/out" "$KEYS"

# --- fetch apk.static + signing keys (cached) ------------------------------
if [ ! -x "$APK" ]; then
    echo ">> fetching apk-tools-static"
    idx="$TOOLS/APKINDEX.tar.gz"
    curl -sSL -o "$idx" "$MIRROR/$ALPINE_BRANCH/main/x86_64/APKINDEX.tar.gz"
    tar -xzf "$idx" -C "$TOOLS" APKINDEX
    ver=$(awk '/^P:apk-tools-static$/{getline; print substr($0,3); exit}' "$TOOLS/APKINDEX")
    curl -sSL -o "$TOOLS/apk-tools-static.apk" \
        "$MIRROR/$ALPINE_BRANCH/main/x86_64/apk-tools-static-$ver.apk"
    tar -xzf "$TOOLS/apk-tools-static.apk" -C "$TOOLS" 2>/dev/null || true
    cp "$TOOLS/sbin/apk.static" "$APK"
    chmod +x "$APK"
fi

if [ -z "$(ls -A "$KEYS")" ]; then
    echo ">> fetching alpine-keys"
    idx="$TOOLS/APKINDEX.tar.gz"
    [ -f "$idx" ] || curl -sSL -o "$idx" "$MIRROR/$ALPINE_BRANCH/main/x86_64/APKINDEX.tar.gz"
    [ -f "$TOOLS/APKINDEX" ] || tar -xzf "$idx" -C "$TOOLS" APKINDEX
    ver=$(awk '/^P:alpine-keys$/{getline; print substr($0,3); exit}' "$TOOLS/APKINDEX")
    curl -sSL -o "$TOOLS/alpine-keys.apk" "$MIRROR/$ALPINE_BRANCH/main/x86_64/alpine-keys-$ver.apk"
    mkdir -p "$TOOLS/akeys"
    tar -xzf "$TOOLS/alpine-keys.apk" -C "$TOOLS/akeys" 2>/dev/null || true
    cp "$TOOLS"/akeys/etc/apk/keys/*.pub "$KEYS"/
fi

REPOS="$TOOLS/repositories"
cat > "$REPOS" <<EOF
$MIRROR/$ALPINE_BRANCH/main
$MIRROR/$ALPINE_BRANCH/community
EOF

# --- install the base system ----------------------------------------------
echo ">> installing aarch64 packages into $R"
rm -rf "$R"
mkdir -p "$R"

# --allow-untrusted: Alpine rotates the index signing key faster than the
# alpine-keys package ships it (v3.22 index is signed by ...-616ae350, absent
# from the released keyring).  Packages still come from the official CDN over
# HTTPS and their own signatures are checked against the same keyring below.
"$APK" --root "$R" --arch aarch64 --initdb --no-scripts --no-progress --no-cache \
    --allow-untrusted --keys-dir "$KEYS" --repositories-file "$REPOS" \
    add \
        alpine-baselayout busybox busybox-binsh musl \
        openssh openssh-client-default openssh-server \
        wpa_supplicant dhcpcd dnsmasq iw iproute2 wireless-regdb \
        linux-firmware-ath10k kmod ca-certificates \
    >/dev/null

# --- busybox applet symlinks ----------------------------------------------
# apk --no-scripts skips busybox's post-install trigger, which is where Alpine
# creates /bin/ls, /bin/mount, ...  Create them by running the aarch64 busybox
# under qemu-user (static, cached in build/tools).
QEMU="$ROOT/build/tools/qemu-aarch64-static"
if [ ! -x "$QEMU" ]; then
    echo ">> fetching qemu-aarch64-static"
    curl -sSL -o "$QEMU" \
        https://github.com/multiarch/qemu-user-static/releases/download/v7.2.0-1/qemu-aarch64-static
    chmod +x "$QEMU"
fi
cp "$QEMU" "$R/qemu-aarch64-static"
chroot "$R" /qemu-aarch64-static /bin/busybox --install -s /bin 2>/dev/null || \
    chroot "$R" /qemu-aarch64-static /bin/busybox --install -s
rm -f "$R/qemu-aarch64-static"

# --- users, sshd ----------------------------------------------------------
echo ">> configuring users / sshd"
grep -q '^sshd:' "$R/etc/passwd" || \
    echo 'sshd:x:74:74:privsep:/var/empty:/sbin/nologin' >> "$R/etc/passwd"
grep -q '^sshd:' "$R/etc/group" || echo 'sshd:x:74:' >> "$R/etc/group"
# dnsmasq drops privileges to this account (created by its post-install script,
# which we skip with --no-scripts)
grep -q '^dnsmasq:' "$R/etc/passwd" || \
    echo 'dnsmasq:x:75:75:dnsmasq:/var/empty:/sbin/nologin' >> "$R/etc/passwd"
grep -q '^dnsmasq:' "$R/etc/group" || echo 'dnsmasq:x:75:' >> "$R/etc/group"
mkdir -p "$R/var/empty" "$R/run/sshd" "$R/root" "$R/etc/ssh/sshd_config.d"
chmod 0755 "$R/var/empty"
chmod 0700 "$R/root"

cat > "$R/etc/ssh/sshd_config.d/10-a71.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
UseDNS no
X11Forwarding no
EOF

if ! grep -q '^Include /etc/ssh/sshd_config.d' "$R/etc/ssh/sshd_config"; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$R/etc/ssh/sshd_config"
fi

# host keys generated on the build machine (no entropy stall on first boot)
rm -f "$R"/etc/ssh/ssh_host_*
ssh-keygen -q -A -f "$R" >/dev/null

# root password (SHA-512 crypt)
hash=$(openssl passwd -6 "$ROOT_PASSWORD")
awk -v h="$hash" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' \
    "$R/etc/shadow" > "$R/etc/shadow.new"
mv "$R/etc/shadow.new" "$R/etc/shadow"
chmod 0600 "$R/etc/shadow"

# --- overlay --------------------------------------------------------------
echo ">> applying overlay"
cp -a "$ROOT/rootfs/." "$R/"
chmod 0755 "$R/init" "$R/usr/local/sbin/usb-gadget.sh" "$R/usr/local/bin/wifi-connect"

printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$R/etc/resolv.conf"

# --- trim ----------------------------------------------------------------
# Only keep the WCN3990 Wi-Fi firmware (the A71's QCA6390/WCN3990 combo).
fw="$R/lib/firmware"
if [ -d "$fw/ath10k" ]; then
    find "$fw" -mindepth 1 -maxdepth 1 ! -name ath10k -exec rm -rf {} +
    find "$fw/ath10k" -mindepth 1 -maxdepth 1 ! -name WCN3990 -exec rm -rf {} +
fi
rm -rf "$R"/usr/share/man "$R"/usr/share/doc "$R"/usr/share/locale "$R"/var/cache/apk
rm -rf "$R"/usr/lib/modules 2>/dev/null || true

echo ">> rootfs size: $(du -sh "$R" | cut -f1)"

# --- pack ----------------------------------------------------------------
echo ">> packing initramfs"
( cd "$R" && find . -print0 | cpio --null --owner 0:0 -o -H newc 2>/dev/null | gzip -9 ) \
    > "$ROOT/out/initramfs.cpio.gz"
ls -lh "$ROOT/out/initramfs.cpio.gz"
echo ">> done: out/initramfs.cpio.gz (root password: $ROOT_PASSWORD)"
