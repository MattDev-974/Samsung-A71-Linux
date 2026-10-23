#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  ECHEC %s (%s)\n' "$1" "$2"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "attendu [$2] obtenu [$3]"; }
FW="$ROOT/rootfs/lib/firmware/qcom/a630_sqe.fw"
eq "firmware pipeline présent" 1 "$([ -f "$FW" ] && echo 1 || echo 0)"
eq "firmware taille 34188" 34188 "$(stat -c '%s' "$FW")"
eq "firmware hash" 1c21b527d9183487cc550dabbb3f43e555df5a977a461934fc61f0635a9aa90c "$(sha256sum "$FW" | awk '{print $1}')"
cat >"$TMP/dmesg" <<'EOD'
[    1.131759] msm_dpu ae01000.display-controller: Direct firmware load for qcom/a630_sqe.fw failed with error -2
[    1.131766] msm_dpu ae01000.display-controller: [drm:adreno_request_fw] *ERROR* failed to load a630_sqe.fw
[    1.268439] EXT4-fs (mmcblk2p1): mounted filesystem test r/w
[    0.741165] msm_dsi_phy: [drm:dsi_pll_10nm_vco_prepare] *ERROR* DSI PLL(0) lock failed, status=0x0
[    0.743687] msm_dsi_phy: PLL(0) lock failed
[    0.504670] arm-smmu 15000000.iommu: Unhandled context fault: fsr=0x402
[    0.323335] aux_bridge: error -ENODEV: failed to acquire drm_bridge
EOD
python3 "$ROOT/scripts/analyze-kernel-errors.py" --dmesg "$TMP/dmesg" --text "$TMP/out" --json "$TMP/out.json" >/dev/null 2>&1
eq "analyse dmesg" 0 "$?"
eq "échec firmware malgré fichier" 1 "$(awk -F'\t' '$1=="firmware_missing:qcom/a630_sqe.fw"{print $5}' "$TMP/out")"
eq "DSI PLL = 2" 2 "$(awk -F'\t' '$1=="dsi_pll_lock_failed"{print $5}' "$TMP/out")"
eq "SMMU = 1 fixture" 1 "$(awk -F'\t' '$1=="smmu_context_fault"{print $5}' "$TMP/out")"
printf '\nResultat M7B.1 : %d reussite(s), %d echec(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
