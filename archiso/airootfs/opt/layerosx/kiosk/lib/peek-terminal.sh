#!/usr/bin/env bash
# What F2 opens: a plain read-only terminal tailing whatever's
# actually happening right now. Purely a peek window -- closing it
# (Ctrl+D, or the window's own close button) doesn't stop or affect
# whatever it was tailing, and opening it doesn't pause anything
# either.
set -uo pipefail
LOG="${1:-/var/log/layerosx-install.log}"

xterm -fa Monospace -fs 12 -bg black -fg white \
    -T "LayerOSX — what's happening right now (safe to close any time)" \
    -e bash -c "tail -n 200 -f \"$LOG\" 2>/dev/null || echo 'Nothing to show yet.'; echo; read -r -p 'Press Enter to close...' _"
