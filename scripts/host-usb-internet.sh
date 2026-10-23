#!/bin/bash
# NAT IPv4 dédié ECM A71 : 10.71.0.0/30 -> Internet. Root requis pour start/stop.
set -Eeuo pipefail
TABLE=a71_usb
STATE=/var/lib/a71-usb-internet.state
ECM_NET=10.71.0.0/30
PHONE_SRC=10.71.0.2
say(){ printf 'host-usb-internet: %s\n' "$*" >&2; }
die(){ say "$1"; exit "${2:-1}"; }
usage(){ echo "usage: $0 check|start|status|stop|verify [--dry-run]"; }
MODE=${1:-}; shift || true
DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
case "$MODE" in check|start|status|stop|verify) ;; -h|--help) usage; exit 0 ;; *) usage; exit 2 ;; esac
command -v ip >/dev/null || die "ip absent" 3
command -v nft >/dev/null || die "nft absent" 3
ECM_IF=${A71_ECM_IF:-$(ip -4 -o addr show 2>/dev/null | awk '$4 == "10.71.0.1/30" {print $2; exit}')}
[ -n "$ECM_IF" ] || die "interface ECM 10.71.0.1/30 introuvable" 4
[ "$(ip link show "$ECM_IF" | grep -c cdc 2>/dev/null || true)" -ge 0 ]
DRIVER=$(ethtool -i "$ECM_IF" 2>/dev/null | awk -F': ' '/^driver:/{print $2; exit}')
[ "$DRIVER" = "cdc_ether" ] || die "interface ECM non cdc_ether: ${DRIVER:-inconnu}" 4
mapfile -t DEFAULTS < <(ip route show default | awk '$1=="default" && $3 !~ /^(10\.71\.0\.|172\.16\.(42|43)\.)/ {print $5, $7}' | sort -k2n)
[ "${#DEFAULTS[@]}" -ge 1 ] || die "aucune route Internet hors USB" 4
INET_IF=$(printf '%s\n' "${DEFAULTS[0]}" | awk '{print $1}')
UNIQ=$(printf '%s\n' "${DEFAULTS[@]}" | awk '{print $1}' | sort -u | wc -l)
[ "$UNIQ" -eq 1 ] || die "interface Internet ambiguë" 4
FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
USB_IP=$(ip -4 -o addr show dev "$ECM_IF" 2>/dev/null | awk '$4 ~ /^10\.71\.0\./ {print $4; exit}')
PLAN=$(cat <<EOP
table=$TABLE
ecm_if=$ECM_IF
ecm_ip=${USB_IP:-absent}
internet_if=$INET_IF
ecm_net=$ECM_NET
phone_source=$PHONE_SRC
ip_forward_actuel=$FWD
EOP
)
if [ "$MODE" = check ]; then echo "$PLAN"; exit 0; fi
if [ "$MODE" = status ]; then nft list table ip "$TABLE" 2>/dev/null || { echo "absent"; exit 1; }; exit 0; fi
if [ "$MODE" = verify ]; then
    ip -4 -o addr show dev "$ECM_IF" | grep -q '10.71.0.1/30' || { echo "IP ECM .1 absente"; exit 1; }
    nft list table ip "$TABLE" >/dev/null 2>&1 || { echo "table A71 absente"; exit 1; }
    [ "$(sysctl -n net.ipv4.ip_forward)" = 1 ] || { echo "forwarding inactif"; exit 1; }
    echo "verify_ok ecm_if=$ECM_IF ecm_ip=10.71.0.1/30 table=$TABLE"
    exit 0
fi
if [ "$MODE" = stop ]; then
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -q 'Status: active'; then
        ufw --force route delete allow in on "$ECM_IF" out on "$INET_IF" from "$PHONE_SRC" >/dev/null 2>&1 || true
    fi
    nft delete table ip "$TABLE" 2>/dev/null || true
    if [ -f "$STATE" ]; then
        saved=$(cat "$STATE" 2>/dev/null || echo "")
        [ "$saved" = 0 ] && sysctl -w net.ipv4.ip_forward=0 >/dev/null || true
        [ "$saved" = 1 ] && sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
        rm -f "$STATE"
    fi
    say "règles A71 ECM supprimées"
    exit 0
fi
nftfile=$(mktemp /tmp/a71-nft.XXXXXX); trap 'rm -f "$nftfile"' EXIT
cat >"$nftfile" <<EON
table ip $TABLE {
  chain forward {
    type filter hook forward priority -10; policy accept;
    ct state established,related accept
    ip saddr $PHONE_SRC iifname "$ECM_IF" oifname "$INET_IF" accept
    ip daddr $PHONE_SRC oifname "$ECM_IF" ct state established,related accept
  }
  chain postrouting {
    type nat hook postrouting priority 99; policy accept;
    ip saddr $PHONE_SRC oifname "$INET_IF" masquerade
  }
}
EON
if [ "$DRY" = 1 ]; then cat "$nftfile"; exit 0; fi
[ "$(id -u)" -eq 0 ] || die "start nécessite root" 5
ip addr replace 10.71.0.1/30 dev "$ECM_IF"
ip -4 -o addr show dev "$ECM_IF" | grep -q '10.71.0.1/30' || die "adresse ECM .1 non appliquée" 6
printf '%s\n' "$FWD" >"$STATE"; chmod 600 "$STATE"
[ "$FWD" = 1 ] || sysctl -w net.ipv4.ip_forward=1 >/dev/null
nft delete table ip "$TABLE" 2>/dev/null || true
nft -f "$nftfile"
nft list table ip "$TABLE" >/dev/null
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -q 'Status: active'; then
    if ! ufw status 2>/dev/null | grep -q "$PHONE_SRC"; then
        ufw --force route allow in on "$ECM_IF" out on "$INET_IF" from "$PHONE_SRC" comment 'A71 ECM M8.2' >/dev/null
    fi
fi
say "NAT ECM actif: $ECM_IF (10.71.0.1) -> $INET_IF pour $PHONE_SRC"
