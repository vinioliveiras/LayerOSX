#!/usr/bin/env bash
# Let the kiosk user's QEMU open one of the computer's own partitions as an
# extra disk for the Mac (Settings > USB Devices > Drives inside this
# computer), or take that access away again. Root, through sudo.
#
#   disk-access.sh grant  <partition>
#   disk-access.sh revoke <partition>
#
# An ACL for the calling user ($SUDO_USER) on the device node -- gone at the
# next reboot / device change anyway. Refused: anything that isn't a
# partition of a non-removable disk, the system's own partitions (/, /boot,
# /boot/efi), the one holding /var/lib/layerosx, and a mounted one (Linux and
# macOS writing the same filesystem at once would corrupt it).
set -uo pipefail
STATE_DIR="${LAYEROSX_STATE_DIR:-/var/lib/layerosx}"
die() { echo "disk-access: $*" >&2; exit 2; }

ACT="${1:-}"; DEV="${2:-}"; WHO="${SUDO_USER:-}"
case "$ACT" in grant|revoke) ;; *) die "usage: disk-access.sh grant|revoke <partition>" ;; esac
[ -n "$WHO" ] && [ "$WHO" != root ] || die "run through sudo by the kiosk user"
DEV="$(readlink -f -- "$DEV")"
case "$DEV" in /dev/*) ;; *) die "not a device: $DEV" ;; esac
[ -b "$DEV" ] || die "not a block device: $DEV"
[ "$(lsblk -ndo TYPE "$DEV" 2>/dev/null)" = part ] || die "not a partition: $DEV"

if [ "$ACT" = revoke ]; then
    setfacl -x "u:$WHO" "$DEV" 2>/dev/null
    exit 0
fi

parent="/dev/$(lsblk -ndo PKNAME "$DEV" 2>/dev/null)"
[ "$(lsblk -ndo RM "$parent" 2>/dev/null | tr -d ' ')" = 0 ] || die "removable drives go to the Mac through USB"
for sys in / /boot /boot/efi "$STATE_DIR"; do
    src="$(findmnt -nro SOURCE --target "$sys" 2>/dev/null | sed 's/\[.*//')"
    [ -n "$src" ] && [ "$(readlink -f "$src")" = "$DEV" ] && die "refusing the system's own $sys partition"
done
findmnt -rno TARGET --source "$DEV" >/dev/null 2>&1 && die "$DEV is mounted on Linux -- unmount it first"
grep -q "^$DEV " /proc/swaps 2>/dev/null && die "$DEV is swap"
setfacl -m "u:$WHO:rw" "$DEV" || die "setfacl failed"
echo "granted $DEV to $WHO"
