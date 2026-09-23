#!/usr/bin/env bash
# Shared: the EFFECTIVE value of each VM toggle -- the user's choice if one is
# saved under /var/lib/layerosx, otherwise the build mode's default (the same
# defaults mac-vm-launch.sh applies; keep the two in sync):
#   release: gfx=reims  verbose=off audio=on
#   debug:   gfx=vmware verbose=on  audio=off
# Sourced by the gpu/verbose/audio/macstatus commands and lib/kiosk-menu.sh, so
# "show current setting" never disagrees with what the next launch will do.
LAYEROSX_STATE_DIR="/var/lib/layerosx"
LAYEROSX_MODE="$(cat /etc/layerosx/mode 2>/dev/null || echo release)"
case "$LAYEROSX_MODE" in debug) : ;; *) LAYEROSX_MODE=release ;; esac

_mode_default() {  # $1 = gfx|verbose|audio
    case "$LAYEROSX_MODE:$1" in
        debug:gfx) echo vmware ;;   release:gfx) echo reims ;;
        debug:verbose) echo on ;;   release:verbose) echo off ;;
        debug:audio) echo off ;;    release:audio) echo on ;;
    esac
}

# Prints the normalized effective value: gfx -> reims|vmware|std,
# verbose/audio -> on|off.
effective_setting() {
    local v; v="$(cat "$LAYEROSX_STATE_DIR/$1" 2>/dev/null || true)"
    [ -n "$v" ] || v="$(_mode_default "$1")"
    case "$1" in
        gfx)
            case "$v" in
                reims|reims-vgpu-pci) echo reims ;;
                std|std-vga|vga) echo std ;;
                *) echo vmware ;;
            esac ;;
        *)
            case "$v" in on|1|yes|true|ON|On) echo on ;; *) echo off ;; esac ;;
    esac
}

# "(saved)" when the user chose it, "(build default)" otherwise.
setting_origin() { [ -s "$LAYEROSX_STATE_DIR/$1" ] && echo "saved" || echo "$LAYEROSX_MODE build default"; }
