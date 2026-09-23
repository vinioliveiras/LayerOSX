#!/usr/bin/env bash
# Host-side battery guard for the macOS VM (macOS itself can't see the laptop
# battery). Started in the background from the kiosk user's .xinitrc, so it
# can show zenity notices on top of the fullscreen VM.
#
# While DISCHARGING:
#   <= 20% and <= 10%  -> one warning each (re-armed once the charger is back)
#   <= 5%  (critical)  -> ACPI power-button to the guest (system_powerdown) so
#                         macOS can shut down cleanly; its Shut Down then powers
#                         the host off through the normal qmp-watch path
#   <= 3%, or 3 min after the critical request with macOS still running
#                      -> last resort: QMP quit (QEMU stops and flushes its
#                         disk images) + flag file; mac-vm-launch.sh sees the
#                         flag and powers the host off instead of relaunching
# Laptops only: exits at once if there's no BAT* power supply.
set -uo pipefail

CTL_SOCK="/tmp/macvm-ctl.sock"
FLAG="/tmp/layerosx-battery-poweroff"
QMP_CMD="/opt/layerosx/kiosk/lib/qmp-cmd.py"
LOG="$HOME/battery-watch.log"
WARN_LEVELS=(20 10)
CRIT=5
EMERG=3
GRACE=180      # seconds macOS gets to shut down after the critical request
INTERVAL="${BATTERY_WATCH_INTERVAL:-30}"

# BATTERY_PATH / BATTERY_WATCH_INTERVAL: test overrides (fake sysfs dir, faster polling).
BAT="${BATTERY_PATH:-$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -n1)}"
[ -n "$BAT" ] || exit 0

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
notify() {
    zenity --warning --width=440 --timeout=25 --title="LayerOSX — Battery" \
        --text="$1" 2>/dev/null &
}

warned=""        # levels already announced during this discharge
crit_at=0        # when the critical shutdown was requested (0 = not yet)
log "battery-watch started ($BAT)"

while sleep "$INTERVAL"; do
    cap="$(cat "$BAT/capacity" 2>/dev/null)" || continue
    status="$(cat "$BAT/status" 2>/dev/null)"
    case "$cap" in ''|*[!0-9]*) continue ;; esac

    if [ "$status" != "Discharging" ]; then
        if [ "$crit_at" != 0 ] || [ -n "$warned" ]; then log "charging again at ${cap}% -- re-armed"; fi
        warned=""; crit_at=0
        continue
    fi

    # One warning for the lowest newly-crossed level (starting at 8% => one
    # notice, not two).
    hit=""
    for l in "${WARN_LEVELS[@]}"; do
        if [ "$cap" -le "$l" ] && [[ " $warned " != *" $l "* ]]; then
            warned+=" $l"; hit="$l"
        fi
    done
    if [ -n "$hit" ] && [ "$cap" -gt "$CRIT" ]; then
        log "warning at ${cap}%"
        notify "Battery at ${cap}%.\n\nPlug in the charger. macOS will be shut down automatically at ${CRIT}%."
    fi

    if [ "$cap" -le "$CRIT" ] && [ "$crit_at" -eq 0 ]; then
        crit_at="$(date +%s)"
        log "critical at ${cap}% -- sending system_powerdown to the guest"
        notify "Battery critical (${cap}%).\n\nShutting macOS down now — save your work. The computer turns off right after."
        python3 "$QMP_CMD" "$CTL_SOCK" system_powerdown >>"$LOG" 2>&1 || log "system_powerdown failed (VM not running?)"
    fi

    if [ "$crit_at" -gt 0 ]; then
        waited=$(( $(date +%s) - crit_at ))
        if [ "$cap" -le "$EMERG" ] || [ "$waited" -ge "$GRACE" ]; then
            log "emergency at ${cap}% (${waited}s after the request) -- QMP quit + host poweroff"
            touch "$FLAG"
            python3 "$QMP_CMD" "$CTL_SOCK" quit >>"$LOG" 2>&1 || true
            sleep 20
            # Launcher normally powers off on the flag; this is the fallback if
            # it isn't running.
            sudo systemctl poweroff
            exit 0
        fi
    fi
done
