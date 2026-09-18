#!/usr/bin/env bash
# Downloads the recovery image directly from Apple's servers
# (fetch-macOS.py, from the OSX-KVM project) into disk $1. This never
# redistributes anything from Apple — it just automates the same
# request a real Mac makes when it boots into network recovery mode,
# this time onto your own disk.
set -euo pipefail
VM_DISK="$1"
WORK="/var/lib/layerosx/fetch-work"
mkdir -p "$WORK"
cd "$WORK"

if [ ! -f fetch-macOS.py ]; then
    curl -fsSLo fetch-macOS.py \
        https://raw.githubusercontent.com/kholia/OSX-KVM/master/fetch-macOS.py
fi
python3 fetch-macOS.py

if [ -f BaseSystem.dmg ] && command -v dmg2img >/dev/null 2>&1; then
    dmg2img BaseSystem.dmg BaseSystem.img
    qemu-img convert -O qcow2 BaseSystem.img "${VM_DISK%.qcow2}-recovery.qcow2"
    echo "Recovery ready at ${VM_DISK%.qcow2}-recovery.qcow2 — mac-vm-launch.sh needs to attach it as a second disk on first boot so you can actually install macOS."
else
    echo "WARNING: couldn't find BaseSystem.dmg or dmg2img — the download may have failed." >&2
    exit 1
fi
