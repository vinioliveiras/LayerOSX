# live ISO only — root autologin on tty1 goes straight into the
# install wizard.
# (This file does NOT persist onto the installed system — the install
# wizard copies the live rootfs via rsync, but postinstall swaps
# autologin over to the macOS kiosk before the first real boot. See
# postinstall/40-kiosk-autologin.sh.)
# Only try once per boot: /run is tmpfs, so this flag clears itself on
# every reboot. Without this guard, a startx/X crash drops back to the
# tty1 login prompt, autologin fires again, and this retries forever —
# looks like the screen endlessly flickering, with no stable console
# to Ctrl+Alt+F2 away to and no time to actually switch VTs. Now: one
# attempt, and if X dies, the next tty1 login just falls through to a
# normal shell here instead of retrying — tty1 already autologs in as
# root, so no password needed there. The debug password (root /
# layerosx, see customize_airootfs.sh) is only for OTHER consoles
# (Ctrl+Alt+F2, sulogin in emergency mode, ...) that don't autologin.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ] && [ ! -e /run/layerosx-startx-attempted ]; then
    touch /run/layerosx-startx-attempted
    exec startx /root/.xinitrc
fi
