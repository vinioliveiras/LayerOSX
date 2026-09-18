# live ISO only — root autologin on tty1 goes straight into the
# install wizard.
# (This file does NOT persist onto the installed system — the install
# wizard copies the live rootfs via rsync, but postinstall swaps
# autologin over to the macOS kiosk before the first real boot. See
# postinstall/40-kiosk-autologin.sh.)
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx /root/.xinitrc
fi
