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

# LayerOSX Terminal (GTK4 + VTE, same macOS-style frame as LayerOSX Settings,
# light/dark from Settings > Appearance). Falls back to the xterm below if GTK or
# VTE can't start (missing packages, broken GL...). Access control (password
# policy) happens before this, in lib/maint-terminal.sh.
TERM_APP=/opt/layerosx/panel/layerosx_terminal.py
if python3 -c 'import gi; gi.require_version("Gtk","4.0"); gi.require_version("Adw","1"); gi.require_version("Vte","3.91"); from gi.repository import Vte' 2>>"$HOME/panel.log"; then
    start=$(date +%s)
    python3 "$TERM_APP" "$LOG" 2>>"$HOME/panel.log" && { rm -f "$RCFILE"; exit 0; }
    # A crash right at start-up -> fall through to xterm; a normal close -> done.
    [ $(( $(date +%s) - start )) -ge 3 ] && { rm -f "$RCFILE"; exit 0; }
fi

# allowTitleOps false: keep the "LayerOSX — terminal" title whatever the shell
# does, so Ctrl+Alt+T can find it again (lib/raise-window.sh) and openbox keeps
# centering it (title rule "LayerOSX*").
xterm -fa Monospace -fs 12 -bg black -fg white -xrm 'XTerm*allowTitleOps: false' \
    -T "LayerOSX — terminal (safe to close any time)" \
    -e bash --rcfile "$RCFILE" -i

rm -f "$RCFILE"
