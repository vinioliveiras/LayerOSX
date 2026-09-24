#!/usr/bin/env bash
set -euo pipefail
echo "[40] kiosk autologin"

MAC_USER="mac"

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin ${MAC_USER} %I \$TERM
EOF

chmod +x /opt/layerosx/kiosk/*.sh /opt/layerosx/kiosk/lib/*.sh 2>/dev/null || true

# -nocursor (an earlier version of this file passed it to startx) hides
# the mouse pointer for the WHOLE X session, not just once QEMU/SDL is
# up and drawing its own cursor -- it also blanked it during
# macos-source-wizard.sh's own zenity dialogs and file pickers (first
# boot only, before a VM disk exists), which genuinely need a visible,
# clickable cursor. Matches root's own live-ISO session, which never
# had this flag and has always worked fine.
cat > "/home/${MAC_USER}/.bash_profile" <<'EOF'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx "$HOME/.xinitrc"
fi
EOF

cat > "/home/${MAC_USER}/.xinitrc" <<'EOF'
#!/bin/sh
# No desktop portals in the kiosk: GTK4 apps (Settings, Terminal, zenity)
# otherwise ask systemd to start xdg-desktop-portal-gnome, which fails every
# time ("Failed to start Portal service (GTK/GNOME implementation)" spam in
# the journal) and can delay the window. Exported first so openbox -- and
# everything its hotkeys start -- inherits it.
export GDK_DEBUG=no-portals GTK_USE_PORTAL=0
# Must run BEFORE `openbox &` -- it edits openbox's config, which is
# only read at startup (see lib/install-f2-keybind.sh).
/opt/layerosx/kiosk/lib/install-f2-keybind.sh "$HOME/mac-vm.log"
openbox &
sleep 1
# Compositor for rounded window corners (see /opt/layerosx/kiosk/picom.conf; it
# unredirects fullscreen windows, so the VM isn't affected). Off switch:
# echo off > /var/lib/layerosx/compositor
if [ "$(cat /var/lib/layerosx/compositor 2>/dev/null)" != off ] && command -v picom >/dev/null 2>&1; then
    picom -b --config /opt/layerosx/kiosk/picom.conf 2>>"$HOME/picom.log" || true
fi
/opt/layerosx/kiosk/lib/force-max-refresh.sh &
# Re-apply the Mac's screen choice when monitors are plugged/unplugged (and
# light every screen back up if the chosen one goes away). lib/displays.py.
python3 /opt/layerosx/kiosk/lib/displays.py watch >/dev/null 2>&1 &
# Automatic USB: give devices plugged into a port to the Mac (Settings > USB).
python3 /opt/layerosx/panel/layerosx_backend.py usb-auto-watch >>"$HOME/usb-auto.log" 2>&1 &
# Last brightness the user chose (keys or LayerOSX Settings), across reboots.
/opt/layerosx/kiosk/lib/brightness.sh restore &
# Laptop battery guard (warnings + clean macOS shutdown at critical); exits
# at once on machines without a battery.
/opt/layerosx/kiosk/lib/battery-watch.sh &
exec /opt/layerosx/kiosk/mac-vm-launch.sh
EOF
chmod +x "/home/${MAC_USER}/.xinitrc"
chown "${MAC_USER}:${MAC_USER}" "/home/${MAC_USER}/.bash_profile" "/home/${MAC_USER}/.xinitrc"

# passwordless systemctl reboot/poweroff, only for the kiosk user —
# this is how Restart/Shutdown done INSIDE macOS end up actually
# touching the physical machine (see /opt/layerosx/kiosk/qmp-watch.py).
cat > /etc/sudoers.d/20-mac-vm-power <<EOF
${MAC_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl reboot, /usr/bin/systemctl poweroff, /usr/bin/mkdir -p /var/lib/layerosx, /usr/bin/chown ${MAC_USER}\:${MAC_USER} /var/lib/layerosx
EOF
chmod 440 /etc/sudoers.d/20-mac-vm-power
