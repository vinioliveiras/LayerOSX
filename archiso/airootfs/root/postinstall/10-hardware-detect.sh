#!/usr/bin/env bash
# Detects the REAL physical CPU/GPU of the machine being installed
# onto (this runs arch-chrooted from install-wizard.sh, which
# bind-mounts the host's /proc, /sys and /dev into the chroot — so
# /proc/cpuinfo and lspci here reflect actual hardware, not a
# container) and configures only what that hardware needs. No
# assumptions about vendor: this replaces an earlier version of this
# script that hardcoded Ryzen + NVIDIA (the original dev machine).
#
# All the relevant driver packages (nvidia-open-dkms, mesa,
# vulkan-radeon, vulkan-intel) are already baked into the ISO
# unconditionally by packages.x86_64 — installing nvidia-open-dkms
# doesn't need real NVIDIA hardware present to build, and mesa's
# Vulkan ICDs are tiny — so nothing here needs network access. This
# script only decides which kernel modules/services to actually
# *enable*, based on what's really plugged in.
set -euo pipefail
echo "[10] hardware detection (CPU + GPU)"

MODULES_TO_ADD=()

# --- CPU vendor: which KVM module actually matches this machine ---
CPU_VENDOR="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo)"
case "$CPU_VENDOR" in
    GenuineIntel)
        echo "[10] CPU: Intel — enabling kvm_intel"
        MODULES_TO_ADD+=("kvm_intel")
        ;;
    AuthenticAMD)
        echo "[10] CPU: AMD — enabling kvm_amd"
        MODULES_TO_ADD+=("kvm_amd")
        ;;
    *)
        echo "[10] WARNING: unrecognized CPU vendor '$CPU_VENDOR' — not adding a KVM module automatically. KVM acceleration in the macOS VM may not work; check 'lscpu' and load the right kvm_* module by hand." >&2
        ;;
esac

# --- GPU vendor(s): may be more than one (e.g. laptop hybrid graphics) ---
GPU_LINES="$(lspci -mm -nn 2>/dev/null | grep -E 'VGA compatible controller|3D controller' || true)"
HAS_NVIDIA=0
HAS_AMD=0
HAS_INTEL=0

if echo "$GPU_LINES" | grep -qi '"NVIDIA'; then
    HAS_NVIDIA=1
fi
if echo "$GPU_LINES" | grep -Eqi '"(AMD|ATI)'; then
    HAS_AMD=1
    MODULES_TO_ADD+=("amdgpu")
fi
if echo "$GPU_LINES" | grep -qi '"Intel'; then
    HAS_INTEL=1
    MODULES_TO_ADD+=("i915")
fi

if [ "$HAS_NVIDIA" -eq 0 ] && [ "$HAS_AMD" -eq 0 ] && [ "$HAS_INTEL" -eq 0 ]; then
    echo "[10] WARNING: couldn't identify the GPU from lspci — Reims-vGPU needs a working Vulkan driver on the host to accelerate the macOS VM. Check 'lspci -k' by hand." >&2
fi

if [ "$HAS_NVIDIA" -eq 1 ]; then
    echo "[10] GPU: NVIDIA detected — configuring modeset + persistenced"
    mkdir -p /etc/modprobe.d
    cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia_drm modeset=1
EOF
    systemctl enable nvidia-persistenced.service 2>/dev/null || true
fi
if [ "$HAS_AMD" -eq 1 ]; then
    echo "[10] GPU: AMD detected — amdgpu + Mesa/RADV Vulkan (no extra config needed)"
fi
if [ "$HAS_INTEL" -eq 1 ]; then
    echo "[10] GPU: Intel detected — i915 + Mesa/ANV Vulkan (no extra config needed)"
fi

# --- apply the module list, regenerate initramfs ---
if [ "${#MODULES_TO_ADD[@]}" -gt 0 ]; then
    for mod in "${MODULES_TO_ADD[@]}"; do
        if ! grep -q "\b${mod}\b" /etc/mkinitcpio.conf; then
            sed -i "s/^MODULES=(\(.*\))/MODULES=(\1 ${mod})/" /etc/mkinitcpio.conf
        fi
    done
    echo "[10] mkinitcpio -P (modules: ${MODULES_TO_ADD[*]})"
    mkinitcpio -P
fi

echo 'KERNEL=="kvm", GROUP="kvm", MODE="0660"' > /etc/udev/rules.d/65-kvm.rules
