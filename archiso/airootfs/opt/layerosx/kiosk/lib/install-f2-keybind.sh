#!/usr/bin/env bash
# Kiosk lockdown of openbox's config, run BEFORE `openbox &` (openbox only
# reads rc.xml at startup). Historically this just added an F2 "peek at the
# log" keybind -- it now also strips every other keyboard/desktop shortcut so
# the kiosk really shows the VM and nothing else, with no accidental way onto
# an empty desktop, another window, or a menu.
#
# $1 = the log file F2's terminal should tail.
#
# What it does to a COPY of openbox's own stock rc.xml (so all the normal
# window management GParted/zenity/the QEMU window rely on is kept):
#   * Drops the desktop count 4 -> 1 (removes the "scrolled onto an empty
#     desktop, where's the VM?" failure class).
#   * Removes EVERY <keybind> -- Ctrl+Alt+arrows (switch desktop), Alt+Tab,
#     Alt+F4, the Reconfigure/Restart binds, all of them. The user reported
#     being able to Ctrl+Alt+arrow between windows; a kiosk wants none of it.
#   * Removes the desktop-switch mousebinds (scroll/Alt-scroll -> GoToDesktop).
#   * Strips the right-click root menu (a plain way out to Log Out / settings).
#   * Pins the QEMU/SDL window focused + above everything on the one desktop.
#
# Build mode (/etc/layerosx/mode, baked by build.sh) decides ONE thing here:
#   debug   -> re-add the F2 peek-terminal keybind (the developer's escape
#              hatch to the live log). VT switching is left working too (that's
#              an X-server option handled in build.sh, not here).
#   release -> no F2: a fully locked appliance. The only shortcut kept (both
#              modes) is Ctrl+Alt+W, which opens the Wi-Fi picker dialog.
#
# Safe to call every boot: each edit is independently idempotent.
set -uo pipefail

LOG_TARGET="${1:?usage: install-f2-keybind.sh <log-file-to-tail>}"
MODE="$(cat /etc/layerosx/mode 2>/dev/null || echo release)"
case "$MODE" in debug) : ;; *) MODE=release ;; esac

mkdir -p ~/.config/openbox
if [ ! -f ~/.config/openbox/rc.xml ]; then
    cp /etc/xdg/openbox/rc.xml ~/.config/openbox/rc.xml 2>/dev/null || exit 0
fi

python3 - "$LOG_TARGET" "$MODE" <<'PYEOF'
import re
import sys
from pathlib import Path

log_target = sys.argv[1]
mode = sys.argv[2]
path = Path.home() / ".config/openbox/rc.xml"
content = path.read_text(encoding="utf-8")
original = content

# 1) One desktop only (stock ships 4). Removes the whole "switched onto an
#    empty desktop, now where's the VM window?" failure class.
content = re.sub(r"<number>\d+</number>", "<number>1</number>", content, count=1)

# 2) Remove EVERY keyboard shortcut. openbox's <keyboard> can hold just
#    <chainQuitKey> and no <keybind> children, which is exactly what a kiosk
#    wants: Ctrl+Alt+arrows (GoToDesktop), Alt+Tab, Alt+F4, W-e, the
#    Reconfigure/Restart binds -- all gone. (Re-add only F2 below, debug only.)
content = re.sub(r"[ \t]*<keybind\b.*?</keybind>\s*", "", content, flags=re.DOTALL)

# 3) Remove the desktop-switching mousebinds (scroll / Alt-scroll / Ctrl-Alt-
#    scroll on the root window -> GoToDesktop). Leaves Focus/Raise clicks and
#    every other context untouched.
content = re.sub(
    r"[ \t]*<mousebind\b[^>]*>\s*<action name=\"GoToDesktop\">.*?</mousebind>\s*",
    "",
    content,
    flags=re.DOTALL,
)

# 4) Strip the right-click root menu (Applications/System -> Log Out,
#    settings panels, ...) -- another undocumented way out of the kiosk.
content = re.sub(
    r'\s*<mousebind button="Right" action="Press">\s*'
    r'<action name="ShowMenu"><menu>root-menu</menu></action>\s*'
    r"</mousebind>",
    "",
    content,
    count=1,
)

# 5) Pin the QEMU/SDL window (class/title both match QEMU's SDL frontend --
#    "QEMU (macOS-0)" etc.) focused, above everything, on the one desktop, so
#    a closing zenity dialog or a non-focus-stealing new window can't leave it
#    unfocused.
if "layerosx-qemu-focus" not in content and "</applications>" in content:
    app_rule = (
        '  <application class="*QEMU*" title="QEMU*"> <!-- layerosx-qemu-focus -->\n'
        "    <desktop>1</desktop>\n"
        "    <focus>yes</focus>\n"
        "    <layer>above</layer>\n"
        "  </application>\n"
    )
    content = content.replace("</applications>", app_rule + "</applications>", 1)

# 6) debug only: re-add the F2 keybind (the live-log peek terminal) into the
#    now-empty <keyboard>. release stays fully locked (no keybinds at all).
if mode == "debug" and "layerosx-f2-peek" not in content and "</keyboard>" in content:
    keybind = (
        '  <keybind key="F2"> <!-- layerosx-f2-peek -->\n'
        '    <action name="Execute">\n'
        f"      <command>/opt/layerosx/kiosk/lib/peek-terminal.sh {log_target}</command>\n"
        "    </action>\n"
        "  </keybind>\n"
    )
    content = content.replace("</keyboard>", keybind + "</keyboard>", 1)

# 7) Both modes: Ctrl+Alt+W opens the Wi-Fi picker. This is the ONLY way to
#    change networks in a locked release build (no terminal there). It runs a
#    fixed zenity dialog, not a shell, so it doesn't reopen an escape hatch.
if "layerosx-wifi" not in content and "</keyboard>" in content:
    keybind = (
        '  <keybind key="C-A-w"> <!-- layerosx-wifi -->\n'
        '    <action name="Execute">\n'
        "      <command>/opt/layerosx/kiosk/lib/wifi-setup.sh --pick</command>\n"
        "    </action>\n"
        "  </keybind>\n"
    )
    content = content.replace("</keyboard>", keybind + "</keyboard>", 1)

# 8) Keep the picker's dialogs (zenity) and its "Advanced (nmtui)" xterm on
#    top of the pinned, always-above QEMU window, or they'd open hidden behind
#    the fullscreen VM.
if "layerosx-dialogs-above" not in content and "</applications>" in content:
    rules = (
        '  <application class="Zenity"> <!-- layerosx-dialogs-above -->\n'
        "    <focus>yes</focus>\n"
        "    <layer>above</layer>\n"
        "  </application>\n"
        '  <application title="LayerOSX*"> <!-- layerosx-dialogs-above -->\n'
        "    <focus>yes</focus>\n"
        "    <layer>above</layer>\n"
        "  </application>\n"
    )
    content = content.replace("</applications>", rules + "</applications>", 1)

if content != original:
    path.write_text(content, encoding="utf-8")
PYEOF
