#!/usr/bin/env bash
# getty for tty2 (Ctrl+Alt+F2, reachable only while "Text consoles" is on in
# LayerOSX Settings > General). It follows the same policy as the Ctrl+Alt+T
# maintenance terminal (/etc/layerosx/terminal, build parameter
# LAYEROSX_TERMINAL), so unlocking consoles from the panel never opens a
# password-less shell by itself:
#   open     -> auto-login as "mac" (what the old debug build did)
#   password -> a normal login prompt (the mac user's password)
#   off      -> no shell at all, just a notice
# $1 = tty (from %I), $2 = TERM.
TTY="${1:-tty2}"; TERMTYPE="${2:-linux}"
POLICY="$(cat /etc/layerosx/terminal 2>/dev/null || echo password)"
case "$POLICY" in
    open)
        exec /sbin/agetty -o '-p -f -- \u' --noclear --autologin mac "$TTY" "$TERMTYPE" ;;
    off)
        exec </dev/"$TTY" >/dev/"$TTY" 2>&1
        printf '\nLayerOSX: this build has no maintenance console (LAYEROSX_TERMINAL=off).\nPress Ctrl+Alt+F1 to go back to the Mac.\n'
        exec sleep infinity ;;
    *)
        exec /sbin/agetty --noclear "$TTY" "$TERMTYPE" ;;
esac
