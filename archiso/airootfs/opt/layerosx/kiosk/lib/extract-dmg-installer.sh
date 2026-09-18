#!/usr/bin/env bash
# Best effort: tries to extract a bootable installer from a .dmg (or
# an .app with a .dmg inside it) you already have — for example,
# downloaded from the App Store on another Mac, which always gets you
# the latest version. This is the most experimental part of the
# project: real Apple installer images are usually APFS, and APFS
# support on Linux is still limited. See docs/CHECKLIST.md.
set -euo pipefail
SRC="$1"
VM_DISK="$2"

command -v dmg2img >/dev/null 2>&1 || { echo "dmg2img not found" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'umount "$WORK/mnt" 2>/dev/null; rm -rf "$WORK"' EXIT

DMG="$SRC"
if [ -d "$SRC" ]; then
    DMG=$(find "$SRC" -iname '*.dmg' | head -n1)
    [ -n "$DMG" ] || { echo "no .dmg found inside $SRC" >&2; exit 1; }
fi

dmg2img "$DMG" "$WORK/installer.img"

MNT="$WORK/mnt"
mkdir -p "$MNT"
if mount -o loop,ro "$WORK/installer.img" "$MNT" 2>/dev/null; then
    echo "mounted successfully (HFS+)"
elif command -v apfs-fuse >/dev/null 2>&1 && apfs-fuse "$WORK/installer.img" "$MNT" 2>/dev/null; then
    echo "mounted successfully (APFS via apfs-fuse)"
else
    echo "couldn't mount the extracted image (neither HFS+ nor APFS) — this path needs more work, see docs/CHECKLIST.md." >&2
    exit 1
fi

qemu-img convert -O qcow2 "$WORK/installer.img" "${VM_DISK%.qcow2}-installer.qcow2"
echo "Installer ready at ${VM_DISK%.qcow2}-installer.qcow2 — attach it as a second disk on first boot."
