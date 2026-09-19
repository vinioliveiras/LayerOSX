#!/usr/bin/env bash
# Zenity-based Wi-Fi picker -- replaces the old "just open nmtui in a
# terminal" flow with something that actually matches the rest of the
# kiosk (a list to click + a password box), instead of a text-mode
# tool that needs Tab/arrow-key/Enter navigation and looks like a
# crash to anyone who's never seen a TUI before.
#
# nmtui is kept one click away as "Advanced" for anything this simple
# picker can't do (WPA-Enterprise/802.1X, captive portals, static IP)
# -- nothing regresses, it's just no longer the only option.
#
# Public entry point: ensure_internet -- returns 0 once there's a
# working connection (already connected, user connected one just now,
# or user chose to skip), 1 if the user gave up/cancelled. Safe to
# source from another script (defines functions only) or run directly
# (connects, standalone, if invoked as its own program).
set -uo pipefail

# Cheap connectivity probe against the exact host fetch-recovery.sh
# needs -- good enough to decide whether to bother the user with
# Wi-Fi setup before even trying the real download.
has_internet() {
    curl -fsS --max-time 5 -o /dev/null https://osrecovery.apple.com 2>/dev/null
}

_wifi_radio_on() {
    nmcli radio wifi 2>/dev/null | grep -qi '^enabled$' && return 0
    nmcli radio wifi on 2>/dev/null
    sleep 1
}

# Prints TAB-separated "SSID<TAB>signal<TAB>security", one line per
# SSID (strongest signal wins if an SSID shows up more than once,
# which happens on multi-AP networks), sorted strongest-first.
_wifi_scan() {
    nmcli device wifi rescan 2>/dev/null || true
    sleep 2
    nmcli -t -f SSID,SIGNAL,SECURITY device wifi list 2>/dev/null | awk -F: '
        BEGIN { OFS = "\t" }
        $1 == "" { next }
        {
            ssid = $1; signal = $2 + 0; sec = $3
            if (!(ssid in best) || signal > best[ssid]) {
                best[ssid] = signal
                secmap[ssid] = sec
            }
        }
        END { for (s in best) print s, best[s], secmap[s] }
    ' | sort -t "$(printf '\t')" -k2,2 -rn
}

_wifi_bars() {
    local sig="$1"
    if   [ "$sig" -ge 80 ]; then printf '((((' # excellent
    elif [ "$sig" -ge 60 ]; then printf '((( '
    elif [ "$sig" -ge 40 ]; then printf '((  '
    else                          printf '(   '
    fi
}

_wifi_connect() {
    local ssid="$1" pass="${2:-}" hidden="${3:-no}" out rc
    if [ -n "$pass" ]; then
        if [ "$hidden" = "yes" ]; then
            out=$(nmcli device wifi connect "$ssid" password "$pass" hidden yes 2>&1)
        else
            out=$(nmcli device wifi connect "$ssid" password "$pass" 2>&1)
        fi
    else
        if [ "$hidden" = "yes" ]; then
            out=$(nmcli device wifi connect "$ssid" hidden yes 2>&1)
        else
            out=$(nmcli device wifi connect "$ssid" 2>&1)
        fi
    fi
    rc=$?
    if [ "$rc" -ne 0 ] || ! has_internet; then
        zenity --error --width=460 --title="LayerOSX — Wi-Fi" \
            --text="Couldn't connect to \"$ssid\".\n\n$out" 2>/dev/null || true
        return 1
    fi
    return 0
}

_wifi_pick_and_connect() {
    _wifi_radio_on

    local -A sec_of=()
    local rows=() ssid signal sec bars secured

    while IFS="$(printf '\t')" read -r ssid signal sec; do
        [ -n "$ssid" ] || continue
        sec_of["$ssid"]="$sec"
        bars="$(_wifi_bars "$signal")"
        if [ -n "$sec" ] && [ "$sec" != "--" ]; then secured="secured"; else secured="open"; fi
        rows+=(FALSE "$ssid" "$bars" "$secured")
    done < <(_wifi_scan)

    rows+=(FALSE "Connect to a hidden network…" "" "")
    rows+=(FALSE "Advanced (nmtui)…" "" "")

    local choice
    choice=$(zenity --list --radiolist --width=560 --height=460 \
        --title="LayerOSX — Wi-Fi" \
        --text="Pick a network" \
        --column="" --column="Network" --column="Signal" --column="" \
        "${rows[@]}" 2>/dev/null)

    [ -n "$choice" ] || return 1

    case "$choice" in
        "Advanced (nmtui)…")
            xterm -fa Monospace -fs 12 -bg black -fg white \
                -T "LayerOSX — Wi-Fi setup (Esc/Q in nmtui when connected)" \
                -e nmtui
            has_internet
            return
            ;;
        "Connect to a hidden network…")
            ssid=$(zenity --entry --width=420 --title="LayerOSX — Wi-Fi" \
                --text="Network name (SSID)" 2>/dev/null)
            [ -n "$ssid" ] || return 1
            local pass
            pass=$(zenity --password --title="LayerOSX — Wi-Fi" \
                --text="Password for \"$ssid\" (leave blank if open)" 2>/dev/null)
            _wifi_connect "$ssid" "$pass" yes
            return
            ;;
    esac

    ssid="$choice"
    sec="${sec_of[$ssid]:-}"
    local pass=""
    if [ -n "$sec" ] && [ "$sec" != "--" ]; then
        pass=$(zenity --password --title="LayerOSX — Wi-Fi" \
            --text="Password for \"$ssid\"" 2>/dev/null)
        [ -n "$pass" ] || return 1
    fi
    _wifi_connect "$ssid" "$pass"
}

ensure_internet() {
    has_internet && return 0
    while true; do
        zenity --question --width=480 --title="LayerOSX — first run" \
            --text="No internet connection detected, and downloading macOS needs one.\n\nSet up Wi-Fi now?" \
            --ok-label="Set up Wi-Fi" --cancel-label="Cancel" 2>/dev/null || return 1
        _wifi_pick_and_connect && break
        zenity --question --width=480 --title="LayerOSX — Wi-Fi" \
            --text="Still not connected. Try again? (Or Cancel to use the 'pick a file' option instead, if you already have macOS on a disk/USB drive.)" \
            --ok-label="Try again" --cancel-label="Cancel" 2>/dev/null || return 1
    done
    has_internet
}

# Allow running this file directly too (not just sourcing it).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    ensure_internet
fi
