#!/usr/bin/env bash
# Copy a diagnostics bundle (made by `macdiag`) onto a chosen drive -- the
# "Save diagnostics…" picker in LayerOSX Settings runs this through sudo.
#
#   save-logs-to.sh <bundle-dir> <block-device>
#
# Mounts the partition if it isn't mounted yet (and unmounts it again after),
# copies the bundle into <drive>/LayerOSX-logs/, syncs, and prints the final
# path. Deliberately narrow because it runs as root: the bundle must be a
# mac-vm-diag-* folder in a home directory, the target must be a partition
# block device, and never the running system's own root or boot partition.
set -euo pipefail

BUNDLE="${1:-}"; DEV="${2:-}"
die() { echo "save-logs-to: $*" >&2; exit 2; }

BUNDLE="$(realpath -e -- "$BUNDLE" 2>/dev/null)" || die "no such bundle"
case "$BUNDLE" in
    /home/*/mac-vm-diag-*|/root/mac-vm-diag-*) ;;
    *) die "not a diagnostics bundle: $BUNDLE" ;;
esac
[ -d "$BUNDLE" ] || die "bundle is not a folder"

case "$DEV" in /dev/*) ;; *) die "not a device: $DEV" ;; esac
[ -b "$DEV" ] || die "not a block device: $DEV"
[ "$(lsblk -ndo TYPE "$DEV" 2>/dev/null)" = part ] || die "not a partition: $DEV"
for sys in / /boot /boot/efi; do
    src="$(findmnt -nro SOURCE --target "$sys" 2>/dev/null || true)"
    [ -n "$src" ] && [ "$(realpath "$src" 2>/dev/null)" = "$(realpath "$DEV")" ] && die "refusing the system's own $sys partition"
done

MNT="$(findmnt -nro TARGET --source "$DEV" 2>/dev/null | head -n1 || true)"
MOUNTED_HERE=0
cleanup() {
    if [ "$MOUNTED_HERE" = 1 ]; then
        umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
        rmdir "$MNT" 2>/dev/null || true
    fi
}
trap cleanup EXIT
if [ -z "$MNT" ]; then
    MNT="/mnt/layerosx-save/$(basename "$DEV")"
    mkdir -p "$MNT"
    mount -o rw "$DEV" "$MNT" || die "couldn't mount $DEV (if it's a Windows drive, Windows may have left it hibernated/locked)"
    MOUNTED_HERE=1
fi

DEST="$MNT/LayerOSX-logs"
mkdir -p "$DEST" || die "the drive is read-only"
cp -r -- "$BUNDLE" "$DEST/" || die "copy failed (drive full?)"
sync
echo "$DEST/$(basename "$BUNDLE")"
