#!/usr/bin/env bash
# "login program" for tty2 when a Maintenance password is set (see
# tty2-getty.sh): asks for it, checks it with the panel backend and logs in as
# "mac". Runs as root under agetty. Wrong password -> exit (agetty restarts).
echo
echo "LayerOSX maintenance console (Ctrl+Alt+F1 = back to the Mac)"
read -rs -p "Maintenance password: " pw; echo
if printf '%s\n' "$pw" | python3 /opt/layerosx/panel/layerosx_backend.py check-maint-password >/dev/null 2>&1; then
    unset pw
    exec /bin/login -f mac
fi
unset pw
echo "Wrong password."; sleep 3
exit 1
