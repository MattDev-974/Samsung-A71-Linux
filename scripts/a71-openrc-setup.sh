#!/bin/sh
# a71-openrc-setup.sh - bascule le système vers un vrai Alpine/OpenRC.
#
# À exécuter SUR le téléphone, en root :
#   sh /root/a71-openrc-setup.sh
#
# Installe OpenRC, convertit le script d'init en services, et fait de busybox
# init (/etc/inittab + openrc) le PID 1 au prochain démarrage.
# L'ancien script reste disponible en secours (/init.a71-rescue).
set -eu

[ "$(id -u)" = 0 ] || { echo "root requis" >&2; exit 1; }

say() { printf '\033[1;36m>> %s\033[0m\n' "$*"; }

say "installation d'OpenRC et des outils Alpine"
apk update >/dev/null 2>&1 || true
apk add --no-cache openrc alpine-conf chrony ca-certificates 2>&1 | tail -6

# ---------------------------------------------------------------- services
say "service a71-usb (gadget réseau USB + dnsmasq)"
cat > /etc/init.d/a71-usb <<'EOF'
#!/sbin/openrc-run
description="Galaxy A71 USB gadget network (RNDIS + ECM) and DHCP server"

depend() {
    need localmount
    after devfs
    provide net
    before sshd
}

start() {
    ebegin "Starting USB gadget network"
    /usr/local/sbin/usb-gadget.sh start >/dev/null 2>&1
    eend $?
}
EOF
chmod +x /etc/init.d/a71-usb

say "service a71-net (adresses, dnsmasq, route par défaut)"
cat > /etc/init.d/a71-net <<'EOF'
#!/sbin/openrc-run
description="A71 USB network addressing, DHCP server and default route"

depend() {
    need a71-usb
    before sshd
    provide net
}

setup() {
    conf=/run/dnsmasq-usb.conf
    : > "$conf"
    found=0
    for sysif in /sys/class/net/usb*; do
        [ -e "$sysif" ] || continue
        dev=${sysif##*/}
        case "$dev" in
            usb0) addr=172.16.42.1 ;;
            usb1) addr=172.16.43.1 ;;
            *) continue ;;
        esac
        net=${addr%.*}
        ip link set "$dev" up 2>/dev/null
        ip addr show dev "$dev" 2>/dev/null | grep -q "inet $addr/" || \
            ip addr add "$addr/24" dev "$dev" 2>/dev/null
        {
            echo "interface=$dev"
            echo "dhcp-range=$dev,$net.100,$net.150,255.255.255.0,24h"
            echo "dhcp-option=$dev,3,$addr"
            echo "dhcp-option=$dev,6,1.1.1.1,9.9.9.9"
        } >> "$conf"
        found=1
    done
    [ "$found" = 1 ]
}

start() {
    ebegin "Configuring USB network"
    i=0
    while [ $i -lt 60 ]; do
        setup && break
        i=$((i + 1)); sleep 1
    done
    [ $i -lt 60 ] || { eend 1 "no USB interface"; return 1; }

    if ! pidof dnsmasq >/dev/null 2>&1; then
        {
            echo "bind-interfaces"
            echo "user=root"
            echo "port=0"
            echo "dhcp-leasefile=/run/dnsmasq.leases"
            echo "pid-file=/run/dnsmasq.pid"
            echo "log-facility=/run/dnsmasq.log"
            cat /run/dnsmasq-usb.conf
        } > /run/dnsmasq.conf
        dnsmasq --conf-file=/run/dnsmasq.conf || { eend 1 "dnsmasq"; return 1; }
    fi
    eend 0
}

stop() {
    ebegin "Stopping USB network"
    kill $(cat /run/dnsmasq.pid 2>/dev/null) 2>/dev/null
    eend 0
}
EOF
chmod +x /etc/init.d/a71-net

say "service a71-route (route par défaut vers le PC, auto-réparante)"
cat > /etc/init.d/a71-route <<'EOF'
#!/sbin/openrc-run
description="Default route through the PC (internet sharing)"

depend() {
    need a71-net
    after a71-net
}

start() {
    ebegin "Default route through the PC"
    (
        while :; do
            if ! ip route show default 2>/dev/null | grep -q '^default'; then
                peer=$(awk '$3 ~ /^172\.16\.42\./ {print $3; exit}' /run/dnsmasq.leases 2>/dev/null)
                if [ -n "$peer" ]; then
                    ip route replace default via "$peer" dev usb0 2>/dev/null
                else
                    peer=$(awk '$3 ~ /^172\.16\.43\./ {print $3; exit}' /run/dnsmasq.leases 2>/dev/null)
                    [ -n "$peer" ] && ip route replace default via "$peer" dev usb1 2>/dev/null
                fi
            fi
            sleep 10
        done
    ) &
    echo $! > /run/a71-route.pid
    eend 0
}

stop() {
    [ -f /run/a71-route.pid ] && kill "$(cat /run/a71-route.pid)" 2>/dev/null
    rm -f /run/a71-route.pid
}
EOF
chmod +x /etc/init.d/a71-route

say "enregistrement des services"
rc-update add devfs sysinit 2>/dev/null || true
rc-update add dmesg sysinit 2>/dev/null || true
rc-update add mdev sysinit 2>/dev/null || true
rc-update add hwdrivers sysinit 2>/dev/null || true
rc-update add modules boot 2>/dev/null || true
rc-update add sysctl boot 2>/dev/null || true
rc-update add hostname boot 2>/dev/null || true
rc-update add bootmisc boot 2>/dev/null || true
rc-update add syslog boot 2>/dev/null || true
rc-update add swap boot 2>/dev/null || true
rc-update add a71-usb boot 2>/dev/null || true
rc-update add a71-net default 2>/dev/null || true
rc-update add a71-route default 2>/dev/null || true
rc-update add sshd default 2>/dev/null || true
rc-update add chronyd default 2>/dev/null || true
rc-update add crond default 2>/dev/null || true
rc-update add local default 2>/dev/null || true

# ---------------------------------------------------------------- inittab
if [ ! -f /etc/inittab ]; then
    say "écriture de /etc/inittab"
    cat > /etc/inittab <<'EOF'
# /etc/inittab
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# consoles
tty1::respawn:/sbin/getty 38400 tty1
ttyMSM0::respawn:/sbin/getty -L 115200 ttyMSM0 vt100

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
::restart:/sbin/init
EOF
fi

# --------------------------------------------------------------- init swap
if [ ! -f /init.a71-rescue ]; then
    say "mise en place du nouveau /init (busybox init + openrc)"
    cp /init /init.a71-rescue
    cat > /init <<'EOF'
#!/bin/sh
# /init - PID 1 : on laisse busybox init prendre la main. Il lit /etc/inittab
# et lance OpenRC (runlevels sysinit / boot / default).
# IMPORTANT : PID 1 ne doit JAMAIS sortir, sinon panique du noyau et
# redémarrage en boucle. Ne jamais terminer par un "wait" qui peut retourner.
# L'ancien script reste disponible dans /init.a71-rescue.
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
exec /sbin/init
EOF
    chmod +x /init
fi

say "filet de sécurité (si sshd ne démarre pas)"
mkdir -p /etc/local.d
cat > /etc/local.d/10-a71-rescue.start <<'EOF'
#!/bin/sh
# Si, 90 s après le démarrage, sshd n'écoute pas, on repasse sur l'ancien init
# (réseau + sshd manuels). Le sous-shell ne bloque pas le service local.
(
    sleep 90
    if ! pidof sshd >/dev/null 2>&1; then
        echo "a71: sshd absent, init de secours" > /dev/kmsg
        /sbin/a71-system
    fi
) &
exit 0
EOF
chmod +x /etc/local.d/10-a71-rescue.start

say "état des runlevels"
rc-update show 2>/dev/null | head -20

say "terminé — redémarre pour basculer sur OpenRC"
