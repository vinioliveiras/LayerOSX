#!/usr/bin/env bash
# USB passthrough for the macOS VM: hand a host USB device (pendrive, phone,
# webcam, MIDI, ...) to the guest, take it back, and optionally remember it so
# it's given to the Mac on every launch and every re-plug.
#
# How: QEMU `usb-host` matched by vendor/product id on the VM's xHCI bus,
# hot-added over the control QMP socket (lib/qmp-cmd.py). Matching by
# vendor/product (not bus/address) means QEMU re-attaches the device to the
# guest by itself whenever it's re-plugged. Remembered devices live in
# $USB_FILE and are added at launch by mac-vm-launch.sh.
#
# Never offered (they'd take input away from the host, or are the host's own):
#   * hubs and root hubs
#   * devices with a HID keyboard/mouse interface -- keyboard, touchpad and
#     mouse input already reach macOS through the host, and passing the
#     laptop's own (USB) keyboard would lock the host out
#   * storage with a partition mounted on the host (unmount it first)
# Internal devices (sysfs removable=fixed: built-in webcam, Bluetooth,
# fingerprint reader) are allowed but labelled "(built-in)".
#
#   usb-passthrough.sh --pick    zenity picker (usb command / Ctrl+Alt+U)
#   or source it for the functions (usb_devices, usb_attach, ...).
set -uo pipefail

CTL_SOCK="/tmp/macvm-ctl.sock"
QMP_CMD="/opt/layerosx/kiosk/lib/qmp-cmd.py"
USB_FILE="/var/lib/layerosx/usb-passthrough"   # lines: "vvvv:pppp  name"
SYSFS_USB="${USB_SYSFS_ROOT:-/sys/bus/usb/devices}"  # test override

_rd() { cat "$1" 2>/dev/null | tr -d '\n'; }

# Why a device can't be passed through (empty = OK).
_blocked_reason() {
    local d="$1" itf cls proto blk
    [ "$(_rd "$d/bDeviceClass")" = "09" ] && { echo "hub"; return; }
    for itf in "$d"/*:*; do
        [ -e "$itf/bInterfaceClass" ] || continue
        cls="$(_rd "$itf/bInterfaceClass")"; proto="$(_rd "$itf/bInterfaceProtocol")"
        if [ "$cls" = "03" ] && { [ "$proto" = "01" ] || [ "$proto" = "02" ]; }; then
            echo "keyboard/mouse (already shared with the Mac)"; return
        fi
    done
    for blk in $(find "$d"/ -maxdepth 6 -path '*/block/*' -name 'sd*' -printf '%f\n' 2>/dev/null | sort -u); do
        if grep -q "^/dev/${blk}[0-9]* " /proc/mounts 2>/dev/null; then
            echo "mounted on the host (/dev/$blk) -- unmount it first"; return
        fi
    done
}

# TSV: vid pid name removable blocked_reason   (one line per device)
usb_devices() {
    local d vid pid name rem
    for d in "$SYSFS_USB"/*; do
        [ -e "$d/idVendor" ] || continue
        case "$(basename "$d")" in usb*|*:*) continue ;; esac  # root hubs / interfaces
        vid="$(_rd "$d/idVendor")"; pid="$(_rd "$d/idProduct")"
        name="$(_rd "$d/manufacturer") $(_rd "$d/product")"
        name="$(echo "$name" | sed 's/^ *//; s/ *$//')"; [ -n "$name" ] || name="USB device $vid:$pid"
        rem="$(_rd "$d/removable")"
        printf '%s\t%s\t%s\t%s\t%s\n' "$vid" "$pid" "$name" "${rem:-unknown}" "$(_blocked_reason "$d")"
    done
}

usb_attached() { python3 "$QMP_CMD" "$CTL_SOCK" usb-list 2>/dev/null; }   # "vid pid" lines
usb_attach()   { python3 "$QMP_CMD" "$CTL_SOCK" usb-attach "$1" "$2"; }
usb_detach()   { python3 "$QMP_CMD" "$CTL_SOCK" usb-detach "$1" "$2"; }

usb_is_remembered() { grep -qi "^$1:$2\b" "$USB_FILE" 2>/dev/null; }
usb_remember() {
    usb_is_remembered "$1" "$2" && return 0
    mkdir -p "$(dirname "$USB_FILE")" 2>/dev/null
    printf '%s:%s  %s\n' "$1" "$2" "$3" >> "$USB_FILE"
}
usb_forget() {
    [ -f "$USB_FILE" ] || return 0
    local tmp; tmp="$(mktemp)"
    grep -vi "^$1:$2\b" "$USB_FILE" > "$tmp"; cat "$tmp" > "$USB_FILE"; rm -f "$tmp"
}

usb_pick() {
    local T="LayerOSX — USB devices" rows=() att vid pid name rem why state label choice
    if [ ! -S "$CTL_SOCK" ]; then
        zenity --error --width=400 --title="$T" --text="The Mac isn't running." 2>/dev/null; return 1
    fi
    att="$(usb_attached)"
    while IFS="$(printf '\t')" read -r vid pid name rem why; do
        if printf '%s\n' "$att" | grep -qi "^$vid $pid$"; then state="on the Mac"
        elif [ -n "$why" ]; then state="not available: $why"
        else state="on Linux"; fi
        usb_is_remembered "$vid" "$pid" && state="$state (always)"
        label="$name"; [ "$rem" = "fixed" ] && label="$label (built-in)"
        rows+=(FALSE "$vid:$pid" "$label" "$state")
    done < <(usb_devices)
    [ "${#rows[@]}" -gt 0 ] || { zenity --info --width=360 --title="$T" --text="No USB devices found." 2>/dev/null; return 0; }

    choice=$(zenity --list --radiolist --width="${LAYEROSX_DIALOG_W:-720}" --height="${LAYEROSX_DIALOG_H:-420}" --title="$T" \
        --ok-label="Select" --cancel-label="${LAYEROSX_BACK_LABEL:-Cancel}" \
        --text="Pick a device to give to the Mac (or to take back)" \
        --column="" --column="ID" --column="Device" --column="Where" "${rows[@]}" 2>/dev/null) || return 1
    [ -n "$choice" ] || return 1
    vid="${choice%%:*}"; pid="${choice##*:}"
    IFS="$(printf '\t')" read -r _ _ name rem why < <(usb_devices | awk -F'\t' -v v="$vid" -v p="$pid" '$1==v && $2==p' | head -n1)

    if printf '%s\n' "$att" | grep -qi "^$vid $pid$"; then
        zenity --question --width=420 --title="$T" --text="Give \"$name\" back to Linux?\n\n(It also stops being given to the Mac automatically.)" 2>/dev/null || return 1
        usb_detach "$vid" "$pid"; usb_forget "$vid" "$pid"
        return 0
    fi
    if [ -n "${why:-}" ]; then
        zenity --warning --width=420 --title="$T" --text="\"$name\" can't be given to the Mac:\n$why" 2>/dev/null; return 1
    fi
    if ! usb_attach "$vid" "$pid"; then
        zenity --error --width=420 --title="$T" --text="Couldn't give \"$name\" to the Mac (see ~/mac-vm.log)." 2>/dev/null; return 1
    fi
    if zenity --question --width=440 --title="$T" --ok-label="Always" --cancel-label="Just this time" \
        --text="\"$name\" is now on the Mac.\n\nGive it to the Mac automatically every time (also after a restart or re-plug)?" 2>/dev/null; then
        usb_remember "$vid" "$pid" "$name"
    fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        --pick) usb_pick ;;
        *) echo "usage: usb-passthrough.sh --pick   (or source it)" >&2; exit 2 ;;
    esac
fi
