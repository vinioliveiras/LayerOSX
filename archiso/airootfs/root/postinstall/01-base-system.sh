#!/usr/bin/env bash
set -euo pipefail
echo "[01] locale, keyboard, hostname, user"

# fixed locale — the real keyboard layout comes from inside the macOS
# VM, this is just enough for the Arch underneath to not complain.
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

echo "layerosx" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   layerosx.localdomain layerosx
EOF

hwclock --systohc --utc 2>/dev/null || true

# single appliance user — no interactive password prompt, autologin in
# the kiosk (see 40-kiosk-autologin.sh). Change the password later
# with `passwd mac`, this is just so the machine boots on its own.
MAC_USER="mac"
if ! id "$MAC_USER" &>/dev/null; then
    useradd -m -G wheel,kvm,video,render -s /bin/bash "$MAC_USER"
    echo "${MAC_USER}:mac" | chpasswd
fi
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-wheel-nopasswd
chmod 440 /etc/sudoers.d/10-wheel-nopasswd

passwd -l root || true

systemctl enable NetworkManager
systemctl enable layerosx-cleanup.timer

echo "[01] mkinitcpio -P"
mkinitcpio -P
