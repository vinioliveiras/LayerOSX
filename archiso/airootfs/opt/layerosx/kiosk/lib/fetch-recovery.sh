#!/usr/bin/env bash
# Downloads the recovery image directly from Apple's servers
# (fetch-macOS-v2.py, from the OSX-KVM project — note the "-v2": the
# older fetch-macOS.py was renamed/replaced upstream) into disk $1.
# This never redistributes anything from Apple — it just automates the
# same request a real Mac makes when it boots into network recovery
# mode, this time onto your own disk.
#
# Needs unrestricted outbound HTTP to osrecovery.apple.com — this will
# fail under any kind of network allowlist/proxy (confirmed while
# testing: both this developer's sandboxed dev environments got a 403
# from their own egress allowlist, nothing to do with Apple). The
# actual installed LayerOSX system has normal internet, so this just
# works there.
set -euo pipefail
VM_DISK="$1"
WORK="/var/lib/layerosx/fetch-work"
mkdir -p "$WORK"
cd "$WORK"

if [ ! -f fetch-macOS-v2.py ]; then
    curl -fsSLo fetch-macOS-v2.py \
        https://raw.githubusercontent.com/kholia/OSX-KVM/master/fetch-macOS-v2.py
fi
python3 fetch-macOS-v2.py --action download -o recovery

DMG=$(find recovery -iname 'BaseSystem.dmg' | head -n1)
if [ -n "$DMG" ] && command -v dmg2img >/dev/null 2>&1; then
    dmg2img "$DMG" BaseSystem.img
    qemu-img convert -O qcow2 BaseSystem.img "${VM_DISK%.qcow2}-recovery.qcow2"
    echo "Recovery ready at ${VM_DISK%.qcow2}-recovery.qcow2 — mac-vm-launch.sh needs to attach it as a second disk on first boot so you can actually install macOS."
else
    echo "WARNING: couldn't find BaseSystem.dmg (under $WORK/recovery) or dmg2img — the download may have failed." >&2
    exit 1
fi
