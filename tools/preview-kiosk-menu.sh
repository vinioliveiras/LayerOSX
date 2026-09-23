#!/usr/bin/env bash
# Preview the Ctrl+Alt+W kiosk menu on your own Linux desktop, straight from
# the repo -- no ISO build. Runs lib/kiosk-menu.sh in DRY-RUN mode: every
# action that would change something (graphics/boot log/audio, restarting the
# Mac or the computer, diagnostics, terminal) just shows what it WOULD run.
# The Wi-Fi and USB pickers are the real ones (NetworkManager / sysfs), so
# connecting to a network from the preview really connects this machine.
#
# Needs: zenity (sudo pacman -S zenity), NetworkManager for the Wi-Fi status.
# The status line shows the build defaults (release: Reims / boot log off /
# audio on) since this machine has no /var/lib/layerosx settings.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
command -v zenity >/dev/null || { echo "zenity not found -- install it first (sudo pacman -S zenity)." >&2; exit 1; }
export LAYEROSX_LIB="$REPO/archiso/airootfs/opt/layerosx/kiosk/lib"
export LAYEROSX_DRY_RUN=1
exec bash "$LAYEROSX_LIB/kiosk-menu.sh"
