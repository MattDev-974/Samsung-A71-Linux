#!/usr/bin/env bash
# shellcheck shell=bash
#
# validate-rootfs.sh - validation statique stricte du rootfs A71 (E1).
#
# Strictement en lecture seule : aucun montage, chroot, QEMU, sudo, loop
# device ni acces appareil. Le seul fichier ecrit est le rapport demande.
#
# Usage :
#   ./scripts/validate-rootfs.sh \
#       --rootfs <rootfs-functional> \
#       --manifest manifest.yaml \
#       --ownership-manifest <rootfs>/reports/ownership-manifest.txt \
#       --report <sortie>
#
# Codes : 0 conforme, 1 non-conformite, 2 usage, 3 entree invalide,
#         4 rapport impossible (rapport symlink refuse).

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

exec python3 "$SCRIPT_DIR/validate-rootfs.py" "$@"
