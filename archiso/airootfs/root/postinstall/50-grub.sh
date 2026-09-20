#!/usr/bin/env bash
set -euo pipefail
echo "[50] GRUB (reuses the existing EFI partition — never formats it)"

# Without this, the boot menu's own entry just says "Arch Linux" --
# grub-mkconfig's 10_linux falls back to /etc/os-release's NAME when
# GRUB_DISTRIBUTOR is unset, which is what Arch's own /etc/default/grub
# template leaves it as. 01-base-system.sh already rebrands os-release
# itself (also fixes systemd's "Welcome to ...!" boot message), but
# setting this explicitly too is the standard, more reliable way distros
# actually control their own GRUB menu title, so it doesn't just happen
# to work via a fallback. Same present/commented/missing handling as
# GRUB_DISABLE_OS_PROBER below, since Arch's own default/grub template
# state can't be assumed.
if grep -q '^GRUB_DISTRIBUTOR=' /etc/default/grub; then
    sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="LayerOSX"/' /etc/default/grub
elif grep -q '^#GRUB_DISTRIBUTOR=' /etc/default/grub; then
    sed -i 's/^#GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="LayerOSX"/' /etc/default/grub
else
    echo 'GRUB_DISTRIBUTOR="LayerOSX"' >> /etc/default/grub
fi

# GRUB stopped enabling os-prober by default a while back (security:
# an unprivileged user could otherwise get grub-mkconfig, run as
# root, to run arbitrary code off another mounted OS). We DO want it
# here on purpose -- this box dual/multi-boots real hardware, and the
# whole point of reusing (never formatting) the existing ESP is to
# coexist with whatever else is already on the disk (Windows, other
# Linux installs, ...). os-prober + ntfs-3g are already pulled in by
# packages.x86_64; this just flips the one flag that actually uses
# them. GRUB_DISABLE_OS_PROBER may be absent, commented out, or
# already set either way depending on the package's own template, so
# handle all three instead of assuming a fresh file.
if grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
elif grep -q '^#GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    sed -i 's/^#GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
else
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi

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
