#!/usr/bin/env bash
# shellcheck shell=bash
#
# run-i1-tests.sh - tests bouchonnes de scripts/write-sdcard.sh.
#
# Aucune commande de test n'ouvre un vrai /dev/sdX : le device est un fichier
# temporaire et toutes les commandes sensibles sont remplacees par des bouchons
# dans un PATH temporaire.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/scripts/write-sdcard.sh"
TMP=$(mktemp -d) || { echo "temporaire impossible" >&2; exit 1; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/reports"

PASS=0
FAIL=0
check_eq() {
    local desc=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf '  ok    %s\n' "$desc"
    else
        FAIL=$((FAIL + 1)); printf '  ECHEC %s (attendu [%s], obtenu [%s])\n' "$desc" "$expected" "$actual"
    fi
}
section() { printf '\n%s\n' "$*"; }

cat >"$BIN/lsblk" <<'EOF'
#!/bin/sh
[ "${STUB_LSBLK_FAIL:-0}" = 1 ] && exit 1
case " $* " in
  *" -P "*) if [ -n "${STUB_LSBLK_RAW+x}" ]; then RAW=$STUB_LSBLK_RAW; else RAW='NAME="sdd" MAJ:MIN="8:48" RM="1" RO="0" TYPE="disk" SIZE="31000000000" MODEL="TestCard" SERIAL="SN123" TRAN="usb" MOUNTPOINTS=""'; fi; printf '%s\n' "$RAW" ;;
  *" -o NAME,PKNAME "*) printf 'sdd1\tsdd\n' ;;
  *" -o NAME "*) printf 'sdd\nsdd1\n' ;;
  *) printf 'sdd\n' ;;
esac
EOF
cat >"$BIN/findmnt" <<'EOF'
#!/bin/sh
[ -n "${STUB_MOUNT:-}" ] && printf '%s\n' "$STUB_MOUNT" && exit 0
exit 1
EOF
cat >"$BIN/swapon" <<'EOF'
#!/bin/sh
[ -n "${STUB_SWAP:-}" ] && printf '%s\n' "$STUB_SWAP"
exit 0
EOF
cat >"$BIN/dmsetup" <<'EOF'
#!/bin/sh
[ -n "${STUB_DM:-}" ] && printf '%s\n' "$STUB_DM"
exit 0
EOF
cat >"$BIN/sfdisk" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = "-d" ] && {
  if [ -n "${STUB_SFDISK_TABLE+x}" ]; then printf '%s\n' "$STUB_SFDISK_TABLE"; else
    printf 'label: dos\n'
    printf 'label-id: 0xa71a71a7\n'
    printf 'unit: sectors\n'
    printf 'sector-size: 512\n'
    printf '\n'
    printf 'image1 : start= 2048, size= 2048, type=83\n'
  fi
  exit "${STUB_SFDISK_EXIT:-0}"
}; done
printf 'sfdisk %s\n' "$*" >>"${A71_STUB_LOG:-/dev/null}"
exit 0
EOF
cat >"$BIN/dumpe2fs" <<'EOF'
#!/bin/sh
printf 'dumpe2fs %s\n' "$*" >>"${A71_STUB_LOG:-/dev/null}"
printf 'Filesystem volume name:   %s\n' "${STUB_LABEL:-A71ROOT}"
printf 'Filesystem UUID:          11111111-2222-3333-4444-555555555555\n'
exit 0
EOF
cat >"$BIN/blkid" <<'EOF'
#!/bin/sh
printf 'blkid %s\n' "$*" >>"${A71_STUB_LOG:-/dev/null}"
printf '%s\n' "${STUB_FS_TYPE:-ext4}"
exit 0
EOF
cat >"$BIN/debugfs" <<'EOF'
#!/bin/sh
printf 'debugfs %s\n' "$*" >>"${A71_STUB_LOG:-/dev/null}"
case "$*" in
  *"stat /init"*)
    [ "${STUB_DEBUGFS_NO_INIT:-0}" = 1 ] && exit 1
    printf 'Inode: 1   Type: symlink    Mode:  0777\n'
    printf 'Fast link dest: "/sbin/init"\n' ;;
  *"stat /sbin/init"*)
    [ "${STUB_DEBUGFS_NO_INIT:-0}" = 1 ] && exit 1
    printf 'Inode: 2   Type: symlink    Mode:  0777\n' ;;
esac
exit 0
EOF
cat >"$BIN/dd" <<'EOF'
#!/bin/sh
printf 'dd %s\n' "$*" >>"${A71_STUB_LOG:-/dev/null}"
[ "${STUB_DD_FAIL:-0}" = 1 ] && exit 1
IF= OF= BS= COUNT=
for a in "$@"; do
  case "$a" in
    if=*) IF=${a#if=} ;;
    of=*) OF=${a#of=} ;;
    bs=*) BS=${a#bs=} ;;
    count=*) COUNT=${a#count=} ;;
    skip=*) SKIP=${a#skip=} ;;
  esac
done
[ -n "$IF" ] && [ -n "$OF" ] || exit 1
if [ "$IF" = "${A71_TEST_IMAGE_PATH:-}" ] && [ -n "${SKIP:-}" ]; then
  /usr/bin/dd if="$IF" of="$OF" bs="${BS:-512}" skip="$SKIP" count="${COUNT:-0}" status=none
  exit $?
fi
N=$(( ${COUNT:-2} * 1048576 ))
if [ "${STUB_BAD_READBACK:-0}" = 1 ] && [ "$IF" != "$OF" ]; then
  head -c "$N" /dev/zero >"$OF"
  exit 0
fi
if [ "$IF" = "${A71_TEST_DEVICE_PATH:-}" ]; then
  head -c "$N" "$IF" >"$OF"
else
  cp --sparse=always "$IF" "$OF"
fi
EOF
cat >"$BIN/umount" <<'EOF'
#!/bin/sh
printf 'umount %s\n' "$*" >>"${A71_STUB_LOG:-/dev/null}"
exit 0
EOF
for name in partprobe blockdev udevadm; do
    cat >"$BIN/$name" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >>"${A71_STUB_LOG:-/dev/null}"
[ "${STUB_REREAD_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
done
chmod 755 "$BIN"/*

IMAGE="$TMP/image.img"
truncate -s 2M "$IMAGE"
printf 'image-test\n' | dd of="$IMAGE" bs=1 conv=notrunc status=none
sha256sum "$IMAGE" | awk '{print $1"  image.img"}' >"$IMAGE.sha256"
FAKE="$TMP/fake-sdd"
truncate -s 31000000000 "$FAKE"
LOG="$TMP/stub.log"
: >"$LOG"

base_env() {
    env PATH="$BIN:/usr/bin:/bin" A71_STUB_LOG="$LOG" \
        A71_WRITE_TEST_MODE=1 A71_TEST_DEVICE_PATH="$FAKE" \
        A71_TEST_IMAGE_PATH="$IMAGE" TMPDIR="$TMP/write-tmp" "$@"
}
run_test() {
    mkdir -p "$TMP/write-tmp"
    base_env "$SCRIPT" --image "$IMAGE" --device /dev/sdd "$@" >"$TMP/out" 2>"$TMP/err"
    local rc=$?
    cp "$TMP/err" /tmp/i1-last-err 2>/dev/null || true
    if [ "${A71_I1_DEBUG:-0}" = 1 ]; then cat "$TMP/err" >&2; fi
    echo "$rc"
}
run_test_err() {
    mkdir -p "$TMP/write-tmp"
    base_env "$SCRIPT" --image "$IMAGE" --device /dev/sdd "$@" >"$TMP/out" 2>"$TMP/err"
    echo $?
    wc -c <"$TMP/err"
}
run_real() {
    env -u A71_WRITE_TEST_MODE -u A71_TEST_DEVICE_PATH PATH="$BIN:/usr/bin:/bin" \
        "$SCRIPT" --image "$IMAGE" --device /dev/sdd "$@" >/dev/null 2>&1
    echo $?
}

section "I1 : write-sdcard.sh (bouchons)"
check_eq "non-root refuse" 3 "$(run_real --verify-only)"
check_eq "mauvaise cible /dev/sda" 3 "$(base_env "$SCRIPT" --image "$IMAGE" --device /dev/sda --verify-only >/dev/null 2>&1; echo $?)"
ln -s "$FAKE" "$TMP/devlink"
check_eq "cible symlink" 3 "$(base_env env A71_TEST_DEVICE_PATH="$TMP/devlink" "$SCRIPT" --image "$IMAGE" --device /dev/sdd --verify-only >/dev/null 2>&1; echo $?)"
check_eq "RM=0" 3 "$(STUB_LSBLK_RAW='NAME="sdd" MAJ:MIN="8:48" RM="0" RO="0" TYPE="disk" SIZE="31000000000" MODEL="X" SERIAL="Y" TRAN="usb" MOUNTPOINTS=""' run_test --verify-only)"
check_eq "RO=1" 3 "$(STUB_LSBLK_RAW='NAME="sdd" MAJ:MIN="8:48" RM="1" RO="1" TYPE="disk" SIZE="31000000000" MODEL="X" SERIAL="Y" TRAN="usb" MOUNTPOINTS=""' run_test --verify-only)"
check_eq "taille trop petite" 3 "$(STUB_LSBLK_RAW='NAME="sdd" MAJ:MIN="8:48" RM="1" RO="0" TYPE="disk" SIZE="10000000000" MODEL="X" SERIAL="Y" TRAN="usb" MOUNTPOINTS=""' run_test --verify-only)"
check_eq "mauvaise MAJ:MIN" 3 "$(STUB_LSBLK_RAW='NAME="sdd" MAJ:MIN="8:49" RM="1" RO="0" TYPE="disk" SIZE="31000000000" MODEL="X" SERIAL="Y" TRAN="usb" MOUNTPOINTS=""' run_test --verify-only)"
check_eq "partition montee" 3 "$(STUB_MOUNT='/dev/sdd1 /mnt ext4 rw 0 0' run_test --verify-only)"
check_eq "swap" 3 "$(STUB_SWAP='/dev/sdd1' run_test --verify-only)"
check_eq "holder" 3 "$(A71_TEST_HOLDER=1 run_test --verify-only)"
ln -s "$IMAGE" "$TMP/image-link"
check_eq "image symlink" 4 "$(base_env "$SCRIPT" --image "$TMP/image-link" --device /dev/sdd --verify-only >/dev/null 2>&1; echo $?)"
cp "$IMAGE.sha256" "$TMP/good.sha"
printf 'deadbeef  image.img\n' >"$IMAGE.sha256"
check_eq "hash incorrect" 4 "$(run_test --verify-only)"
cp "$TMP/good.sha" "$IMAGE.sha256"
check_eq "plusieurs partitions" 4 "$(STUB_SFDISK_TABLE='label: dos
sector-size: 512
image1 : start= 2048, size= 1024, type=83
image2 : start= 4096, size= 1024, type=83' run_test --verify-only)"
check_eq "type de partition != 83" 4 "$(STUB_SFDISK_TABLE='label: dos
sector-size: 512
image1 : start= 2048, size= 2048, type=82' run_test --verify-only)"
check_eq "partition hors fichier" 4 "$(STUB_SFDISK_TABLE='label: dos
sector-size: 512
image1 : start= 2048, size= 999999, type=83' run_test --verify-only)"
check_eq "sector-size invalide" 4 "$(STUB_SFDISK_TABLE='label: dos
sector-size: 1024
image1 : start= 2048, size= 2048, type=83' run_test --verify-only)"
check_eq "start non numerique" 4 "$(STUB_SFDISK_TABLE='label: dos
sector-size: 512
image1 : start= abc, size= 2048, type=83' run_test --verify-only)"
check_eq "size non numerique" 4 "$(STUB_SFDISK_TABLE='label: dos
sector-size: 512
image1 : start= 2048, size= abc, type=83' run_test --verify-only)"
check_eq "label incorrect" 4 "$(STUB_LABEL=WRONG run_test --verify-only)"
check_eq "type de systeme de fichiers incorrect" 4 "$(STUB_FS_TYPE=ext2 run_test --verify-only)"
check_eq "rootfs sans /init refuse" 4 "$(STUB_DEBUGFS_NO_INIT=1 run_test --verify-only)"
check_eq "echec extraction dd" 4 "$(STUB_DD_FAIL=1 run_test --verify-only)"
ERR_DD=$(STUB_DD_FAIL=1 run_test_err --verify-only)
check_eq "echec extraction: stderr non vide" 1 "$([ "$(printf '%s\n' "$ERR_DD" | sed -n '2p')" -gt 0 ] && echo 1 || echo 0)"
: >"$LOG"
# Refus explicite dans un pseudo-terminal : sans TTY de contrôle, le script
# sortirait 3 pour "terminal indisponible" et le test ne testerait pas le refus.
cat >"$TMP/confirm-refuse.sh" <<EOF
#!/bin/sh
exec env PATH="$BIN:/usr/bin:/bin" A71_STUB_LOG="$LOG" A71_WRITE_TEST_MODE=1 \
    A71_TEST_DEVICE_PATH="$FAKE" A71_TEST_IMAGE_PATH="$IMAGE" TMPDIR="$TMP/write-tmp" \
    "$SCRIPT" --image "$IMAGE" --device /dev/sdd
EOF
chmod 755 "$TMP/confirm-refuse.sh"
CONFIRM_REFUSED_RC=$(printf 'NON\n' | timeout 5 script -qec "$TMP/confirm-refuse.sh" /dev/null >/dev/null 2>&1; echo $?)
check_eq "confirmation refusee" 3 "$CONFIRM_REFUSED_RC"
check_eq "aucune ecriture avant confirmation" 0 "$(grep -c 'of=.*fake-sdd' "$LOG" || true)"
: >"$LOG"
check_eq "verify-only succes" 0 "$(run_test --verify-only)"
check_eq "verify-only sans ecriture" 0 "$(grep -c 'of=.*fake-sdd' "$LOG" || true)"
check_eq "extraction partition appelee" 1 "$(grep -c 'dd .*skip=2048.*count=2048' "$LOG" || true)"
check_eq "dumpe2fs sur partition extraite" 1 "$(grep -c 'dumpe2fs .*partition.ext4' "$LOG" || true)"
check_eq "dumpe2fs sur image complete interdit" 0 "$(grep -c 'dumpe2fs .*image.img' "$LOG" || true)"
check_eq "temporaire nettoye apres succes" 0 "$(find "$TMP/write-tmp" -mindepth 1 | wc -l | tr -d ' ')"
: >"$LOG"
check_eq "ecriture simulee succes" 0 "$(run_test --yes-i-understand-testing-only)"
check_eq "dd ecriture appele" 1 "$(grep -c 'of=.*fake-sdd' "$LOG" || true)"
check_eq "reecriture hash differente" 6 "$(STUB_BAD_READBACK=1 run_test --yes-i-understand-testing-only)"
check_eq "rereadpt impossible" 5 "$(STUB_REREAD_FAIL=1 run_test --yes-i-understand-testing-only)"
check_eq "confirmation --yes interdite hors test" 3 "$(env -u A71_WRITE_TEST_MODE PATH="$BIN:/usr/bin:/bin" "$SCRIPT" --image "$IMAGE" --device /dev/sdd --yes-i-understand-testing-only >/dev/null 2>&1; echo $?)"
ERR_RESULT=$(STUB_LABEL=WRONG run_test_err --verify-only)
check_eq "mauvais label: code" 4 "$(printf '%s\n' "$ERR_RESULT" | sed -n '1p')"
check_eq "mauvais label: stderr non vide" 1 "$([ "$(printf '%s\n' "$ERR_RESULT" | sed -n '2p')" -gt 0 ] && echo 1 || echo 0)"
check_eq "temporaire nettoye apres echec" 0 "$(find "$TMP/write-tmp" -mindepth 1 | wc -l | tr -d ' ')"

section "I1 : image MBR reelle, outils reels"
REAL_IMAGE="$ROOT/../work/sdcard/a71-sd-usb.img"
[ -f "$REAL_IMAGE" ] || REAL_IMAGE="$ROOT/../work/sdcard/a71-sd-init.img"
if [ -f "$REAL_IMAGE" ]; then
    BIN_REAL="$TMP/bin-real"
    mkdir -p "$BIN_REAL" "$TMP/real-tmp"
    for name in lsblk findmnt swapon dmsetup partprobe blockdev udevadm umount; do
        cp "$BIN/$name" "$BIN_REAL/$name"
    done
    FAKE_REAL="$TMP/fake-real"
    truncate -s 31000000000 "$FAKE_REAL"
    : >"$TMP/real-stub.log"
    env PATH="$BIN_REAL:/usr/bin:/bin" A71_STUB_LOG="$TMP/real-stub.log" \
        A71_WRITE_TEST_MODE=1 A71_TEST_DEVICE_PATH="$FAKE_REAL" \
        TMPDIR="$TMP/real-tmp" "$SCRIPT" --image "$REAL_IMAGE" --device /dev/sdd --verify-only \
        >"$TMP/real.out" 2>"$TMP/real.err"
    check_eq "vraie image MBR + ext4 offset 2048 -> 0" 0 "$?"
    check_eq "vraie image: label A71ROOT affiche" 1 "$(grep -c 'label        : A71ROOT' "$TMP/real.err")"
    check_eq "vraie image: VERIFY-ONLY affiche" 1 "$(grep -c 'VERIFY-ONLY' "$TMP/real.err")"
    check_eq "vraie image: /init compatible" 0 "$(grep -c 'rootfs incompatible' "$TMP/real.err" || true)"
    check_eq "vraie image: temporaire nettoye" 0 "$(find "$TMP/real-tmp" -mindepth 1 | wc -l | tr -d ' ')"
    OLD_IMAGE="$ROOT/../work/sdcard/a71-sd.img"
    if [ -f "$OLD_IMAGE" ]; then
        env PATH="$BIN_REAL:/usr/bin:/bin" A71_STUB_LOG="$TMP/real-stub.log" \
            A71_WRITE_TEST_MODE=1 A71_TEST_DEVICE_PATH="$FAKE_REAL" \
            TMPDIR="$TMP/real-tmp" "$SCRIPT" --image "$OLD_IMAGE" --device /dev/sdd --verify-only \
            >/dev/null 2>"$TMP/old.err"
        check_eq "ancienne image sans /init refusee -> 4" 4 "$?"
        check_eq "ancienne image: message /init" 1 "$(grep -c 'rootfs incompatible' "$TMP/old.err")"
    fi
else
    printf '  (ignore) work/sdcard/a71-sd.img absent\n'
fi

printf '\n%s\n' "---------------------------------------------"
printf 'Resultat I1 : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
