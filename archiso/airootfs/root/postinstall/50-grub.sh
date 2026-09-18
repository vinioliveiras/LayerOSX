#!/usr/bin/env bash
set -euo pipefail
echo "[50] GRUB (reuses the existing EFI partition — never formats it)"

if ! grep -q 'nvidia-drm.modeset=1' /etc/default/grub 2>/dev/null; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=1"/' /etc/default/grub
fi

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=layerosx --recheck
grub-mkconfig -o /boot/grub/grub.cfg
