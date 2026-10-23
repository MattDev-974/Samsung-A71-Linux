#!/bin/bash
# Profil NetworkManager persistant pour l'interface USB A71.
set -Eeuo pipefail
IFACE=${A71_USB_IF:-enp48s0f4u1}
PROFILE=a71-usb
say(){ printf 'a71-host-persistence: %s\n' "$*" >&2; }
die(){ say "$1"; exit "${2:-1}"; }
usage(){ echo "usage: $0 install|uninstall|status [--dry-run]"; }
STATE=/var/lib/a71-host-persistence.state
MODE=${1:-}; shift || true
DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
case "$MODE" in install|uninstall|status) ;; -h|--help) usage; exit 0 ;; *) usage; exit 2 ;; esac
command -v nmcli >/dev/null || die "nmcli absent" 3
ip link show "$IFACE" >/dev/null 2>&1 || die "interface $IFACE absente" 4
# Refuser une interface qui porte déjà un autre rôle que le lien A71.
ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | grep -qvE '^(172\.16\.42\.2/24)?$' && \
    ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -q '172\.16\.4[23]\.' || true
if [ "$MODE" = status ]; then
    nmcli -t -f NAME,DEVICE,TYPE connection show 2>/dev/null | grep "^$PROFILE:$IFACE:" || echo "profil absent"
    ip -4 -o addr show dev "$IFACE" 2>/dev/null || true
    [ -f "$STATE" ] && cat "$STATE" || true
    exit 0
fi
if [ "$MODE" = uninstall ] && [ "$DRY" = 1 ]; then echo "nmcli connection delete $PROFILE"; exit 0; fi
if [ "$MODE" = install ] && [ "$DRY" = 1 ]; then
    echo "nmcli connection add type ethernet ifname $IFACE con-name $PROFILE ipv4.method manual ipv4.addresses 172.16.42.2/24 ipv4.never-default yes ipv6.method ignore connection.autoconnect yes connection.autoconnect-priority 100"
    exit 0
fi
[ "$(id -u)" -eq 0 ] || die "install/uninstall nécessitent root" 5
if [ "$MODE" = uninstall ]; then
    if [ "$DRY" = 1 ]; then echo "nmcli connection delete $PROFILE"; exit 0; fi
    if [ -f "$STATE" ]; then
        old=$(awk -F= '$1=="old_name"{print $2}' "$STATE")
        [ -n "$old" ] && nmcli connection modify "$old" connection.autoconnect yes >/dev/null 2>&1 || true
        rm -f "$STATE"
    fi
    nmcli connection down "$PROFILE" >/dev/null 2>&1 || true
    nmcli connection delete "$PROFILE" >/dev/null 2>&1 || true
    say "profil $PROFILE supprimé ; autoconnect de l'ancien profil restauré"
    exit 0
fi
if [ "$DRY" = 1 ]; then
    echo "nmcli connection add type ethernet ifname $IFACE con-name $PROFILE ipv4.method manual ipv4.addresses 172.16.42.2/24 ipv4.never-default yes ipv6.method ignore connection.autoconnect yes connection.autoconnect-priority 100"
    exit 0
fi
old_name=""
while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = "$PROFILE" ] && continue
    iface=$(nmcli -g connection.interface-name connection show "$name" 2>/dev/null || true)
    [ "$iface" = "$IFACE" ] && { old_name=$name; break; }
done < <(nmcli -t -f NAME connection show 2>/dev/null)
if [ -n "$old_name" ]; then
    old_ac=$(nmcli -g connection.autoconnect connection show "$old_name" 2>/dev/null || echo yes)
    printf 'old_name=%s\nold_autoconnect=%s\n' "$old_name" "$old_ac" >"$STATE"
    chmod 600 "$STATE"
    nmcli connection modify "$old_name" connection.autoconnect no >/dev/null
    say "ancien profil $old_name : autoconnect désactivé (sauvegardé)"
fi
if nmcli -t -f NAME connection show | grep -qx "$PROFILE"; then
    nmcli connection delete "$PROFILE" >/dev/null
fi
nmcli connection add type ethernet ifname "$IFACE" con-name "$PROFILE" \
    ipv4.method manual ipv4.addresses 172.16.42.2/24 ipv4.never-default yes \
    ipv6.method ignore connection.autoconnect yes connection.autoconnect-priority 100 >/dev/null
nmcli connection up "$PROFILE" >/dev/null
sleep 1
ip -4 -o addr show dev "$IFACE" | grep -q '172.16.42.2/24' || die "profil créé mais IP .2 absente" 6
say "profil $PROFILE actif sur $IFACE (172.16.42.2/24)"
