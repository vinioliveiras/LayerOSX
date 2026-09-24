#!/usr/bin/env bash
# Bring an already-open LayerOSX window back to the front.
#   raise-window.sh <window-name-regex>
# Used when a hotkey is pressed while its window is still open but hidden
# behind the fullscreen VM (clicking the VM puts it on top): the second press
# used to do nothing because the single-instance lock was taken. xdotool's
# windowactivate goes through _NET_ACTIVE_WINDOW, which openbox honours.
set -uo pipefail
[ -n "${1:-}" ] || exit 2
command -v xdotool >/dev/null 2>&1 || exit 1
wid="$(xdotool search --name "$1" 2>/dev/null | tail -n1)"
[ -n "$wid" ] || exit 1
xdotool windowmap "$wid" 2>/dev/null
xdotool windowactivate "$wid" 2>/dev/null || xdotool windowraise "$wid" 2>/dev/null
