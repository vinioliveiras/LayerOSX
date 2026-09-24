#!/usr/bin/env bash
# Power mode (Settings > Battery > Power mode): how hard the host CPU runs.
# macOS can't manage the real CPU clock -- its cores are host threads -- so
# this is the one place that decides it. Runs as root (systemd at boot, a
# udev rule on charger plug/unplug, the panel via sudo).
#
#   power-mode.sh restore        apply the saved mode (auto -> by charger)
#   power-mode.sh apply <mode>   save and apply: auto|performance|balanced|power-saver
#   power-mode.sh status         what's applied, as key=value lines
#
# What a mode sets, where the hardware has it:
#   * cpufreq: governor "performance" for Performance; otherwise "powersave"
#     plus the energy_performance_preference hint (EPP: balance_performance /
#     power) on amd-pstate-epp / intel_pstate, or schedutil / powersave on
#     plain acpi-cpufreq.
#   * ACPI platform_profile (the laptop maker's fan/power limits, e.g. ASUS
#     Silent/Balanced/Turbo): performance / balanced / low-power or quiet.
# auto = Performance on the charger (or with no battery), Balanced on battery.
set -uo pipefail
STATE_DIR="${LAYEROSX_STATE_DIR:-/var/lib/layerosx}"
CPUFREQ="${LAYEROSX_CPUFREQ:-/sys/devices/system/cpu/cpufreq}"
PROFILE="${LAYEROSX_PLATFORM_PROFILE:-/sys/firmware/acpi/platform_profile}"
PSU="${LAYEROSX_POWER_SUPPLY:-/sys/class/power_supply}"
RUN_FILE="${LAYEROSX_POWER_RUN:-/run/layerosx-power-mode}"

_rd() { cat "$1" 2>/dev/null | tr -d '\n'; }
_has() { case " $(_rd "$1") " in *" $2 "*) return 0 ;; esac; return 1; }
_wr() { [ -w "$1" ] || [ -e "$1" ] || return 1; printf '%s' "$2" > "$1" 2>/dev/null; }

on_ac() {
    local p bat=0
    for p in "$PSU"/*; do
        case "${p##*/}" in BAT*) bat=1 ;; esac
        [ -e "$p/type" ] || continue
        case "$(_rd "$p/type")" in
            Mains|USB) [ "$(_rd "$p/online")" = 1 ] && return 0 ;;
            Battery) bat=1 ;;
        esac
    done
    [ "$bat" = 0 ]          # no battery at all: a desktop, always "on AC"
}

saved() {
    local m; m="$(_rd "$STATE_DIR/power-mode")"
    case "$m" in performance|balanced|power-saver) echo "$m" ;; *) echo auto ;; esac
}

effective() {
    local m; m="$(saved)"
    if [ "$m" = auto ]; then on_ac && m=performance || m=balanced; fi
    echo "$m"
}

apply_cpufreq() {   # $1 = performance|balanced|power-saver
    local pol gov epp
    for pol in "$CPUFREQ"/policy*; do
        [ -d "$pol" ] || continue
        if [ -e "$pol/energy_performance_preference" ]; then
            if [ "$1" = performance ] && _has "$pol/scaling_available_governors" performance; then
                _wr "$pol/scaling_governor" performance
                continue
            fi
            _has "$pol/scaling_available_governors" powersave && _wr "$pol/scaling_governor" powersave
            case "$1" in
                performance) epp=performance ;;
                balanced)    epp=balance_performance ;;
                *)           epp=power ;;
            esac
            _has "$pol/energy_performance_available_preferences" "$epp" || epp=default
            _wr "$pol/energy_performance_preference" "$epp"
        else
            case "$1" in
                performance) gov=performance ;;
                balanced)    gov=schedutil ;;
                *)           gov=powersave ;;
            esac
            _has "$pol/scaling_available_governors" "$gov" || gov=schedutil
            _has "$pol/scaling_available_governors" "$gov" && _wr "$pol/scaling_governor" "$gov"
        fi
    done
}

apply_profile() {
    local want c
    [ -e "$PROFILE" ] || return 0
    case "$1" in
        performance) want="performance balanced-performance" ;;
        balanced)    want="balanced" ;;
        *)           want="low-power quiet cool balanced" ;;
    esac
    for c in $want; do
        if _has "${PROFILE}_choices" "$c"; then _wr "$PROFILE" "$c"; return; fi
    done
}

apply_effective() {
    local m; m="$(effective)"
    apply_cpufreq "$m"
    apply_profile "$m"
    printf '%s\n' "$m" > "$RUN_FILE" 2>/dev/null || true
    echo "power mode: $(saved) -> $m"
}

case "${1:-}" in
    restore) apply_effective ;;
    apply)
        case "${2:-}" in auto|performance|balanced|power-saver) ;; *) echo "usage: power-mode.sh apply <auto|performance|balanced|power-saver>" >&2; exit 2 ;; esac
        mkdir -p "$STATE_DIR"
        if [ "$2" = auto ]; then rm -f "$STATE_DIR/power-mode"; else printf '%s\n' "$2" > "$STATE_DIR/power-mode"; fi
        apply_effective ;;
    status)
        pol="$(ls -d "$CPUFREQ"/policy* 2>/dev/null | head -1)"
        echo "saved=$(saved)"
        echo "effective=$(effective)"
        echo "on_ac=$(on_ac && echo yes || echo no)"
        echo "driver=$(_rd "$pol/scaling_driver")"
        echo "governor=$(_rd "$pol/scaling_governor")"
        echo "epp=$(_rd "$pol/energy_performance_preference")"
        echo "profile=$(_rd "$PROFILE")"
        echo "profile_choices=$(_rd "${PROFILE}_choices")" ;;
    *) echo "usage: power-mode.sh restore | apply <mode> | status" >&2; exit 2 ;;
esac
