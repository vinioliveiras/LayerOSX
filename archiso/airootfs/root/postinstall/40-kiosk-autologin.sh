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

cat > "/home/${MAC_USER}/.bash_profile" <<'EOF'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx "$HOME/.xinitrc" -- -nocursor
fi
EOF

cat > "/home/${MAC_USER}/.xinitrc" <<'EOF'
#!/bin/sh
openbox &
sleep 1
/opt/layerosx/kiosk/lib/force-max-refresh.sh &
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
