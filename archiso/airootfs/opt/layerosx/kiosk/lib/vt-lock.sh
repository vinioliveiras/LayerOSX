#!/usr/bin/env bash
# "Text consoles" toggle (LayerOSX Settings > General), applied at boot by
# layerosx-vtlock.service -- as root, before the kiosk's X server starts.
#
# Locked (default -- the appliance behaviour the old release build baked in):
# X gets DontVTSwitch + DontZap, so Ctrl+Alt+F1..F6 (switch to a Linux text
# console) and Ctrl+Alt+Backspace (kill X) do nothing and there is no host-side
# escape from the fullscreen Mac. Unlocked (/var/lib/layerosx/vt-switch = on):
# the file is removed and those keys work again -- the old debug build's
# escape hatch. X reads xorg.conf.d only when it starts, hence "next boot".
#
# The tty2 console itself follows the Ctrl+Alt+T terminal policy
# (lib/tty2-getty.sh), so unlocking consoles never bypasses the terminal
# password.
set -u
CONF=/etc/X11/xorg.conf.d/10-layerosx-kiosk-lock.conf
STATE="${LAYEROSX_STATE_DIR:-/var/lib/layerosx}/vt-switch"
case "$(cat "$STATE" 2>/dev/null)" in
    on|1|yes|true)
        rm -f "$CONF"
        echo "vt-lock: text consoles ENABLED (Ctrl+Alt+F1..F6)"
        ;;
    *)
        mkdir -p "$(dirname "$CONF")"
        cat > "$CONF" <<'CONF'
# Written at boot by /opt/layerosx/kiosk/lib/vt-lock.sh (layerosx-vtlock.service).
# Text consoles are locked: no Ctrl+Alt+Fn VT switching, no Ctrl+Alt+Backspace.
# Unlock in LayerOSX Settings > General > Text consoles, then restart.
Section "ServerFlags"
    Option "DontVTSwitch" "on"
    Option "DontZap"      "on"
EndSection
CONF
        echo "vt-lock: text consoles locked"
        ;;
esac
exit 0
