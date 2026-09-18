#!/usr/bin/env bash
set -euo pipefail
echo "[50] GRUB (reuses the existing EFI partition — never formats it)"

# Independent lspci check rather than reading state from
# 10-hardware-detect.sh — each postinstall script is meant to run
# standalone (run.sh continues even if one script fails), so no
# cross-script state files.
if lspci -mm -nn 2>/dev/null | grep -E 'VGA compatible controller|3D controller' | grep -qi '"NVIDIA'; then
    if ! grep -q 'nvidia-drm.modeset=1' /etc/default/grub 2>/dev/null; then
        sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=1"/' /etc/default/grub
    fi
fi

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=layerosx --recheck
grub-mkconfig -o /boot/grub/grub.cfg
