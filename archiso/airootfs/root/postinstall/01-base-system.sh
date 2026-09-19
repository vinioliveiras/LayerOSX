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

# The rsync-based install (see install-wizard.sh) copies the running
# live system's "/" onto the target disk -- but archiso deliberately
# does NOT ship the kernel, initramfs, or microcode images inside the
# live squashfs itself. mkarchiso keeps those only on the ISO's own
# boot media (loaded directly by the bootloader before the squashfs
# is even mounted), since the live system has no need for a redundant
# local copy to boot itself. rsync can't restore what was never on
# the live filesystem in the first place, so /boot lands on the
# target with only EFI/ and grub/ -- no kernel at all. mkinitcpio -P
# below would fail on a missing/unreadable /boot/vmlinuz-linux as a
# symptom, and even if it didn't, GRUB would have nothing to boot.
#
# Fix: pacman's local package database DID get rsynced (it just
# records linux/linux-firmware/*-ucode as already installed), so
# force a reinstall of everything that actually owns files under
# /boot -- this re-extracts the real files from the local package
# cache (also rsynced, so this normally needs no network at all).
echo "Reinstalling kernel/microcode packages (archiso doesn't ship these inside the live squashfs -- see comment above)..."
pacman -S --noconfirm linux linux-firmware intel-ucode amd-ucode

echo "[01] mkinitcpio -P"
mkinitcpio -P
