#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  ECHEC %s (%s)\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "attendu [$2] obtenu [$3]"; }
NET="$ROOT/rootfs/etc/init.d/a71-net"
eq "gateway .2 dans a71-net" 1 "$(grep -c '^A71_GATEWAY=172.16.42.2$' "$NET")"
eq "route usb0 via gateway" 1 "$(grep -c 'via \$A71_GATEWAY dev usb0' "$NET")"
eq "aucune .127 dans a71-net" 0 "$(grep -c '172.16.42.127' "$NET")"
eq "aucune route par défaut usb1" 0 "$(grep -c 'default via .* dev usb1' "$NET")"
eq "host script statique .2" 1 "$([ "$(grep -c '172.16.42.2/24' "$ROOT/scripts/host-usb-internet.sh")" -gt 0 ] && echo 1 || echo 0)"
eq "host script sans .127" 0 "$(grep -c '172.16.42.127' "$ROOT/scripts/host-usb-internet.sh")"
# check déterministe du plan host avec faux ip/nft
mkdir -p "$TMP/bin"
cat >"$TMP/bin/ip" <<'EOI'
#!/bin/sh
case "$*" in
 *"-4 -o addr show"*) echo '2: fakeusb inet 172.16.42.2/24 brd 172.16.42.255 scope global fakeusb';;
 *"route show default"*) echo 'default via 192.0.2.1 dev fakeinet proto dhcp metric 100';;
 *) exit 0;;
esac
EOI
cat >"$TMP/bin/nft" <<'EON'
#!/bin/sh
exit 0
EON
chmod 755 "$TMP/bin/ip" "$TMP/bin/nft"
PATH="$TMP/bin:$PATH" "$ROOT/scripts/host-usb-internet.sh" check >"$TMP/check" 2>&1
eq "check hôte statique" 0 "$?"
eq "check usb_ip .2" 1 "$(grep -c 'usb_ip=172.16.42.2/24' "$TMP/check")"
PATH="$TMP/bin:$PATH" "$ROOT/scripts/host-usb-internet.sh" start --dry-run >"$TMP/plan" 2>&1
eq "dry-run NAT" 0 "$?"
eq "NAT restreint 172.16.42.0/24" 2 "$(grep -c 'ip saddr 172.16.42.0/24' "$TMP/plan")"
"$ROOT/scripts/install-a71-host-persistence.sh" --help >/dev/null 2>&1
eq "install persistence aide" 0 "$?"
PATH="$TMP/bin:$PATH" "$ROOT/scripts/install-a71-host-persistence.sh" install --dry-run 2>/dev/null | grep -q 'ipv4.addresses 172.16.42.2/24'
eq "profil NM statique .2" 0 "$?"
printf '\nResultat M8.1 : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
