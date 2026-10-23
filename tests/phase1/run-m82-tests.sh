#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  ECHEC %s (%s)\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "attendu [$2] obtenu [$3]"; }
NET="$ROOT/rootfs/etc/init.d/a71-net"
HOST="$ROOT/scripts/host-usb-internet.sh"
eq "ECM gateway .1" 1 "$(grep -c '^A71_ECM_GW=10.71.0.1$' "$NET")"
eq "RNDIS fallback .2" 1 "$(grep -c '^A71_RNDIS_GW=172.16.42.2$' "$NET")"
eq "route principale usb1" 1 "$(grep -c 'via \$A71_ECM_GW dev usb1' "$NET")"
eq "adresse usb1 .2/30" 1 "$(grep -c 'A71_ECM_ADDR=10.71.0.2' "$NET")"
eq "aucun .127" 0 "$(grep -c '172.16.42.127' "$NET")"
eq "host ECM .1" 1 "$([ "$(grep -c '10.71.0.1/30' "$HOST")" -gt 0 ] && echo 1 || echo 0)"
eq "host source .2" 1 "$(grep -c '^PHONE_SRC=10.71.0.2$' "$HOST")"
eq "host pas .127" 0 "$(grep -c '172.16.42.127' "$HOST")"
mkdir -p "$TMP/bin"
cat >"$TMP/bin/ip" <<'EOI'
#!/bin/sh
case "$*" in
 *"-4 -o addr show"*) echo '2: fakeecm inet 10.71.0.1/30 brd 10.71.0.3 scope global fakeecm';;
 *"route show default"*) echo 'default via 192.0.2.1 dev fakeinet proto dhcp metric 100';;
 *"link show"*) exit 0;;
 *) exit 0;;
esac
EOI
cat >"$TMP/bin/ethtool" <<'EOE'
#!/bin/sh
echo 'driver: cdc_ether'
EOE
cat >"$TMP/bin/nft" <<'EON'
#!/bin/sh
exit 0
EON
chmod 755 "$TMP/bin/ip" "$TMP/bin/ethtool" "$TMP/bin/nft"
PATH="$TMP/bin:$PATH" "$HOST" check >"$TMP/check" 2>&1
eq "check ECM déterministe" 0 "$?"
eq "check ecm_ip .1" 1 "$(grep -c 'ecm_ip=10.71.0.1/30' "$TMP/check")"
PATH="$TMP/bin:$PATH" "$HOST" start --dry-run >"$TMP/plan" 2>&1
eq "dry-run ECM" 0 "$?"
eq "NAT source .2 uniquement" 2 "$(grep -c 'ip saddr 10.71.0.2' "$TMP/plan")"
"$ROOT/scripts/install-a71-host-ecm-persistence.sh" --help >/dev/null 2>&1
eq "install ECM aide" 0 "$?"
PATH="$TMP/bin:$PATH" "$ROOT/scripts/install-a71-host-ecm-persistence.sh" install --dry-run 2>/dev/null | grep -q 'ipv4.addresses 10.71.0.1/30'
eq "profil ECM .1" 0 "$?"
printf '\nResultat M8.2 : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
