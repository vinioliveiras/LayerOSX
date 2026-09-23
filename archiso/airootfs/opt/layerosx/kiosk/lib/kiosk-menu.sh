#!/usr/bin/env bash
# LayerOSX kiosk menu (Ctrl+Alt+W, both build modes): one place for everything
# the locked kiosk needs without a terminal -- status at a glance, Wi-Fi, USB,
# the VM toggles (graphics / boot log / audio), restarting the Mac or the whole
# computer, diagnostics, and the (password-gated) maintenance terminal.
#
# Actions that restart things always ask first. "Restart the Mac" relaunches
# only the VM (a hard stop for macOS -- the rescue for a stuck/black screen;
# when macOS works, its own Apple menu > Restart is the clean way and also
# restarts the computer). "Restart/Shut down computer" stop QEMU with QMP quit
# (disk images flushed) and leave the action in $HOST_ACTION_FILE for
# mac-vm-launch.sh, which then reboots/powers off instead of relaunching.
#
# Preview on any Linux desktop (no ISO build): tools/preview-kiosk-menu.sh, i.e.
#   LAYEROSX_LIB=<repo>/archiso/airootfs/opt/layerosx/kiosk/lib LAYEROSX_DRY_RUN=1 kiosk-menu.sh
# LAYEROSX_DRY_RUN=1 shows what each action WOULD run instead of doing it
# (changing settings, relaunching, rebooting, terminal). Wi-Fi/USB pickers stay
# real -- they only use NetworkManager / sysfs.
set -uo pipefail
LIB="${LAYEROSX_LIB:-/opt/layerosx/kiosk/lib}"
BIN="${LAYEROSX_BIN:-/usr/local/bin}"
DRY_RUN="${LAYEROSX_DRY_RUN:-0}"
# shellcheck source=/dev/null
source "$LIB/settings.sh"
CTL_SOCK="/tmp/macvm-ctl.sock"
HOST_ACTION_FILE="/tmp/layerosx-host-action"
T="LayerOSX"

exec 9>"/tmp/layerosx-menu-$(id -u).lock"
flock -n 9 || exit 0

# Run an action, or in preview mode just show it.
act() {
    if [ "$DRY_RUN" = 1 ]; then
        zenity --info --width=420 --title="$T — preview" --text="Would run:\n$*" 2>/dev/null
        return 0
    fi
    "$@"
}

ask() { zenity --question --width=440 --title="$T" --ok-label="${2:-Yes}" --cancel-label="Back" --text="$1" 2>/dev/null; }
note() { zenity --info --width=400 --timeout=5 --title="$T" --text="$1" 2>/dev/null; }

vm_running() { [ -S "$CTL_SOCK" ]; }
relaunch_vm() { act "$BIN/relaunch"; }

apply_and_offer_restart() {  # $1 = what changed (for the message)
    if vm_running && zenity --question --width=440 --title="$T" --ok-label="Restart now" --cancel-label="Later" \
            --text="$1\n\nRestart the Mac now to apply it?\n(macOS is stopped abruptly — save your work first.)" 2>/dev/null; then
        relaunch_vm
    else
        note "$1\nIt applies the next time the Mac starts."
    fi
}

host_action() {  # $1 = reboot|poweroff
    if [ "$DRY_RUN" = 1 ]; then act python3 "$LIB/qmp-cmd.py" "$CTL_SOCK" quit '&&' systemctl "$1"; return; fi
    printf '%s\n' "$1" > "$HOST_ACTION_FILE"
    if vm_running; then
        python3 "$LIB/qmp-cmd.py" "$CTL_SOCK" quit >/dev/null 2>&1 || relaunch_vm
    fi
    # Fallback if the launcher isn't there to act on the file.
    sleep 15
    [ -e "$HOST_ACTION_FILE" ] && { rm -f "$HOST_ACTION_FILE"; sudo systemctl "$1"; }
}

status_text() {
    local wifi bat="" b gfx
    wifi="$(nmcli -t -f ACTIVE,SSID device wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')"
    [ -n "$wifi" ] || { nmcli -t -f TYPE,STATE device 2>/dev/null | grep -q '^ethernet:connected' && wifi="wired" || wifi="not connected"; }
    b="$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -n1)"
    [ -n "$b" ] && bat="   ·   Battery: $(cat "$b/capacity" 2>/dev/null)% ($(cat "$b/status" 2>/dev/null))"
    case "$(effective_setting gfx)" in reims) gfx="Reims (accelerated)" ;; std) gfx="std VGA" ;; *) gfx="VMware" ;; esac
    printf 'Wi-Fi: %s%s\nGraphics: %s   ·   Boot log: %s   ·   Audio: %s   ·   Mac: %s' \
        "$wifi" "$bat" "$gfx" "$(effective_setting verbose)" "$(effective_setting audio)" \
        "$(vm_running && echo running || echo stopped)"
}

menu_graphics() {
    local cur choice
    cur="$(effective_setting gfx)"
    choice=$(zenity --list --radiolist --width=$W --height=$H --title="$T — Graphics" \
        --ok-label="Apply" --cancel-label="Back" \
        --text="Graphics adapter for the Mac (current: $cur)" \
        --column="" --column="id" --column="Adapter" --hide-column=2 --print-column=2 \
        "$([ "$cur" = reims ] && echo TRUE || echo FALSE)"  reims  "Reims — hardware-accelerated (alpha)" \
        "$([ "$cur" = vmware ] && echo TRUE || echo FALSE)" vmware "VMware — reliable, not accelerated (use if the screen stays black)" \
        "$([ "$cur" = std ] && echo TRUE || echo FALSE)"    std    "Standard VGA — diagnostics only" \
        2>/dev/null) || return
    [ -n "$choice" ] && [ "$choice" != "$cur" ] || return
    act "$BIN/gpu" "$choice"
    apply_and_offer_restart "Graphics set to $choice."
}

toggle() {  # $1 = verbose|audio, $2 = label
    local cur new
    cur="$(effective_setting "$1")"; [ "$cur" = on ] && new=off || new=on
    ask "$2 is $cur. Turn it $new?" || return
    act "$BIN/$1" "$new"
    apply_and_offer_restart "$2 turned $new."
}

# Every dialog shares one size so going menu -> sub-screen -> menu doesn't jump
# around (zenity opens one window per dialog; it can't keep a single window).
W=620; H=480

main() {
    local items=() choice terminal_policy
    terminal_policy="$(cat /etc/layerosx/terminal 2>/dev/null || true)"
    items+=(wifi     "Wi-Fi…")
    items+=(usb      "USB devices…")
    items+=(gfx      "Graphics…")
    items+=(verbose  "Boot log (verbose): $(effective_setting verbose) — switch")
    items+=(audio    "Audio: $(effective_setting audio) — switch")
    items+=(macrestart "Restart the Mac (if it's stuck or the screen is black)")
    items+=(reboot   "Restart computer")
    items+=(poweroff "Shut down computer")
    items+=(diag     "Save diagnostics to a USB drive")
    [ "$terminal_policy" = off ] || items+=(terminal "Maintenance terminal…")

    # Returns 1 when the user closes the menu, 0 to show it again.
    choice=$(zenity --list --width=$W --height=$H --title="$T — Menu" \
        --text="$(status_text)" --ok-label="Open" --cancel-label="Close" \
        --column="id" --column="" --hide-column=1 --print-column=1 --hide-header \
        "${items[@]}" 2>/dev/null) || return 1
    choice="${choice%%|*}"

    # Sub-screens return here ("Back" = their cancel button), so the menu
    # comes straight back after every action. Only actions that end the
    # session (restarts, opening the terminal) leave the menu.
    case "$choice" in
        wifi)     "$LIB/wifi-setup.sh" --pick ;;
        usb)      "$LIB/usb-passthrough.sh" --pick ;;
        gfx)      menu_graphics ;;
        verbose)  toggle verbose "Boot log" ;;
        audio)    toggle audio "Audio" ;;
        macrestart)
            ask "Restart the Mac?\n\nmacOS is stopped abruptly and starts again (unsaved work is lost). Use this when it's stuck; otherwise use Apple menu > Restart." \
                && { relaunch_vm; [ "$DRY_RUN" = 1 ] || return 1; } ;;
        reboot)   ask "Restart the computer?\n\nSave your work in macOS first — it will be stopped." && { host_action reboot; [ "$DRY_RUN" = 1 ] || return 1; } ;;
        poweroff) ask "Shut down the computer?\n\nSave your work in macOS first — it will be stopped." && { host_action poweroff; [ "$DRY_RUN" = 1 ] || return 1; } ;;
        diag)
            if [ "$DRY_RUN" = 1 ]; then act "$BIN/macdiag" usb
            elif "$BIN/macdiag" usb 2>&1 | grep -q '^Copied'; then note "Diagnostics saved to the USB drive."
            else zenity --warning --width=380 --title="$T" --text="Couldn't save — plug in a writable USB drive and try again." 2>/dev/null; fi ;;
        terminal)
            if [ "$DRY_RUN" = 1 ]; then act "$LIB/maint-terminal.sh" "$HOME/mac-vm.log"
            else "$LIB/maint-terminal.sh" "$HOME/mac-vm.log" & return 1; fi ;;
    esac
    return 0
}

# Sub-screens (Wi-Fi / USB pickers) label their cancel button "Back" and use
# the menu's size when opened from here.
export LAYEROSX_BACK_LABEL="Back" LAYEROSX_DIALOG_W=$W LAYEROSX_DIALOG_H=$H

while main; do :; done
