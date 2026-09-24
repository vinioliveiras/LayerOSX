#!/usr/bin/env bash
# Kiosk lockdown of openbox's config, run BEFORE `openbox &` (openbox only
# reads rc.xml at startup). Historically this just added an F2 "peek at the
# log" keybind -- it now also strips every other keyboard/desktop shortcut so
# the kiosk really shows the VM and nothing else, with no accidental way onto
# an empty desktop, another window, or a menu.
#
# $1 = the log file the Ctrl+Alt+T terminal should tail.
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
# Build mode (/etc/layerosx/mode, baked by build.sh):
#   debug   -> Ctrl+Alt+T opens the live terminal directly; VT switching is left
#              working too (that's an X-server option handled in build.sh).
#   release -> Ctrl+Alt+T asks for the kiosk user's password before opening the
#              terminal (lib/maint-terminal.sh); VT switching stays off. Kept
#              in BOTH modes: Ctrl+Alt+W
#              (LayerOSX Settings), Ctrl+Alt+U (USB passthrough picker) and
#              the brightness keys (brightnessctl).
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

# 0) Drop every application rule we added in an earlier session, so an updated
#    rule replaces the old one instead of being skipped by its marker.
content = re.sub(r"[ \t]*<application\b[^>]*> <!-- layerosx-[^>]*-->.*?</application>\n?", "", content,
                 flags=re.DOTALL)

# 1) One desktop only (stock ships 4). Removes the whole "switched onto an
#    empty desktop, now where's the VM window?" failure class.
content = re.sub(r"<number>\d+</number>", "<number>1</number>", content, count=1)

# 2) Remove EVERY keyboard shortcut. openbox's <keyboard> can hold just
#    <chainQuitKey> and no <keybind> children, which is exactly what a kiosk
#    wants: Ctrl+Alt+arrows (GoToDesktop), Alt+Tab, Alt+F4, W-e, the
#    Reconfigure/Restart binds -- all gone. (the terminal chord is re-added below, see step 6.)
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

# 5b) Reims' own Vulkan window ("Reims vGPU", see mac-vm-launch.sh): same
#     treatment as the QEMU/SDL window -- focused, above, one desktop, and no
#     openbox decorations on the borderless fullscreen window.
if "layerosx-reims-window" not in content and "</applications>" in content:
    app_rule = (
        '  <application title="Reims vGPU"> <!-- layerosx-reims-window -->\n'
        "    <desktop>1</desktop>\n"
        "    <decor>no</decor>\n"
        "    <focus>yes</focus>\n"
        "    <layer>above</layer>\n"
        "  </application>\n"
    )
    content = content.replace("</applications>", app_rule + "</applications>", 1)

# 6) Both modes: Ctrl+Alt+T -> maintenance terminal (lib/maint-terminal.sh).
#    Not F2 (what this used to be): a key openbox grabs never reaches macOS,
#    and F2 is brightness-up / an app key there; Ctrl+Alt+T is the usual Linux
#    "open terminal" chord and Control+Option+T isn't a macOS shortcut. In a
#    debug build it opens straight away; in a release build it asks for the
#    kiosk user's password first, so the appliance stays locked but is never
#    unmaintainable (no other way to reach gpu/verbose/relaunch/logs there).
if "layerosx-f2-peek" not in content and "</keyboard>" in content:
    keybind = (
        '  <keybind key="C-A-t"> <!-- layerosx-f2-peek -->\n'
        '    <action name="Execute">\n'
        f"      <command>/opt/layerosx/kiosk/lib/maint-terminal.sh {log_target}</command>\n"
        "    </action>\n"
        "  </keybind>\n"
    )
    content = content.replace("</keyboard>", keybind + "</keyboard>", 1)

# 7) Both modes: Ctrl+Alt+W opens LayerOSX Settings (lib/panel.sh -> the
#    GTK4/libadwaita panel in /opt/layerosx/panel; falls back to the zenity
#    lib/kiosk-menu.sh if GTK can't start): Wi-Fi, battery, displays/graphics,
#    sound, USB, Mac (boot log, restart), power, diagnostics, terminal. It runs fixed zenity dialogs, not a
#    shell (the terminal entry still goes through maint-terminal.sh's policy),
#    so it doesn't reopen an escape hatch in a locked release build.
if "layerosx-wifi" not in content and "</keyboard>" in content:
    keybind = (
        '  <keybind key="C-A-w"> <!-- layerosx-wifi -->\n'
        '    <action name="Execute">\n'
        "      <command>/opt/layerosx/kiosk/lib/panel.sh</command>\n"
        "    </action>\n"
        "  </keybind>\n"
    )
    content = content.replace("</keyboard>", keybind + "</keyboard>", 1)

# 7a) Both modes: Ctrl+Alt+U opens the USB passthrough picker (give a host USB
#     device to the Mac / take it back). A fixed dialog, not a shell.
if "layerosx-usb" not in content and "</keyboard>" in content:
    keybind = (
        '  <keybind key="C-A-u"> <!-- layerosx-usb -->\n'
        '    <action name="Execute">\n'
        "      <command>/opt/layerosx/kiosk/lib/usb-passthrough.sh --pick</command>\n"
        "    </action>\n"
        "  </keybind>\n"
    )
    content = content.replace("</keyboard>", keybind + "</keyboard>", 1)

# 7c) Both modes: the laptop's volume keys -> this computer's volume (the
#     same control as Settings > Sound > Volume). openbox grabs them before the
#     VM window, like the brightness keys.
if "layerosx-volume" not in content and "</keyboard>" in content:
    keybind = "".join(
        f'  <keybind key="{k}"> <!-- layerosx-volume -->\n'
        f'    <action name="Execute"><command>python3 /opt/layerosx/panel/layerosx_backend.py volume {op}</command></action>\n'
        "  </keybind>\n"
        for k, op in (("XF86AudioRaiseVolume", "up"), ("XF86AudioLowerVolume", "down"), ("XF86AudioMute", "mute")))
    content = content.replace("</keyboard>", keybind + "</keyboard>", 1)

# 7b) Both modes: the laptop's brightness keys. The panel backlight belongs to
#     the host (macOS has nothing to drive), so openbox catches the keys before
#     the VM window does and runs lib/brightness.sh (brightnessctl; the kiosk
#     user is in `video`, which brightnessctl's udev rule lets write the
#     backlight). It remembers the value across reboots; never below 5%.
if "layerosx-brightness" not in content and "</keyboard>" in content:
    keybind = (
        '  <keybind key="XF86MonBrightnessUp"> <!-- layerosx-brightness -->\n'
        '    <action name="Execute"><command>/opt/layerosx/kiosk/lib/brightness.sh up</command></action>\n'
        "  </keybind>\n"
        '  <keybind key="XF86MonBrightnessDown"> <!-- layerosx-brightness -->\n'
        '    <action name="Execute"><command>/opt/layerosx/kiosk/lib/brightness.sh down</command></action>\n'
        "  </keybind>\n"
    )
    content = content.replace("</keyboard>", keybind + "</keyboard>", 1)

# 8) Keep every LayerOSX window (settings panel, terminal, zenity dialogs) on
#    top of the pinned, always-above VM window and always CENTERED on screen,
#    or they'd open hidden behind the fullscreen VM / wherever openbox likes.
if "layerosx-dialogs-above" not in content and "</applications>" in content:
    rules = (
        '  <application class="Zenity"> <!-- layerosx-dialogs-above -->\n'
        "    <focus>yes</focus>\n"
        "    <layer>above</layer>\n"
        "  </application>\n"
        '  <application title="LayerOSX*"> <!-- layerosx-dialogs-above -->\n'
        "    <focus>yes</focus>\n"
        "    <layer>above</layer>\n"
        '    <position force="yes"><x>center</x><y>center</y></position>\n'
        "  </application>\n"
    )
    content = content.replace("</applications>", rules + "</applications>", 1)

# 9) layerosx_style.present_animated()'s 1x1 helper ("layerosx-kick"): it must
#    sit ABOVE the fullscreen VM for picom to redirect the screen (so the
#    panel's open animation plays), but never take focus or be seen -- parked
#    at 0,0, undecorated (picom also makes it fully transparent).
if "layerosx-kick" not in content and "</applications>" in content:
    rules = (
        '  <application title="layerosx-kick"> <!-- layerosx-kick -->\n'
        "    <decor>no</decor>\n"
        "    <focus>no</focus>\n"
        "    <layer>above</layer>\n"
        "    <skip_taskbar>yes</skip_taskbar>\n"
        '    <position force="yes"><x>0</x><y>0</y></position>\n'
        "  </application>\n"
    )
    content = content.replace("</applications>", rules + "</applications>", 1)

if content != original:
    path.write_text(content, encoding="utf-8")
PYEOF
