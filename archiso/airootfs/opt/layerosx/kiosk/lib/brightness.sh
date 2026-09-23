#!/usr/bin/env bash
# Panel brightness, remembered across reboots.
#
#   brightness.sh up | down     brightness keys (openbox, both build modes)
#   brightness.sh set <1-100>   LayerOSX Settings > Displays slider
#   brightness.sh restore       session start (.xinitrc): re-apply the last value
#   brightness.sh get           print the current percentage
#
# Every change saves the resulting percentage to $STATE (the kiosk user owns
# /var/lib/layerosx), and `restore` puts it back. systemd-backlight does
# something similar at boot, but on hybrid AMD+NVIDIA laptops it often misses
# (the backlight device changes name between boots, or the GPU driver resets
# it later) -- this runs inside the session, after the drivers are up.
# Never below 5%, so the screen can't end up black.
set -uo pipefail
STATE="${LAYEROSX_STATE_DIR:-/var/lib/layerosx}/brightness"
MIN=5
command -v brightnessctl >/dev/null 2>&1 || exit 0

current() { brightnessctl -m -c backlight 2>/dev/null | awk -F, 'NR==1{gsub("%","",$4); print $4}'; }
save() { local p; p="$(current)"; [ -n "$p" ] && printf '%s\n' "$p" > "$STATE" 2>/dev/null; true; }

case "${1:-}" in
    up)   brightnessctl -q -c backlight set 10%+ && save ;;
    down) brightnessctl -q -c backlight --min-value="$MIN%" set 10%- && save ;;
    set)
        v="${2:-}"; case "$v" in ''|*[!0-9]*) echo "usage: brightness.sh set <1-100>" >&2; exit 2 ;; esac
        [ "$v" -lt "$MIN" ] && v=$MIN; [ "$v" -gt 100 ] && v=100
        brightnessctl -q -c backlight set "$v%" && save ;;
    restore)
        v="$(cat "$STATE" 2>/dev/null)"
        case "$v" in ''|*[!0-9]*) exit 0 ;; esac
        sleep "${LAYEROSX_BRIGHTNESS_DELAY:-2}"   # let the GPU driver finish setting up the backlight
        case "$v" in ''|*[!0-9]*) exit 0 ;; esac
        [ "$v" -lt "$MIN" ] && v=$MIN
        brightnessctl -q -c backlight set "$v%" ;;
    get) current ;;
    *) echo "usage: brightness.sh up|down|set <n>|restore|get" >&2; exit 2 ;;
esac
