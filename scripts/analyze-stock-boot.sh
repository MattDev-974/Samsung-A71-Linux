#!/usr/bin/env bash
# shellcheck shell=bash
#
# analyze-stock-boot.sh - analyse strictement en lecture seule d'un boot.img
# Android d'origine (J3). Aucun contenu extrait n'est execute.
#
# Usage :
#   ./scripts/analyze-stock-boot.sh --input boot.img --output work/boot/stock [--force]
#
# Codes : 0 ok, 2 usage, 3 entree, 4 format, 5 sortie, 6 entree modifiee.

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec python3 "$SCRIPT_DIR/android_boot.py" "$@"
