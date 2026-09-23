#!/usr/bin/env bash
# Preview LayerOSX Settings (the Ctrl+Alt+W panel) on your own Linux desktop,
# straight from the repo -- no ISO build. DRY RUN: every action that would
# change something (graphics, sound, boot log, USB, restarts, terminal) only
# shows "Preview — would run: ...". Status (Wi-Fi, battery, brightness) is this
# machine's real one, and the Wi-Fi page is real too (joining a network really
# joins it).
#
# Needs python-gobject + gtk4 + libadwaita (a GNOME desktop already has them;
# otherwise: sudo pacman -S python-gobject gtk4 libadwaita).
#   LAYEROSX_PANEL_THEME=dark tools/preview-panel.sh    # dark variant
#   LAYEROSX_PANEL_PAGE=usb   tools/preview-panel.sh    # open on a section
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
export LAYEROSX_LIB="$REPO/archiso/airootfs/opt/layerosx/kiosk/lib"
export LAYEROSX_DRY_RUN=1
exec python3 "$REPO/archiso/airootfs/opt/layerosx/panel/layerosx_panel.py"
