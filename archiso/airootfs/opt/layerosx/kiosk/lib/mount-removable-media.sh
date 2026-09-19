#!/usr/bin/env bash
# Mounts every currently-unmounted partition with a recognizable
# filesystem under /mnt/media/<name>, read-only. This is a minimal
# openbox kiosk with no udisks2/gvfs automount daemon -- so a USB
# drive plugged in with a VM disk, .dmg, or .iso on it is otherwise
# completely invisible to zenity's plain file-selection dialog (it
# only ever browses the local filesystem tree from wherever it
# starts, with no awareness of media that was never mounted anywhere
# in the first place). Safe to re-run: skips whatever is already
# mounted (that also means the disk LayerOSX itself is installed on
# is left alone -- its partitions are always already mounted).
set -uo pipefail

sudo mkdir -p /mnt/media

while IFS= read -r line; do
    eval "$line"
    NAME="${NAME:-}"
    FSTYPE="${FSTYPE:-}"
    MOUNTPOINT="${MOUNTPOINT:-}"
    [ -n "$NAME" ] || continue
    [ -n "$FSTYPE" ] || continue
    [ -z "$MOUNTPOINT" ] || continue
    case "$FSTYPE" in
        ext2|ext3|ext4|vfat|exfat|ntfs|ntfs3|hfsplus|iso9660|udf) ;;
        *) continue ;;
    esac
    target="/mnt/media/$NAME"
    sudo mkdir -p "$target"
    sudo mount -o ro "/dev/$NAME" "$target" 2>/dev/null || true
done < <(lsblk -Pno NAME,FSTYPE,MOUNTPOINT 2>/dev/null)
