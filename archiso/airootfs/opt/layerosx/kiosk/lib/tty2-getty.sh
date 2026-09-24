#!/usr/bin/env bash
# getty for tty2 (Ctrl+Alt+F2, reachable only while "Text consoles" is on in
# LayerOSX Settings > Maintenance). Same rules as the Ctrl+Alt+T terminal:
#   LAYEROSX_TERMINAL=off           -> no shell at all, just a notice
#   no Maintenance password set     -> auto-login as "mac"
#   a Maintenance password is set   -> lib/tty2-login.sh asks for it, then logs in
# $1 = tty (from %I), $2 = TERM.
TTY="${1:-tty2}"; TERMTYPE="${2:-linux}"
POLICY="$(cat /etc/layerosx/terminal 2>/dev/null || echo open)"
if [ "$POLICY" = off ]; then
    exec </dev/"$TTY" >/dev/"$TTY" 2>&1
    printf '\nLayerOSX: this build has no maintenance console (LAYEROSX_TERMINAL=off).\nPress Ctrl+Alt+F1 to go back to the Mac.\n'
    exec sleep infinity
fi
if [ -s /var/lib/layerosx/maint-password ]; then
    exec /sbin/agetty --noclear -n -o '' -l /opt/layerosx/kiosk/lib/tty2-login.sh "$TTY" "$TERMTYPE"
fi
exec /sbin/agetty -o '-p -f -- \u' --noclear --autologin mac "$TTY" "$TERMTYPE"
