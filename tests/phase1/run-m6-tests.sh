#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  ECHEC %s (%s)\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "attendu [$2] obtenu [$3]"; }
A="$ROOT/scripts/analyze-kernel-errors.py"
cat >"$TMP/dmesg" <<'EOD'
[    0.000000] Linux version test
[    0.500000] arm-smmu 15000000.iommu: Unhandled context fault: fsr=0x402, iova=0x9c0000
[    0.700000] msm_dsi_phy: [drm:dsi_pll_10nm_vco_prepare] *ERROR* DSI PLL(0) lock failed, status=0x0
[    0.710000] msm_dsi_phy: PLL(0) lock failed
[    1.000000] msm_dpu: Direct firmware load for qcom/a630_sqe.fw failed with error -2
[    1.010000] msm_dpu: failed to load a630_sqe.fw
[    1.200000] aux_bridge: error -ENODEV: failed to acquire drm_bridge
[    1.300000] init: can't open /dev/ttyMSM0: No such file or directory
[    1.400000] module: Unknown symbol foo
[    2.000000] Call trace:
EOD
python3 "$A" --dmesg "$TMP/dmesg" --text "$TMP/out.txt" --json "$TMP/out.json" >/dev/null 2>&1
eq "analyse -> 0" 0 "$?"
eq "firmware a630 détecté" 1 "$(grep -c 'firmware_missing:qcom/a630_sqe.fw' "$TMP/out.txt" || true)"
eq "SMMU compté" 1 "$(grep -c '^smmu_context_fault' "$TMP/out.txt" || true)"
eq "DSI compté deux fois" 2 "$(awk -F'\t' '$1=="dsi_pll_lock_failed"{print $5}' "$TMP/out.txt")"
eq "ttyMSM0 détecté" 1 "$(grep -c '^ttymsm0_missing' "$TMP/out.txt" || true)"
eq "Unknown symbol bloquant" 1 "$(python3 -c 'import json;d=json.load(open("'"$TMP"'/out.json"));print(sum(1 for r in d["signatures"] if r["state"]=="DRIVER_MISSING"))')"
eq "JSON valide" 0 "$(python3 -m json.tool "$TMP/out.json" >/dev/null 2>&1; echo $?)"
python3 "$A" --dmesg "$TMP/absent" >/dev/null 2>&1
eq "dmesg absent -> 3" 3 "$?"
python3 "$A" --help >/dev/null 2>&1
eq "aide -> 0" 0 "$?"
printf '\nResultat M6 : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
