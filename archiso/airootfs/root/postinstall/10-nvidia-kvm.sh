#!/usr/bin/env bash
set -euo pipefail
echo "[10] NVIDIA + KVM"

# nvidia modeset — needed for Vulkan (the Reims-vGPU backend) to work
# well outside X/Wayland.
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia_drm modeset=1
EOF

# kvm_amd (Ryzen) early at boot
if ! grep -q 'kvm_amd' /etc/mkinitcpio.conf; then
    sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 kvm_amd)/' /etc/mkinitcpio.conf
    mkinitcpio -P
fi

echo 'KERNEL=="kvm", GROUP="kvm", MODE="0660"' > /etc/udev/rules.d/65-kvm.rules

systemctl enable nvidia-persistenced.service 2>/dev/null || true
