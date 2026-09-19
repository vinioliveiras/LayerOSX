#!/usr/bin/env bash
# Live-ISO install flow. Replaces Calamares: Calamares has never been
# in Arch's official repos (only the AUR), and we decided against both
# pulling in a third-party binary repo (Chaotic-AUR doesn't carry it
# anyway) and compiling its Qt/KDE dependency chain from the AUR at
# build time (see README.md for the full reasoning).
#
# GParted (official Arch package, graphical, does exactly one job)
# handles partitioning and formatting interactively — partitioning is
# the one decision in this whole install that genuinely can't be
# automated safely. Everything else Calamares used to do (copy the
# live system onto the target, fstab, machine-id, chroot in and run
# our postinstall) is done here instead, with zero further prompts.
set -euo pipefail

LOG=/var/log/layerosx-install.log
exec > >(tee -a "$LOG") 2>&1
echo "===== LayerOSX install: $(date -Is) ====="

# Without this, a failure partway through (mount, rsync, genfstab,
# arch-chroot, ...) would just get logged and the script would keep
# going — silently reaching the "Done, reboot" dialog and rebooting
# into a broken/incomplete install. set -e stops on the first
# unexpected failure, and this trap actually tells you so instead of
# leaving you looking at a dead black screen with no explanation.
trap 'zenity --error --width=560 --title="LayerOSX — Install" \
    --text="Something went wrong during install and it stopped (see the log for details).\n\nLog: $LOG\n\nOpen a terminal (Ctrl+Alt+F2, login: root / layerosx) to look, then reboot and try again — nothing was rebooted, so you are not stuck with a broken install." \
    2>/dev/null || true' ERR

zenity --info --width=560 --title="LayerOSX — Install" \
    --text="Next: GParted opens so you can partition the disk.\n\nCreate at least:\n  • an EFI System Partition (fat32, ~512MB, flag 'esp'/'boot')\n  • a root partition (ext4, using the rest of the disk)\n\nFormat both from inside GParted itself. When you're done, apply the changes and close GParted to continue." \
    || exit 1

gparted
# GParted blocks until closed; its exit code doesn't tell us anything
# useful (0 even if the user made no changes), so nothing to check.

mapfile -t ROWS < <(lsblk -rno PATH,SIZE,FSTYPE,TYPE | awk '$4=="part"{print $1; print $2; print ($3==""?"(none)":$3)}')
if [ "${#ROWS[@]}" -eq 0 ]; then
    zenity --error --text="No partitions found. Open a terminal (there isn't a friendly way to recover from this yet) or reboot and try again in GParted."
    exit 1
fi

ROOT_PART=$(zenity --list --width=600 --height=320 \
    --title="LayerOSX — Install" \
    --text="Which partition is the ROOT filesystem (/)? Its entire content will be replaced." \
    --column="Partition" --column="Size" --column="Filesystem" "${ROWS[@]}")
[ -n "$ROOT_PART" ] || exit 1

ESP_PART=$(zenity --list --width=600 --height=320 \
    --title="LayerOSX — Install" \
    --text="Which partition is the EFI System Partition (fat32, ~512MB)?" \
    --column="Partition" --column="Size" --column="Filesystem" "${ROWS[@]}")
[ -n "$ESP_PART" ] || exit 1

zenity --question --width=480 --title="LayerOSX — Install" \
    --text="This will ERASE the content of $ROOT_PART and install LayerOSX there, using $ESP_PART as the EFI partition.\n\nThis cannot be undone. Continue?" \
    || exit 1

echo "Mounting $ROOT_PART at /mnt, $ESP_PART at /mnt/boot..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$ESP_PART" /mnt/boot

# From here on there is real work to wait through with nothing to
# look at otherwise (a bare black openbox desktop, no feedback at
# all) — a plain dark background plus a progress dialog instead. This
# is a generic dark loading look, not a recreation of Apple's actual
# boot screen/logo.
xsetroot -solid "#000000" 2>/dev/null || true

echo "Copying the live system to $ROOT_PART (this is the 'unpackfs' step Calamares used to do)..."
rsync -aHAX --info=progress2 \
    --exclude=/dev --exclude=/proc --exclude=/sys --exclude=/tmp \
    --exclude=/run --exclude=/mnt --exclude=/media --exclude=/lost+found \
    --exclude="$LOG" \
    / /mnt/ &
RSYNC_PID=$!
(
    while kill -0 "$RSYNC_PID" 2>/dev/null; do
        echo "#Copying LayerOSX to disk…"
        sleep 1
    done
) | zenity --progress --pulsate --no-cancel --auto-close \
    --title="LayerOSX — Install" --text="Copying LayerOSX to disk…" --width=560 \
    2>/dev/null || true
wait "$RSYNC_PID"

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "Generating a fresh machine-id..."
rm -f /mnt/etc/machine-id
arch-chroot /mnt systemd-machine-id-setup

echo "Running postinstall (locale, keyboard, user, NVIDIA/KVM, GRUB, kiosk autologin)..."
arch-chroot /mnt /root/postinstall/run.sh

umount -R /mnt

zenity --info --width=480 --title="LayerOSX — Install" \
    --text="Done. Remove the installation media, then reboot." \
    --ok-label="Reboot now"
systemctl reboot
