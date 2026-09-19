#!/usr/bin/env bash
# Best-effort: copies every known LayerOSX log (+ a journalctl
# snapshot of the current boot) onto EVERY eligible disk it can find
# -- not just one. We were burned once already by picking a single
# "best" candidate that silently turned out to be unwritable for a
# reason we couldn't see from the outside (see README.md); trying
# every candidate instead of guessing which one is "the" USB drive
# costs a few extra seconds but means a bad guess on one drive no
# longer means zero logs anywhere. Ventoy-labeled partitions are
# still tried first (most likely to be the one someone's actually
# going to check), but nothing eligible is skipped.
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
# there this run, not a broken boot/install. Safe to call from
# anywhere, any number of times. Every outcome (found nothing, a
# specific device's mount/write failed, a successful save) leaves a
# one-line breadcrumb in $STATUS_LOG on the LOCAL disk, so a future
# silent failure can actually be diagnosed instead of guessed at
# blind.
set -uo pipefail

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STATUS_LOG="/var/log/layerosx-save-logs-status.log"

status() {
    { printf '%s pid=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$1" >>"$STATUS_LOG"; } 2>/dev/null || true
}

# The one thing we must NEVER do is mount over or write onto whatever
# disk is actually running this system (internal drive, could well
# have an NTFS/exFAT Windows partition on a dual-boot machine) -- so
# instead of trusting lsblk's RM ("removable") column, which several
# USB enclosures/bridge chips misreport as 0 for genuinely-removable
# drives (a known quirk, and the original reason this script produced
# zero output on real hardware the first time), we explicitly resolve
# and exclude the parent disk(s) behind / and /boot and treat
# everything else as fair game.
root_disks() {
    local src pk
    for mp in / /boot; do
        src="$(findmnt -no SOURCE "$mp" 2>/dev/null)" || continue
        [ -n "$src" ] || continue
        pk="$(lsblk -no PKNAME "$src" 2>/dev/null)"
        [ -n "$pk" ] && printf '%s\n' "$pk"
        # PKNAME is empty for a device that's already a whole disk
        # (no partition table involved), or for a non-block source
        # like a live-ISO overlay/tmpfs -- basename of a bogus source
        # just never matches a real partition's PKNAME, harmless.
        [ -n "$pk" ] || basename "$src"
    done
}

# Every exfat/ntfs/vfat partition that isn't part of the disk we're
# actually running from, Ventoy-labeled ones first (most likely to be
# the one someone's actually going to check).
candidate_partitions() {
    local excluded
    excluded="$(root_disks)"
    while IFS= read -r line; do
        eval "$line"
        [ "${TYPE:-}" = "part" ] || continue
        case "${FSTYPE:-}" in exfat|ntfs|ntfs3|vfat) ;; *) continue ;; esac
        printf '%s\n' "$excluded" | grep -qxF "${PKNAME:-}" && continue
        if printf '%s' "${LABEL:-}" | grep -qi ventoy; then
            printf '0 %s\n' "$NAME"
        else
            printf '1 %s\n' "$NAME"
        fi
    done < <(lsblk -Plno NAME,LABEL,FSTYPE,TYPE,PKNAME 2>/dev/null) | sort -n | cut -d' ' -f2
}

# Always our own dedicated read-write mount (never reuse whatever a
# device might already be mounted as elsewhere) -- the live ISO's own
# boot medium is commonly already mounted READ-ONLY somewhere else
# (e.g. /run/archiso/bootmnt), and silently reusing that would look
# exactly like "nothing saved, no error" all over again.
save_to_one() {
    local dev="$1" mnt we_mounted=0 dest

    mnt="/tmp/layerosx-logs-usb-$dev"
    mkdir -p "$mnt" 2>/dev/null || { status "mkdir $mnt failed for /dev/$dev"; return 1; }

    if ! mountpoint -q "$mnt" 2>/dev/null; then
        if ! mount -o rw "/dev/$dev" "$mnt" 2>/dev/null; then
            status "mount /dev/$dev -> $mnt failed"
            rmdir "$mnt" 2>/dev/null || true
            return 1
        fi
        we_mounted=1
    fi

    dest="$mnt/layerosx-logs/${STAMP}-$(hostname 2>/dev/null || echo host)"
    if ! mkdir -p "$dest" 2>/dev/null; then
        status "mkdir $dest failed on /dev/$dev (read-only?)"
        [ "$we_mounted" = "1" ] && umount "$mnt" 2>/dev/null
        rmdir "$mnt" 2>/dev/null || true
        return 1
    fi

    cp -f /var/log/layerosx-install.log "$dest/" 2>/dev/null || true
    cp -f /mnt/var/log/layerosx-postinstall.log "$dest/postinstall.log" 2>/dev/null || true
    cp -f /var/log/layerosx-postinstall.log "$dest/" 2>/dev/null || true
    cp -f /home/mac/mac-vm.log "$dest/" 2>/dev/null || true
    journalctl -b -0 --no-pager > "$dest/journal-current-boot.log" 2>/dev/null || true
    lsblk -f > "$dest/lsblk.txt" 2>/dev/null || true
    cp -f "$STATUS_LOG" "$dest/save-logs-status.log" 2>/dev/null || true

    sync 2>/dev/null || true
    status "saved to /dev/$dev at $dest"

    if [ "$we_mounted" = "1" ]; then
        umount "$mnt" 2>/dev/null || true
    fi
    rmdir "$mnt" 2>/dev/null || true
    return 0
}

DEVICES=()
while IFS= read -r d; do
    [ -n "$d" ] && DEVICES+=("$d")
done < <(candidate_partitions)

if [ "${#DEVICES[@]}" -eq 0 ]; then
    status "no candidate partitions found (nothing removable/exfat/ntfs/vfat besides the system disk)"
    exit 0
fi

OK=0
for dev in "${DEVICES[@]}"; do
    save_to_one "$dev" && OK=$((OK + 1))
done
status "done: $OK/${#DEVICES[@]} partition(s) got a copy (${DEVICES[*]})"
