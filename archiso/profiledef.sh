#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="layerosx"
iso_label="LAYEROSX_$(date +%Y%m)"
iso_publisher="LayerOSX <https://github.com/vinioliveiras/LayerOSX>"
iso_application="LayerOSX Live/Install medium"
iso_version="$(date +%Y.%m.%d)"
install_dir="layerosx"
buildmodes=('iso')
# uefi.systemd-boot is the only mode we actually intend to support
# (this project is UEFI-only, on purpose). The bios.syslinux modes
# below are NOT about supporting legacy BIOS boot -- they're what
# makes mkarchiso generate the ISO's isohybrid MBR + El Torito boot
# catalog. Without that structure (found the hard way: booting via a
# real Ventoy USB on physical hardware left NO /dev/loop* device at
# all for the kernel to find, so the "search by label" fix couldn't
# find anything either -- Ventoy needs to be able to loopback-mount
# the whole ISO as a disk, and a UEFI-only ISO doesn't have the MBR
# structure that makes that possible), tools like Ventoy can't
# recognize/loopback-mount the ISO as a disk at all -- they can only
# chainload the kernel+initrd directly out of it, which is why the
# running system could never find its own medium afterward. This is
# also just what every official Arch ISO does, for the same reason.
bootmodes=('bios.syslinux' 'uefi.systemd-boot')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15')
# NOTE: a directory entry here only sets that directory's own mode —
# it is NOT applied recursively to files inside it (confirmed the hard
# way: /opt/layerosx was already listed at 0:0:755 below, but
# install-wizard.sh under it still landed on the live ISO as 644,
# because the *source* checkout — on a Windows-mounted drive via WSL,
# which doesn't reliably preserve the git-tracked executable bit —
# had it wrong, and mkarchiso doesn't fix it without an explicit
# entry). Every individual script that needs +x has to be listed here
# by its own path.
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/postinstall"]="0:0:750"
  ["/root/customize_airootfs.sh"]="0:0:750"
  ["/root/postinstall/01-base-system.sh"]="0:0:750"
  ["/root/postinstall/10-hardware-detect.sh"]="0:0:750"
  ["/root/postinstall/40-kiosk-autologin.sh"]="0:0:750"
  ["/root/postinstall/50-grub.sh"]="0:0:750"
  ["/root/postinstall/run.sh"]="0:0:750"
  ["/opt/layerosx"]="0:0:755"
  ["/opt/layerosx/bin/qemu-system-x86_64"]="0:0:755"
  ["/opt/layerosx/kiosk/install-wizard.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/mac-vm-launch.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/macos-source-wizard.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/extract-dmg-installer.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/fetch-recovery.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/force-max-refresh.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/vt-lock.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/qemu-libdir.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/tty2-getty.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/mount-removable-media.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/save-logs-to-usb.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/wifi-setup.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/install-f2-keybind.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/peek-terminal.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/maint-terminal.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/kiosk-menu.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/panel.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/save-logs-to.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/brightness.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/raise-window.sh"]="0:0:755"
  ["/opt/layerosx/panel"]="0:0:755"
  ["/opt/layerosx/panel/layerosx_panel.py"]="0:0:755"
  ["/opt/layerosx/panel/layerosx_backend.py"]="0:0:755"
  ["/opt/layerosx/panel/layerosx_style.py"]="0:0:644"
  ["/opt/layerosx/panel/layerosx_terminal.py"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/settings.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/collect-diag.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/pick-source-file.py"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/qmp-cmd.py"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/battery-watch.sh"]="0:0:755"
  ["/opt/layerosx/kiosk/lib/usb-passthrough.sh"]="0:0:755"
  ["/usr/lib/systemd/system-sleep/layerosx-vm"]="0:0:755"
  ["/usr/local/bin/layerosx-cleanup.sh"]="0:0:755"
  ["/usr/local/bin/erasevm"]="0:0:755"
  ["/usr/local/bin/gpu"]="0:0:755"
  ["/usr/local/bin/verbose"]="0:0:755"
  ["/usr/local/bin/audio"]="0:0:755"
  ["/usr/local/bin/maclog"]="0:0:755"
  ["/usr/local/bin/relaunch"]="0:0:755"
  ["/usr/local/bin/macstatus"]="0:0:755"
  ["/usr/local/bin/commands"]="0:0:755"
  ["/usr/local/bin/macdiag"]="0:0:755"
  ["/usr/local/bin/wifi"]="0:0:755"
  ["/usr/local/bin/usb"]="0:0:755"
)
