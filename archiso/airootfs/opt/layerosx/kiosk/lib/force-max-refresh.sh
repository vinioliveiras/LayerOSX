#!/usr/bin/env bash
# Some monitors negotiate a lower/wrong refresh rate than they
# actually support when X auto-picks a mode via EDID -- seen
# firsthand on a second monitor, whose image came out visibly
# corrupted/noisy until forced to its real max rate. Rather than
# hardcode an xorg.conf mode line (which would be flat-out wrong on
# any other monitor), this re-detects every connected output at
# runtime and re-applies its own current resolution at the highest
# refresh rate that resolution actually supports.
#
# Runs from .xinitrc, after openbox starts (needs a live X server;
# doesn't touch anything if xrandr isn't available or a display
# reports no modes, so it's safe to just let it fail quietly on
# unusual setups).
set -uo pipefail

command -v xrandr >/dev/null 2>&1 || exit 0

python3 - <<'PYEOF'
import re
import subprocess

try:
    out = subprocess.run(
        ["xrandr", "--query"], capture_output=True, text=True, check=False
    ).stdout
except FileNotFoundError:
    raise SystemExit(0)

output = None
for line in out.splitlines():
    m = re.match(r"^(\S+) connected", line)
    if m:
        output = m.group(1)
        continue
    if output is None:
        continue
    m = re.match(r"^\s+(\d+x\d+)([ \t]+.*)$", line)
    if not m:
        continue
    res, rest = m.group(1), m.group(2)
    rates = re.findall(r"(\d+\.\d+)(\*?)", rest)
    if not any(star for _, star in rates):
        continue  # not the currently-active resolution for this output
    best = max(float(r) for r, _ in rates)
    subprocess.run(
        ["xrandr", "--output", output, "--mode", res, "--rate", f"{best:.2f}"],
        check=False,
    )
    output = None  # one active mode per output, done with this block
PYEOF
