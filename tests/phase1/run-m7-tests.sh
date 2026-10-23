#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  ECHEC %s (%s)\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "attendu [$2] obtenu [$3]"; }
CLOCK="$ROOT/rootfs/usr/local/sbin/a71-clock"
STATE="$TMP/state"; mkdir -p "$STATE"
printf '1600000000\n' >"$STATE/last-good-epoch"
A71_CLOCK_STATE_DIR="$STATE" "$CLOCK" status >/dev/null 2>&1
eq "epoch ancien refusé en status" 1 "$?"
printf '2000000000\n' >"$STATE/last-good-epoch"
A71_CLOCK_STATE_DIR="$STATE" "$CLOCK" save
eq "save retourne 0" 0 "$?"
eq "state mode 644" 644 "$(stat -c '%a' "$STATE/last-good-epoch")"
eq "state entier plausible" 1 "$(grep -Ec '^[0-9]{10}$' "$STATE/last-good-epoch")"
cp "$STATE/last-good-epoch" "$TMP/s1"; A71_CLOCK_STATE_DIR="$STATE" "$CLOCK" save; cp "$STATE/last-good-epoch" "$TMP/s2"
eq "save idempotent (même seconde)" 0 "$(cmp -s "$TMP/s1" "$TMP/s2"; echo $?)"
"$ROOT/scripts/sync-a71-time.sh" --help >/dev/null 2>&1
eq "sync-a71-time aide" 0 "$?"
FW=work/device-runtime/m7b/a630_sqe.fw
[ -f "$ROOT/../$FW" ] && eq "firmware final présent" 1 1 || eq "firmware final présent" 1 0
eq "firmware hash" 1c21b527d9183487cc550dabbb3f43e555df5a977a461934fc61f0635a9aa90c "$(sha256sum "$ROOT/../$FW" 2>/dev/null | awk '{print $1}')"
printf '\nResultat M7 : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
