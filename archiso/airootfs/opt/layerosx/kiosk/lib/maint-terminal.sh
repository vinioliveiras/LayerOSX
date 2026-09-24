#!/usr/bin/env bash
# Ctrl+Alt+T maintenance terminal (also Settings > Maintenance > Terminal).
#
# /etc/layerosx/terminal (build parameter LAYEROSX_TERMINAL): "off" = no
# terminal at all; anything else = available. Whether it asks for a password
# is the USER's choice: the optional Maintenance password set in LayerOSX
# Settings > Maintenance (none by default). It's checked by
# `layerosx_backend.py check-maint-password` against a salted scrypt hash in
# /var/lib/layerosx/maint-password -- nothing is stored or logged here; failed
# attempts go to ~/maint-auth.log with a timestamp only. 3 tries per press,
# with a short growing delay.
#
# $1 = log file the terminal shows/follows (passed through to peek-terminal.sh).
set -uo pipefail
LOG_TARGET="${1:-$HOME/mac-vm.log}"
PEEK=/opt/layerosx/kiosk/lib/peek-terminal.sh
AUTH_LOG="$HOME/maint-auth.log"
T="LayerOSX — Maintenance"

# One terminal at a time (the chord mashed repeatedly shouldn't stack dialogs).
exec 9>"/tmp/layerosx-maint-$(id -u).lock"
# Already open? Bring the existing terminal (or its password dialog) forward.
if ! flock -n 9; then
    /opt/layerosx/kiosk/lib/raise-window.sh '^LayerOSX — (terminal|Maintenance)' || true
    exit 0
fi

# The live ISO's installer session runs as root: it already is the machine's
# admin (and root has no usable password there), so just open the terminal.
[ "$(id -u)" = 0 ] && exec "$PEEK" "$LOG_TARGET"

POLICY="$(cat /etc/layerosx/terminal 2>/dev/null || true)"
[ "$POLICY" = off ] && exit 0

BACKEND=/opt/layerosx/panel/layerosx_backend.py
check() { printf '%s\n' "$1" | python3 "$BACKEND" check-maint-password >/dev/null 2>&1; }
check "" ; rc=$?
[ "$rc" = 2 ] && exec "$PEEK" "$LOG_TARGET"      # no Maintenance password set

for attempt in 1 2 3; do
    pw="$(zenity --password --title="$T" \
        --text="Maintenance — enter the Maintenance password." 2>/dev/null)" || exit 0
    if check "$pw"; then
        unset pw
        printf '%s maintenance terminal unlocked\n' "$(date '+%F %T')" >> "$AUTH_LOG"
        exec "$PEEK" "$LOG_TARGET"
    fi
    unset pw
    printf '%s failed maintenance login (attempt %s)\n' "$(date '+%F %T')" "$attempt" >> "$AUTH_LOG"
    sleep $((attempt * 2))
    [ "$attempt" -lt 3 ] && zenity --error --width=320 --title="$T" --timeout=3 --text="Wrong password." 2>/dev/null
done
exit 1
