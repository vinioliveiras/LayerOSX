#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="layerosx"
iso_label="LAYEROSX_$(date +%Y%m)"
iso_publisher="LayerOSX <https://github.com/vinioliveiras/LayerOSX>"
iso_application="LayerOSX Live/Install medium"
iso_version="$(date +%Y.%m.%d)"
install_dir="layerosx"
buildmodes=('iso')
bootmodes=('uefi-x64.systemd-boot.esp' 'uefi-x64.systemd-boot.eltorito')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/postinstall"]="0:0:750"
  ["/root/customize_airootfs.sh"]="0:0:750"
  ["/opt/layerosx"]="0:0:755"
  ["/usr/local/bin/layerosx-cleanup.sh"]="0:0:755"
)
