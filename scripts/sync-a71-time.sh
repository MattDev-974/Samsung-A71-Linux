#!/bin/bash
# Synchronisation ponctuelle de l'horloge A71 depuis le PC, sans RTC.
set -Eeuo pipefail
HOST=root@172.16.42.1
KEY=${A71_SSH_KEY:-$HOME/.ssh/a71_ed25519}
KNOWN=${A71_KNOWN_HOSTS:-$HOME/.ssh/a71_known_hosts}
MIN_EPOCH=1735689600
SSH=(ssh -F /dev/null -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
     -o ConnectTimeout=10 -o UserKnownHostsFile="$KNOWN" -o StrictHostKeyChecking=accept-new "$HOST")
say(){ printf 'sync-a71-time: %s\n' "$*" >&2; }
die(){ say "$1"; exit "${2:-1}"; }
usage(){ echo "usage: $0 --check | --apply"; }
[ $# -eq 1 ] || { usage; exit 2; }
case "$1" in --check) MODE=check ;; --apply) MODE=apply ;; -h|--help) usage; exit 0 ;; *) usage; exit 2 ;; esac
[ -r "$KEY" ] || die "clé absente: $KEY" 3
[ -f "$KNOWN" ] || : >"$KNOWN"
local_epoch=$(date -u +%s)
[ "$local_epoch" -ge "$MIN_EPOCH" ] || die "heure PC invalide/antérieure à 2025" 4
[[ "$local_epoch" =~ ^[0-9]+$ ]] || die "epoch PC invalide" 4
remote=$("${SSH[@]}" 'id -u; uname -r; cat /etc/alpine-release; findmnt -n -o SOURCE,FSTYPE,OPTIONS /; readlink /init' 2>/dev/null) || die "SSH/identité indisponible" 5
echo "$remote" | grep -qx '0' || die "session non root" 5
echo "$remote" | grep -q '^6\.18\.0-rc1-a71+' || die "noyau inattendu" 5
echo "$remote" | grep -q '^3\.22\.7$' || die "Alpine inattendue" 5
echo "$remote" | grep -q '^/dev/mmcblk2p1 ext4 rw' || die "racine non conforme" 5
echo "$remote" | grep -qx '/sbin/init' || die "/init non conforme" 5
remote_epoch=$("${SSH[@]}" 'date -u +%s' 2>/dev/null) || die "date distante impossible" 5
[[ "$remote_epoch" =~ ^[0-9]+$ ]] || die "epoch distant invalide" 5
say "PC=$local_epoch remote=$remote_epoch"
if [ "$remote_epoch" -ge "$local_epoch" ]; then
    say "aucun recul: heure distante déjà >= heure PC"
    [ "$MODE" = check ] && exit 0 || die "recul refusé" 6
fi
[ "$MODE" = check ] && { say "appliquerait $local_epoch"; exit 0; }
"${SSH[@]}" "date -u -s '@$local_epoch' >/dev/null && /usr/local/sbin/a71-clock save" || die "application horloge impossible" 7
after=$("${SSH[@]}" 'date -u +%s; cat /var/lib/a71-clock/last-good-epoch 2>/dev/null || true; id -u; rc-service a71-usb status >/dev/null 2>&1; echo usb_rc=$?; rc-service a71-net status >/dev/null 2>&1; echo net_rc=$?; rc-service sshd status >/dev/null 2>&1; echo ssh_rc=$?' 2>/dev/null) || die "vérification post-application impossible" 8
echo "$after" | head -1 | grep -Eq '^[0-9]{10}$' || die "heure post-application invalide" 8
echo "$after" | grep -q 'usb_rc=0' || die "a71-usb non started" 8
echo "$after" | grep -q 'net_rc=0' || die "a71-net non started" 8
echo "$after" | grep -q 'ssh_rc=0' || die "sshd non started" 8
say "heure appliquée et vérifiée"
sleep 60
"${SSH[@]}" 'date -u +%s; id -u' >/dev/null || die "SSH perdu après 60s" 8
say "USB/SSH toujours disponibles après 60s"
