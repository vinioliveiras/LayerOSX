#!/usr/bin/env bash
# What Ctrl+Alt+T opens (lib/maint-terminal.sh): a REAL terminal, not just a read-only log tail --
# shows the last bit of whatever's happening right now, then drops
# into an interactive shell so commands can actually be run (ps,
# lsblk, journalctl, cat a status file, whatever's needed) while the
# install/wizard keeps running in the background untouched. Type
# `logs` any time to go back to watching the log live (Ctrl-C stops
# watching and hands the prompt back -- doesn't affect what it's
# tailing, or anything else).
set -uo pipefail
LOG="${1:-/var/log/layerosx-install.log}"

RCFILE=$(mktemp)
cat > "$RCFILE" <<RCEOF
export LOG="$LOG"
logs() { tail -n 200 -f "\$LOG" 2>/dev/null || echo "Nothing to show yet."; }
export SERIAL_LOG="\$HOME/mac-vm-serial.log"
serial() { tail -n 200 -f "\$SERIAL_LOG" 2>/dev/null || echo "No guest serial log yet (the VM hasn't been launched on this boot)."; }
echo "LayerOSX -- live terminal. Last lines of \$LOG:"
echo
tail -n 40 "\$LOG" 2>/dev/null || echo "(nothing logged yet)"
echo
echo "Type 'logs' to follow it live, or 'serial' for the guest's own firmware/kernel console (OpenCore + XNU boot log). Ctrl-C stops watching, back to this prompt. Any other command works too."
RCEOF

xterm -fa Monospace -fs 12 -bg black -fg white \
    -T "LayerOSX — terminal (safe to close any time)" \
    -e bash --rcfile "$RCFILE" -i

rm -f "$RCFILE"
