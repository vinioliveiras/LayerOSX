#!/usr/bin/env bash
# Best-effort: copies every known LayerOSX log (+ a journalctl
# snapshot of the current boot) onto a removable USB drive -- prefers
# whichever partition is labeled "Ventoy" (that's what's actually
# plugged in during testing, since it's the install medium itself),
# falling back to any other removable exfat/ntfs/vfat partition found.
#
# Point of this: during this testing phase, failures happen on real
# hardware with no easy way to get logs back to a screen someone can
# actually read (a black screen, or a reboot loop, means no tty to
# type commands into either). This runs automatically (see the
# layerosx-save-logs.service on the installed system, and the call
# sites in install-wizard.sh/mac-vm-launch.sh on the live ISO) and
# leaves a plain folder of text files on the USB that's readable from
# any machine, Windows included -- no boot, no tty, no photo needed.
#
# Never fails loudly: a missing/unwritable USB just means no log copy
# this run, not a broken boot/install. Safe to call from anywhere,
# any number of times.
set -uo pipefail

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
MNT="/tmp/layerosx-logs-usb"

pick_partition() {
    local best="" fallback=""
    while IFS= read -r line; do
        eval "$line"
        [ "${TYPE:-}" = "part" ] || continue
        [ "${RM:-0}" = "1" ] || continue
        case "${FSTYPE:-}" in exfat|ntfs|ntfs3|vfat) ;; *) continue ;; esac
        if printf '%s' "${LABEL:-}" | grep -qi ventoy; then
            best="$NAME"
        elif [ -z "$fallback" ]; then
            fallback="$NAME"
        fi
    done < <(lsblk -Plno NAME,LABEL,FSTYPE,TYPE,RM 2>/dev/null)
    printf '%s' "${best:-$fallback}"
}

DEV="$(pick_partition)"
[ -n "$DEV" ] || exit 0

mkdir -p "$MNT" 2>/dev/null || exit 0
WE_MOUNTED=0
if ! mountpoint -q "$MNT" 2>/dev/null; then
    mount "/dev/$DEV" "$MNT" 2>/dev/null || exit 0
    WE_MOUNTED=1
fi

DEST="$MNT/layerosx-logs/${STAMP}-$(hostname 2>/dev/null || echo host)"
mkdir -p "$DEST" 2>/dev/null || { [ "$WE_MOUNTED" = "1" ] && umount "$MNT" 2>/dev/null; exit 0; }

# Live-ISO-side paths (install-wizard.sh's own log, and whatever the
# postinstall chroot already wrote onto the target being installed).
cp -f /var/log/layerosx-install.log "$DEST/" 2>/dev/null || true
cp -f /mnt/var/log/layerosx-postinstall.log "$DEST/postinstall.log" 2>/dev/null || true

# Installed-system-side paths (same files, different vantage point,
# once this is running as the layerosx-save-logs.service instead).
cp -f /var/log/layerosx-postinstall.log "$DEST/" 2>/dev/null || true
cp -f /home/mac/mac-vm.log "$DEST/" 2>/dev/null || true

journalctl -b -0 --no-pager > "$DEST/journal-current-boot.log" 2>/dev/null || true
lsblk -f > "$DEST/lsblk.txt" 2>/dev/null || true

sync 2>/dev/null || true
if [ "$WE_MOUNTED" = "1" ]; then
    umount "$MNT" 2>/dev/null || true
fi
