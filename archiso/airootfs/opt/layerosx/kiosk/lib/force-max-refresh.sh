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
#
# One-shot wasn't enough in practice: reported as "some screens don't
# get forced, mostly right at the start of boot" -- right at X
# startup, a monitor's EDID/mode list can still be settling (multi-
# monitor setups especially), so a single xrandr pass moments after
# openbox starts can run before every output is fully ready and just
# never gets reapplied afterwards. Retrying for a while covers that
# without needing to know in advance how long any given monitor takes.
set -uo pipefail

command -v xrandr >/dev/null 2>&1 || exit 0

apply_once() {
    python3 - <<'PYEOF'
import json
import re
import subprocess

# Screens with a resolution / refresh rate fixed in LayerOSX Settings >
# Displays (lib/displays.py, /var/lib/layerosx/display-modes) are the user's
# choice -- never "correct" them back to the maximum rate.
try:
    with open("/var/lib/layerosx/display-modes") as f:
        FIXED = {k for k, v in json.load(f).items() if isinstance(v, dict) and (v.get("size") or v.get("rate"))}
except (OSError, ValueError, AttributeError):
    FIXED = set()

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
        output = None if m.group(1) in FIXED else m.group(1)
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
    # The rate currently in effect is the one xrandr marks with "*".
    active = next((float(r) for r, star in rates if star), None)
    # Skip if this output is ALREADY at (essentially) its max rate. Re-issuing
    # the same mode on every pass is what makes the screen flicker on each
    # relaunch/boot -- only switch when there is an actual change to make.
    if active is not None and abs(active - best) < 0.4:
        output = None
        continue
    subprocess.run(
        ["xrandr", "--output", output, "--mode", res, "--rate", f"{best:.2f}"],
        check=False,
    )
    output = None  # one active mode per output, done with this block
PYEOF
}

# ~20s of retries at the start (covers slow-to-settle EDID/multi-
# monitor setups), then a couple of slower follow-up passes in case
# something else (openbox, a login manager, a monitor waking up late)
# resets the mode after that window.
for _ in 1 2 3 4 5 6 7 8; do
    apply_once
    sleep 2.5
done
sleep 15
apply_once
sleep 30
apply_once
