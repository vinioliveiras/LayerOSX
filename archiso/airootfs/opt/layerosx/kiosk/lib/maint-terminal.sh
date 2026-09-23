#!/usr/bin/env bash
# Ctrl+Alt+T maintenance terminal (was F2). Policy is baked at build time into
# /etc/layerosx/terminal (LAYEROSX_TERMINAL=password|open|off, see build.sh);
# default follows the build mode (debug=open, release=password):
#
#   open     -> opens the live terminal straight away (developer build).
#   password -> asks for the kiosk user's ("mac") password first, so the
#               appliance stays locked for whoever is at the keyboard but is
#               still maintainable (gpu/verbose/audio/relaunch, logs, macdiag,
#               and -- via the kiosk user's sudo -- the whole host).
#   off      -> the chord does nothing (fully locked appliance).
#
# The password is checked with PAM's own unix_chkpwd helper, which lets a user
# verify THEIR OWN password without root (it refuses to run on a tty, so it is
# fed through a pipe). No password is stored or logged here; failed attempts go
# to ~/maint-auth.log with a timestamp only. 3 tries per press, with a short
# growing delay between them.
#
# $1 = log file the terminal shows/follows (passed through to peek-terminal.sh).
set -uo pipefail
LOG_TARGET="${1:-$HOME/mac-vm.log}"
MODE="$(cat /etc/layerosx/mode 2>/dev/null || echo release)"
PEEK=/opt/layerosx/kiosk/lib/peek-terminal.sh
AUTH_LOG="$HOME/maint-auth.log"
T="LayerOSX — Maintenance"

# One terminal at a time (the chord mashed repeatedly shouldn't stack dialogs).
exec 9>"/tmp/layerosx-maint-$(id -u).lock"
flock -n 9 || exit 0

# The live ISO's installer session runs as root: it already is the machine's
# admin (and root has no usable password there), so just open the terminal.
[ "$(id -u)" = 0 ] && exec "$PEEK" "$LOG_TARGET"

POLICY="$(cat /etc/layerosx/terminal 2>/dev/null || true)"
if [ -z "$POLICY" ]; then [ "$MODE" = debug ] && POLICY=open || POLICY=password; fi
case "$POLICY" in
    open) exec "$PEEK" "$LOG_TARGET" ;;
    off)  exit 0 ;;
    *)    : ;;  # password (also any unknown value: fail closed, not open)
esac

CHK="$(command -v unix_chkpwd || true)"
for c in /usr/bin/unix_chkpwd /usr/sbin/unix_chkpwd; do [ -n "$CHK" ] || { [ -x "$c" ] && CHK="$c"; }; done
if [ -z "$CHK" ]; then
    zenity --error --width=420 --title="$T" --text="Can't verify passwords on this system (unix_chkpwd missing)." 2>/dev/null
    exit 1
fi

user="$(id -un)"
for attempt in 1 2 3; do
    pw="$(zenity --password --title="$T" \
        --text="Maintenance terminal — enter the password for \"$user\"." 2>/dev/null)" || exit 0
    if printf '%s\0' "$pw" | "$CHK" "$user" nonull >/dev/null 2>&1; then
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
