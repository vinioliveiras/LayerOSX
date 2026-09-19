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

# VirtualBox's EFI firmware (and some real hardware) does not
# reliably keep the NVRAM boot entry the line above just registered
# via efibootmgr — it can vanish on the next reboot, leaving the
# firmware with nothing to boot but its own "UEFI Firmware Settings"
# menu, even though GRUB itself installed fine. The fix used
# everywhere for this (Arch wiki's own VirtualBox-EFI guidance): also
# install to the "removable media" fallback path
# (/boot/EFI/BOOT/BOOTX64.EFI), which UEFI firmware boots
# automatically with no NVRAM entry required at all, regardless of
# whether the "layerosx" NVRAM entry above survives.
grub-install --target=x86_64-efi --efi-directory=/boot --removable --recheck

grub-mkconfig -o /boot/grub/grub.cfg
