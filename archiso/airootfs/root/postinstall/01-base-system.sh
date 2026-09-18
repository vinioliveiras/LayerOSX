#!/usr/bin/env bash
set -euo pipefail
echo "[01] idioma, teclado, hostname, utilizador"

# locale fixo — o layout real de teclado vem de dentro da VM do macOS,
# isto aqui é só o suficiente pro Arch por baixo não reclamar.
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

# utilizador único da appliance — sem prompt de password interativo,
# autologin no kiosk (ver 40-kiosk-autologin.sh). Muda a password depois
# com `passwd mac`, isto aqui é só pra a máquina arrancar sozinha.
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
