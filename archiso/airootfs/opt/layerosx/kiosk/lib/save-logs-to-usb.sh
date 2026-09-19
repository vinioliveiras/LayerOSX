#!/usr/bin/env bash
# Best-effort: copies every known LayerOSX log (+ a journalctl
# snapshot of the current boot) onto a removable USB drive -- prefers
# whichever partition is labeled "Ventoy" (that's what's actually
# plugged in during testing, since it's the install medium itself),
# falling back to any other exfat/ntfs/vfat partition found that
# isn't part of the disk we're actually running from.
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
# any number of times. Every exit point (found nothing, mount
# failed, etc.) still leaves a one-line breadcrumb in $STATUS_LOG on
# the LOCAL disk though -- we got burned once already by this script
# silently doing nothing with zero way to tell why from the outside
# (see README.md), so "silent to the user" no longer means "silent
# to the next debugging session".
set -uo pipefail

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
MNT="/tmp/layerosx-logs-usb"
STATUS_LOG="/var/log/layerosx-save-logs-status.log"

status() {
    { printf '%s pid=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$1" >>"$STATUS_LOG"; } 2>/dev/null || true
}

# The one thing we must NEVER do is mount over or write onto whatever
# disk is actually running this system (internal drive, could well
# have an NTFS/exFAT Windows partition on a dual-boot machine) -- so
# instead of trusting lsblk's RM ("removable") column, which several
# USB enclosures/bridge chips misreport as 0 for genuinely-removable
# drives (seen in the wild, and the likely reason this script
# produced zero output during a real test even though a Ventoy drive
# was plugged in -- see README.md), we explicitly resolve and exclude
# the parent disk(s) behind / and /boot and treat everything else as
# fair game.
root_disks() {
    local src pk
    for mp in / /boot; do
        src="$(findmnt -no SOURCE "$mp" 2>/dev/null)" || continue
        [ -n "$src" ] || continue
        pk="$(lsblk -no PKNAME "$src" 2>/dev/null)"
        [ -n "$pk" ] && printf '%s\n' "$pk"
        # PKNAME is empty for a device that's already a whole disk
        # (no partition table involved) -- fall back to its own name.
        [ -n "$pk" ] || basename "$src"
    done
}

pick_partition() {
    local excluded best="" fallback="" mp=""
    excluded="$(root_disks)"

    while IFS= read -r line; do
        eval "$line"
        [ "${TYPE:-}" = "part" ] || continue
        case "${FSTYPE:-}" in exfat|ntfs|ntfs3|vfat) ;; *) continue ;; esac
        printf '%s\n' "$excluded" | grep -qxF "${PKNAME:-}" && continue
        if printf '%s' "${LABEL:-}" | grep -qi ventoy; then
            best="$NAME"
            mp="${MOUNTPOINT:-}"
        elif [ -z "$fallback" ]; then
            fallback="$NAME"
            [ -z "$best" ] && mp="${MOUNTPOINT:-}"
        fi
    done < <(lsblk -Plno NAME,LABEL,FSTYPE,TYPE,PKNAME,MOUNTPOINT 2>/dev/null)

    printf '%s\t%s' "${best:-$fallback}" "$mp"
}

RESULT="$(pick_partition)"
DEV="${RESULT%%$'\t'*}"
EXISTING_MP="${RESULT#*$'\t'}"

if [ -z "$DEV" ]; then
    status "no candidate partition found (nothing removable/exfat/ntfs/vfat besides the system disk)"
    exit 0
fi

WE_MOUNTED=0
if [ -n "$EXISTING_MP" ]; then
    # Already mounted somewhere (e.g. by something else) -- just use
    # that instead of mounting a second time.
    MNT="$EXISTING_MP"
else
    mkdir -p "$MNT" 2>/dev/null || { status "mkdir $MNT failed for /dev/$DEV"; exit 0; }
    if ! mountpoint -q "$MNT" 2>/dev/null; then
        if ! mount "/dev/$DEV" "$MNT" 2>/dev/null; then
            status "mount /dev/$DEV -> $MNT failed"
            exit 0
        fi
        WE_MOUNTED=1
    fi
fi

DEST="$MNT/layerosx-logs/${STAMP}-$(hostname 2>/dev/null || echo host)"
if ! mkdir -p "$DEST" 2>/dev/null; then
    status "mkdir $DEST failed on /dev/$DEV"
    [ "$WE_MOUNTED" = "1" ] && umount "$MNT" 2>/dev/null
    exit 0
fi

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
cp -f "$STATUS_LOG" "$DEST/save-logs-status.log" 2>/dev/null || true

sync 2>/dev/null || true
status "saved to /dev/$DEV at $DEST"
if [ "$WE_MOUNTED" = "1" ]; then
    umount "$MNT" 2>/dev/null || true
fi
