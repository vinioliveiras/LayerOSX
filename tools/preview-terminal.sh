#!/usr/bin/env bash
# Preview the LayerOSX Terminal (Ctrl+Alt+T) on your own Linux desktop, from
# the repo. It's a real shell on THIS machine (not a dry run).
# Needs python-gobject + gtk4 + libadwaita + vte4 (sudo pacman -S vte4).
#   LAYEROSX_PANEL_THEME=dark tools/preview-terminal.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$REPO/archiso/airootfs/opt/layerosx/panel/layerosx_terminal.py" "${1:-$HOME/.bash_history}"
