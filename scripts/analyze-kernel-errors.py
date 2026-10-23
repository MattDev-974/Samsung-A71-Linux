#!/usr/bin/env python3
"""Analyse déterministe d'un dmesg A71, sans accès au téléphone."""
import argparse, json, re, sys

PATTERNS = [
    (r"Direct firmware load for (?P<fw>\S+) failed", "firmware_missing", "firmware", "DEGRADED", "FIRMWARE_MISSING", "nécessite firmware"),
    (r"failed to load (?P<fw>[^ ]+\.fw)", "firmware_load_failed", "adreno/firmware", "DEGRADED", "FIRMWARE_MISSING", "nécessite firmware"),
    (r"Unhandled context fault", "smmu_context_fault", "arm-smmu", "DEGRADED", "PRESENT_WITH_ERRORS", "connu, à corriger"),
    (r"(?:DSI PLL|PLL\([0-9]+\)).*lock failed", "dsi_pll_lock_failed", "msm_dsi_phy", "DEGRADED", "PRESENT_WITH_ERRORS", "connu, à corriger"),
    (r"failed to acquire drm_bridge", "drm_bridge_missing", "aux_bridge", "DEGRADED", "DEVICE_TREE_GAP", "nécessite DT/kernel"),
    (r"Could not get user/group ID of chrony", "chrony_user_missing", "chronyd", "DEGRADED", "USERSPACE_GAP", "à corriger"),
    (r"chronyd failed to start", "chronyd_start_failed", "chronyd", "DEGRADED", "USERSPACE_GAP", "à corriger"),
    (r"Could not resolve address of initstepslew", "chrony_dns_failed", "chronyd", "WARNING", "USERSPACE_GAP", "à corriger"),
    (r"can't open /dev/ttyMSM0", "ttymsm0_missing", "init/getty", "WARNING", "USERSPACE_GAP", "corrigé M5"),
    (r"Unknown symbol", "unknown_symbol", "modules", "BLOCKING", "DRIVER_MISSING", "nécessite module compatible"),
    (r"kernel panic|out of memory|oom-kill|I/O error", "blocking_kernel", "kernel", "BLOCKING", "UNKNOWN", "à corriger"),
    (r"Call trace", "call_trace", "kernel", "WARNING", "UNKNOWN", "contexte requis"),
    (r"sysfs groups creation failed", "ufs_sysfs_error", "ufshcd", "WARNING", "PRESENT_WITH_ERRORS", "connu, non bloquant"),
    (r"Unable to find .*supply|freq-table-hz property not specified", "ufs_vreg_warning", "ufshcd", "INFO", "PRESENT_WITH_ERRORS", "connu"),
    (r"sync_state\(\) pending", "sync_state_pending", "clock-controller", "INFO", "PRESENT_WITH_ERRORS", "connu"),
]

def normalize(line, match, label):
    text = re.sub(r"^\[[^\]]*\]\s*", "", line.strip())
    text = re.sub(r"\b0x[0-9a-fA-F]+\b", "0xADDR", text)
    text = re.sub(r"\b\d+\b", "N", text)
    text = re.sub(r"\s+", " ", text)
    return label + " | " + text[:240]

def analyze(path):
    entries = {}
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            for pattern, label, component, severity, state, advice in PATTERNS:
                m = re.search(pattern, line, re.I)
                if not m:
                    continue
                fw = m.groupdict().get("fw") if "fw" in m.groupdict() else None
                sig = label + (":" + fw if fw and label.startswith("firmware_missing") else "")
                key = (sig, component, severity, state, advice)
                rec = entries.setdefault(key, {"signature": sig, "component": component,
                    "severity": severity, "state": state, "advice": advice,
                    "first_line": lineno, "first_text": normalize(line, m, sig), "count": 0})
                rec["count"] += 1
                break
    return list(sorted(entries.values(), key=lambda r: (r["severity"], r["signature"])))

def text_report(rows):
    out = ["signature\tcomponent\tgravite\tetat\toccurrences\tpremiere_ligne\tpremier_texte"]
    for r in rows:
        out.append("%s\t%s\t%s\t%s\t%d\t%d\t%s" % (r["signature"], r["component"],
                   r["severity"], r["state"], r["count"], r["first_line"], r["first_text"]))
    return "\n".join(out) + "\n"

def main():
    ap = argparse.ArgumentParser(description="Analyse dmesg A71 (lecture seule)")
    ap.add_argument("--dmesg", required=True)
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--text", dest="text_out")
    args = ap.parse_args()
    try:
        rows = analyze(args.dmesg)
    except OSError as e:
        print("analyze-kernel-errors: %s" % e, file=sys.stderr)
        return 3
    text = text_report(rows)
    if args.text_out:
        open(args.text_out, "w", encoding="utf-8").write(text)
    else:
        sys.stdout.write(text)
    if args.json_out:
        obj = {"source": args.dmesg, "signatures": rows,
               "counts": {s: sum(1 for r in rows if r["severity"] == s)
                          for s in ("INFO", "WARNING", "DEGRADED", "BLOCKING", "UNKNOWN")}}
        open(args.json_out, "w", encoding="utf-8").write(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")
    return 0

if __name__ == "__main__":
    sys.exit(main())
