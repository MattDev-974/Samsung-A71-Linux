#!/usr/bin/env python3
"""Inject /chosen/bootargs into a compiled DTB (dtc round-trip).

Usage: dtb-bootargs.py board.dtb "console=tty0 console=ttyMSM0,115200n8 ..."
"""
import os
import re
import subprocess
import sys
import tempfile


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    dtb, bootargs = sys.argv[1], sys.argv[2]

    with tempfile.TemporaryDirectory() as tmp:
        dts = os.path.join(tmp, "board.dts")
        subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-o", dts, dtb],
                       check=True, stderr=subprocess.DEVNULL)
        text = open(dts, encoding="utf-8").read()

        # Drop an existing bootargs property, then add ours right after the
        # chosen node opening brace.
        text = re.sub(r'\n\t\tbootargs = "[^"]*";', "", text)
        text = re.sub(r'(\n\tchosen \{\n)',
                      r'\1\t\tbootargs = "%s";\n' % bootargs, text, count=1)
        open(dts, "w", encoding="utf-8").write(text)

        subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", dtb, dts],
                       check=True, stderr=subprocess.DEVNULL)
    print(f"{dtb}: bootargs = {bootargs}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
