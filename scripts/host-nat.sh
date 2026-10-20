#!/bin/sh
# host-nat.sh - share the PC's internet connection with the phone over USB.
#
# Run this on the PC (root) once the phone is booted and the USB network
# interface shows up (usually usb0, sometimes enp0s20u1):
#
#   sudo ./scripts/host-nat.sh usb0
#
# The phone gets 172.16.42.1, the PC 172.16.42.100-150 via DHCP.  With NAT the
# phone can reach the internet even if its Wi-Fi driver is not usable.
set -e

IFACE=${1:?usage: host-nat.sh <usb-interface>}
UPLINK=$(ip route show default | awk '{print $5; exit}')

[ -n "$UPLINK" ] || { echo "no default route on the host" >&2; exit 1; }

echo ">> NAT: $IFACE -> $UPLINK"
sysctl -q -w net.ipv4.ip_forward=1

# idempotent
iptables -t nat -C POSTROUTING -s 172.16.42.0/24 -o "$UPLINK" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 172.16.42.0/24 -o "$UPLINK" -j MASQUERADE
iptables -C FORWARD -i "$IFACE" -o "$UPLINK" -j ACCEPT 2>/dev/null || {
    iptables -A FORWARD -i "$IFACE" -o "$UPLINK" -j ACCEPT
    iptables -A FORWARD -i "$UPLINK" -o "$IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

echo ">> done. On the phone:"
echo "     ssh root@172.16.42.1"
echo "     ping 1.1.1.1"
