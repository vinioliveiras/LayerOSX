#!/usr/bin/env bash
# Ctrl+Alt+W: open LayerOSX Settings (the GTK4/libadwaita panel,
# /opt/layerosx/panel/layerosx_panel.py). If the panel can't start (GTK stack
# missing/broken), fall back to the zenity kiosk menu so the machine is never
# left without a way to switch graphics, restart or reach the terminal.
set -uo pipefail
PANEL=/opt/layerosx/panel/layerosx_panel.py
LIB=/opt/layerosx/kiosk/lib
LOG="$HOME/panel.log"

if python3 -c 'import gi; gi.require_version("Gtk","4.0"); gi.require_version("Adw","1"); from gi.repository import Gtk, Adw' 2>>"$LOG"; then
    start=$(date +%s)
    python3 "$PANEL" 2>>"$LOG"
    rc=$?
    # A crash right at start-up (not a normal close) -> fall back.
    if [ "$rc" -ne 0 ] && [ $(( $(date +%s) - start )) -lt 3 ]; then
        echo "$(date '+%F %T') panel exited with $rc at start-up -- falling back to the zenity menu" >> "$LOG"
        exec "$LIB/kiosk-menu.sh"
    fi
    exit 0
fi
echo "$(date '+%F %T') GTK4/libadwaita not available -- using the zenity menu" >> "$LOG"
exec "$LIB/kiosk-menu.sh"
