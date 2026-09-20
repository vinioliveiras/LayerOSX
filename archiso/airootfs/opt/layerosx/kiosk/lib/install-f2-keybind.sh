#!/usr/bin/env bash
# Adds an F2 keybinding to openbox that opens a plain terminal tailing
# whatever log is actually relevant right now ($1) -- so the install
# and first-run wizard can stay UI-only (progress bars, no visible
# terminal) by default, while anyone who wants to see the raw output
# mid-process can still get to it instantly instead of it being
# forced on everyone all the time. Also strips the right-click root
# menu (see below) -- both changes are about the same thing: F2 is
# meant to be the one deliberate way out of the kiosk, not one of
# several.
#
# Must run BEFORE `openbox &` starts (openbox only reads its config
# file at launch -- editing it afterwards needs `openbox
# --reconfigure`, which is more moving parts than just doing this
# first). Copies openbox's own stock rc.xml (shipped by the openbox
# package) instead of writing a minimal one from scratch, so none of
# openbox's normal window-management behavior (needed for GParted,
# zenity dialogs, the QEMU/SDL window, ...) is lost -- this only edits
# a couple of things on top of it. Safe to call every boot: each
# change is independently idempotent (checked inside the Python
# script below, not by skipping the whole file), so a system that
# already got the F2 keybind from an older version of this script
# still picks up the root-menu fix on its next boot instead of being
# stuck with whatever it had the first time this ran.
set -uo pipefail

LOG_TARGET="${1:?usage: install-f2-keybind.sh <log-file-to-tail>}"

mkdir -p ~/.config/openbox
if [ ! -f ~/.config/openbox/rc.xml ]; then
    cp /etc/xdg/openbox/rc.xml ~/.config/openbox/rc.xml 2>/dev/null || exit 0
fi

python3 - "$LOG_TARGET" <<'PYEOF'
import re
import sys
from pathlib import Path

log_target = sys.argv[1]
path = Path.home() / ".config/openbox/rc.xml"
content = path.read_text(encoding="utf-8")
original = content

if "layerosx-f2-peek" not in content and "</keyboard>" in content:
    keybind = (
        '  <keybind key="F2"> <!-- layerosx-f2-peek -->\n'
        '    <action name="Execute">\n'
        f'      <command>/opt/layerosx/kiosk/lib/peek-terminal.sh {log_target}</command>\n'
        "    </action>\n"
        "  </keybind>\n"
    )
    content = content.replace("</keyboard>", keybind + "</keyboard>", 1)

# Confirmed on real hardware: right-clicking the desktop still opened
# openbox's stock root menu (Applications / System -> Log Out,
# Reconfigure Openbox, GNOME/KDE/Xfce settings panels, ...) on an
# installed kiosk system -- a plain, undocumented way out of "boots
# straight into the VM, nothing else" that defeats the whole point of
# making F2 the one deliberate escape hatch. Strip just that one
# mousebind (Right-click -> root-menu, inside openbox's stock rc.xml
# "Root" context); everything else in that context (e.g. middle-click
# for the window list) and every other context (needed for
# GParted/zenity/the QEMU window) is left untouched.
content = re.sub(
    r'\s*<mousebind button="Right" action="Press">\s*'
    r'<action name="ShowMenu"><menu>root-menu</menu></action>\s*'
    r"</mousebind>",
    "",
    content,
    count=1,
)

if content != original:
    path.write_text(content, encoding="utf-8")
PYEOF
