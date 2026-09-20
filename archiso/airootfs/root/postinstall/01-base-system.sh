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

# /etc/os-release still says "Arch Linux" untouched otherwise -- it's
# what systemd's own early-boot "Welcome to $PRETTY_NAME!" message
# reads, and (when GRUB_DISTRIBUTOR is unset, see 50-grub.sh) what
# grub-mkconfig falls back to for the boot menu's own title too. Only
# touching the two display fields (NAME/PRETTY_NAME), not ID/ID_LIKE/
# VERSION -- those are what pacman hooks and other tooling actually
# check to know this is really Arch underneath, and changing them
# would risk breaking something for a cosmetic rename. /etc/os-release
# is normally a symlink to /usr/lib/os-release on Arch; sed -i still
# edits it correctly either way (see README.md).
if [ -f /etc/os-release ]; then
    sed -i 's/^NAME=.*/NAME="LayerOSX"/' /etc/os-release
    sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="LayerOSX"/' /etc/os-release
fi

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
# Copies logs to a USB drive (Ventoy preferred) on every boot -- see
# kiosk/lib/save-logs-to-usb.sh for why: a black screen or a reboot
# loop leaves no tty to read logs from, but the USB is always there.
systemctl enable layerosx-save-logs.service

# The rsync-based install (see install-wizard.sh) copies the running
# live system's "/" onto the target disk -- but archiso deliberately
# does NOT ship the kernel (vmlinuz-linux) inside the live squashfs
# itself; it only lives on the ISO's own boot media (loaded directly
# by the bootloader before the squashfs is even mounted), since the
# live system has no need for a redundant local copy to boot itself.
# rsync can't restore what was never on the live filesystem in the
# first place -- so install-wizard.sh now copies the real
# vmlinuz-linux into /mnt/boot BEFORE this script ever runs (see its
# "Copying the real kernel" step), sourced from a build-time stash at
# /opt/layerosx/vmlinuz-linux.stashed (customize_airootfs.sh, since
# that DOES rsync onto the target as part of "/" like everything else
# under /opt/layerosx) rather than the live boot medium -- runtime
# medium-searching turned out to be unreliable via Ventoy on real
# hardware. By the time we get here it should already exist.
#
# (An earlier version of this fix instead ran `pacman -S --noconfirm
# linux linux-firmware intel-ucode amd-ucode`, on the theory that the
# rsynced local package database would let pacman re-extract the
# files from the also-rsynced package cache. That was wrong on two
# counts, confirmed on real hardware: mkarchiso never populates the
# live airootfs's own /var/cache/pacman/pkg in the first place
# (packages are pulled from the BUILD machine's own cache, not baked
# into the ISO), and the rsynced system is also missing pacman's
# *sync* databases -- /var/lib/pacman/sync/*.db, distinct from the
# installed-package state db, which IS present -- so `pacman -S`
# couldn't even resolve the package names ("target not found"),
# let alone install them, without a network connection. Copying the
# kernel binary directly needs neither pacman nor a network.
# linux-firmware's actual files (/usr/lib/firmware/...) don't have
# this problem -- they're part of the live "/" like everything else,
# so they arrive via the normal rsync.)
if [ ! -f /boot/vmlinuz-linux ]; then
    echo "!!! /boot/vmlinuz-linux is still missing -- install-wizard.sh's kernel copy step must have failed or been skipped. GRUB will have nothing to boot until this is fixed." >&2
fi

# The live ISO's own /etc/mkinitcpio.conf.d/archiso.conf (rsynced onto
# the target like everything else under /etc) overrides HOOKS with
# archiso-specific ones (archiso, archiso_loop_mnt, memdisk, the PXE
# hooks...) meant for booting the *live medium*, not an installed
# system on a real disk. Left in place, mkinitcpio -P below would bake
# those into the installed system's own initramfs -- at best dead
# weight, at worst it tries to find a live boot medium on every real
# boot and fails. Removing it falls back to mkinitcpio's own
# package-default /etc/mkinitcpio.conf (base udev autodetect
# microcode modconf kms keyboard keymap consolefont block filesystems
# fsck), which is what an installed system actually needs.
rm -f /etc/mkinitcpio.conf.d/archiso.conf

echo "[01] mkinitcpio -P"
mkinitcpio -P
