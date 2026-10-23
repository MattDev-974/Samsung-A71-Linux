#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  ECHEC %s (%s)\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "attendu [$2] obtenu [$3]"; }
C="$ROOT/scripts/collect-a71-runtime-logs.sh"
make_fixture(){
  R=$1; mkdir -p "$R/etc" "$R/var/log/a71" "$R/root/.ssh" "$R/etc/ssh"
  printf '3.22.7\n' >"$R/etc/alpine-release"
  ln -s /sbin/init "$R/init"
  printf 'early\n' >"$R/var/log/a71/early.txt"
  printf 'late60\n' >"$R/var/log/a71/late-60.txt"
  printf 'late90\n' >"$R/var/log/a71/late-90.txt"
  printf 'dmesg\n' >"$R/var/log/a71/dmesg-early.txt"
  ssh-keygen -q -t ed25519 -N '' -f "$TMP/key" >/dev/null 2>&1
  cat "$TMP/key.pub" >"$R/root/.ssh/authorized_keys"
  cp "$TMP/key.pub" "$R/etc/ssh/ssh_host_ed25519_key.pub"
}
make_fixture "$TMP/r1"
"$C" --rootfs "$TMP/r1" --output "$TMP/out1" >"$TMP/log1" 2>&1
eq "collecte valide -> 0" 0 "$?"
eq "early copie" 1 "$([ -f "$TMP/out1/early.txt" ] && echo 1 || echo 0)"
eq "late-90 copie" 1 "$([ -f "$TMP/out1/late-90.txt" ] && echo 1 || echo 0)"
eq "authorized absent" 0 "$([ -e "$TMP/out1/authorized_keys" ] && echo 1 || echo 0)"
eq "private key absente" 0 "$(grep -RIl 'PRIVATE KEY' "$TMP/out1" 2>/dev/null | wc -l | tr -d ' ')"
eq "metadonnees auth" 1 "$(grep -c '^lines=1$' "$TMP/out1/ssh-metadata.txt")"
eq "manifeste" 0 "$(cd "$TMP/out1" && sha256sum -c manifest.sha256 >/dev/null 2>&1; echo $?)"
make_fixture "$TMP/r2"; printf 'PRIVATE KEY\n' >>"$TMP/r2/var/log/a71/early.txt"
"$C" --rootfs "$TMP/r2" --output "$TMP/out2" >/dev/null 2>&1
eq "secret dans journal refuse" 1 "$?"
make_fixture "$TMP/r3"; rm -f "$TMP/r3/init"
"$C" --rootfs "$TMP/r3" --output "$TMP/out3" >/dev/null 2>&1
eq "init absent refuse" 1 "$?"
"$C" --rootfs "$TMP/absent" --output "$TMP/out4" >/dev/null 2>&1
eq "rootfs absent refuse" 1 "$?"
mkdir -p "$TMP/out5"; touch "$TMP/out5/x"
"$C" --rootfs "$TMP/r1" --output "$TMP/out5" >/dev/null 2>&1
eq "sortie non vide refusee" 1 "$?"
printf '\nResultat collecte : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
