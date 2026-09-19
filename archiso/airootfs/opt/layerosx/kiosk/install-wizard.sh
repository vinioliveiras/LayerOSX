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

# Force every zenity/GTK dialog in this script to a black/white look,
# from the very first one. GTK_THEME=Adwaita:dark picks the theme's
# own dark variant as a baseline (Adwaita ships built into GTK3, no
# extra package needed) — this alone is what actually gets respected
# reliably; a bare gtk.css override can silently lose to the active
# theme's own more specific selectors. gtk.css on top then forces the
# exact colors (pure black / pure white, not Adwaita-dark's default
# greys) with !important so it wins regardless of specificity.
export GTK_THEME=Adwaita:dark
mkdir -p ~/.config/gtk-3.0
cat > ~/.config/gtk-3.0/settings.ini <<'INI'
[Settings]
gtk-application-prefer-dark-theme=1
INI
cat > ~/.config/gtk-3.0/gtk.css <<'CSS'
window, window.background {
    background-color: #000000 !important;
}
label {
    color: #ffffff !important;
}
progressbar trough {
    background-color: #1c1c1c !important;
    border: none !important;
    min-height: 6px !important;
    border-radius: 0 !important;
}
progressbar progress {
    background-color: #ffffff !important;
    border-radius: 0 !important;
}
CSS

# Without this, a failure partway through (mount, rsync, genfstab,
# arch-chroot, ...) would just get logged and the script would keep
# going — silently reaching the "Done, reboot" dialog and rebooting
# into a broken/incomplete install. set -e stops on the first
# unexpected failure, and this trap actually tells you so instead of
# leaving you looking at a dead black screen with no explanation.
trap 'exec 3>&- 2>/dev/null || true
    bash /opt/layerosx/kiosk/lib/save-logs-to-usb.sh 2>/dev/null || true
    zenity --error --width=560 --title="LayerOSX — Install" \
    --text="Something went wrong during install and it stopped (see the log for details).\n\nLog: $LOG\n\nA copy was also just saved to the USB drive itself (layerosx-logs/ folder) if one was reachable — readable from any machine, no need to type anything here.\n\nOpen a terminal (Ctrl+Alt+F2, login: root / layerosx) to look, then reboot and try again — nothing was rebooted, so you are not stuck with a broken install." \
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
# all) — a plain black background with a white progress bar. A black
# screen with a white progress bar is a generic, widely-used
# minimal-boot look, not a reproduction of Apple's actual boot screen
# — no Apple logo or wordmark is drawn anywhere, only a plain bar.
xsetroot -solid "#000000" 2>/dev/null || true

# ONE progress dialog for the entire rest of the install (copy,
# fstab, machine-id, postinstall) instead of a separate dialog per
# phase — a new dialog opening after the previous one auto-closed
# looked like the bar restarting/going backward, even though each
# phase's own number was fine on its own. A named pipe feeds a single
# long-lived `zenity --progress`; every phase below just writes its
# overall percentage plus a short "what's happening now" line into
# it via the progress() helper, so the bar only ever moves forward
# and always names the current step.
PROGRESS_FIFO=$(mktemp -u /tmp/layerosx-progress.XXXXXX)
mkfifo "$PROGRESS_FIFO"
zenity --progress --no-cancel --auto-close \
    --title="LayerOSX — Install" --text="Starting…" --width=560 \
    < "$PROGRESS_FIFO" 2>/dev/null &
ZENITY_PID=$!
exec 3>"$PROGRESS_FIFO"
rm -f "$PROGRESS_FIFO"   # unlinked; fd 3 (and zenity's read end) keep it alive

progress() { echo "$1" >&3; echo "#$2" >&3; }

echo "Copying the live system to $ROOT_PART (this is the 'unpackfs' step Calamares used to do)..."
progress 0 "Copying files to disk…"
# --info=progress2 prints an overall "NN%" that updates in place;
# each update is scaled into the 0-70% slice of the overall bar (the
# copy is the bulk of the install) and pushed through progress().
#
# --no-inc-recursive matters here, not just for the split above: by
# default modern rsync streams the file list incrementally as it
# walks the tree, so --info=progress2's "total size" denominator
# keeps growing mid-copy as more files are discovered — the
# percentage can visibly jump backward (e.g. 40% then back to 25%) as
# the estimate gets revised upward. --no-inc-recursive makes rsync
# build the complete file list up front instead, so the total is
# known from the start and the percentage only goes forward. Costs a
# few extra seconds up front (scanning the whole tree before any
# copying starts) — worth it for a bar that doesn't visibly rewind.
rsync -aHAX --info=progress2 --no-inc-recursive \
    --exclude=/dev --exclude=/proc --exclude=/sys --exclude=/tmp \
    --exclude=/run --exclude=/mnt --exclude=/media --exclude=/lost+found \
    --exclude="$LOG" \
    / /mnt/ 2>&1 | stdbuf -oL tr '\r' '\n' | stdbuf -oL grep --line-buffered -oE '[0-9]{1,3}%' | \
    while IFS= read -r raw; do
        raw="${raw%\%}"
        progress "$(( raw * 70 / 100 ))" "Copying files to disk… ${raw}%"
    done
# set -o pipefail (top of file) makes $? here reflect rsync's own
# exit code even though it's the first stage of a long pipe — a real
# rsync failure still trips set -e / the ERR trap above, same as
# every other step in this script.

# rsync's --exclude list above (dev/proc/sys/run/tmp/mnt/media) skips
# these directories ENTIRELY on the target, not just their contents —
# rsync does not create an empty placeholder for an excluded top-level
# entry. A normal Arch root (via pacstrap) gets these from the
# `filesystem` package; since we rsync instead, we have to recreate
# them by hand. Without this, arch-chroot fails immediately with
# "mount point does not exist" / "ERROR: failed to setup chroot" on
# the very next line — which also means postinstall/run.sh (GRUB
# install, user setup, everything) never actually runs, even though
# the script appeared to "finish" (this masked a real install failure
# until set -e/the ERR trap above was added).
echo "Recreating dev/proc/sys/run/tmp/mnt/media mount points (rsync skips these on purpose)..."
mkdir -p /mnt/dev /mnt/proc /mnt/sys /mnt/run /mnt/tmp /mnt/mnt /mnt/media
chmod 1777 /mnt/tmp
progress 72 "Preparing the new system…"

# archiso never ships the kernel (vmlinuz-linux) inside the live
# squashfs -- it only lives on the ISO's own boot media, loaded
# directly by the bootloader before the squashfs is even mounted (see
# the long comment in postinstall/01-base-system.sh for the full
# story, including why a pacman-based fix doesn't work offline).
# rsync can't restore what was never part of "/" in the first place,
# so grab it straight from wherever the boot medium is actually
# mounted right now -- found by matching the same
# "<install_dir>/boot/<arch>/vmlinuz-linux" layout mkarchiso uses on
# the ISO itself (see efiboot/loader/entries/01-layerosx.conf), across
# every mounted filesystem except the target disk we just mounted.
echo "Copying the real kernel from the boot medium into /mnt/boot..."
INSTALL_DIR="layerosx"   # must match profiledef.sh's install_dir
ARCH="x86_64"            # must match profiledef.sh's arch
KERNEL_SRC=""

# /run/archiso/bootmnt is where archiso's own init (the
# archiso_loop_mnt mkinitcpio hook) mounts the medium it actually
# booted from -- checking this FIRST (not just as one of many
# findmnt hits) matters if more than one LayerOSX ISO ever ends up
# reachable at once (e.g. several dated builds sitting on the same
# Ventoy drive) — a generic scan could otherwise match a *different,
# stale* ISO's vmlinuz-linux, one whose kernel version doesn't match
# the /usr/lib/modules/<ver>/ this live system's rsync actually
# carries, breaking module loading on the installed system in a way
# that wouldn't show up until the very first real reboot.
if [ -f "/run/archiso/bootmnt/$INSTALL_DIR/boot/$ARCH/vmlinuz-linux" ]; then
    KERNEL_SRC="/run/archiso/bootmnt/$INSTALL_DIR/boot/$ARCH/vmlinuz-linux"
else
    # Fallback for a different archiso version/layout -- less
    # precise (first match wins), so this is the fallback, not the
    # primary path, precisely for the reason above.
    while IFS= read -r mp; do
        case "$mp" in /mnt|/mnt/*) continue ;; esac
        candidate="$mp/$INSTALL_DIR/boot/$ARCH/vmlinuz-linux"
        if [ -f "$candidate" ]; then
            KERNEL_SRC="$candidate"
            break
        fi
    done < <(findmnt -rno TARGET)
fi
if [ -z "$KERNEL_SRC" ]; then
    # last resort: a broader search in case the layout ever changes
    KERNEL_SRC=$(find /run -maxdepth 6 -type f -name 'vmlinuz-linux' 2>/dev/null | head -n1)
fi
if [ -z "$KERNEL_SRC" ]; then
    zenity --error --width=560 --title="LayerOSX — Install" \
        --text="Could not find the kernel on the boot medium (looked for $INSTALL_DIR/boot/$ARCH/vmlinuz-linux on every mounted filesystem). Make sure you're still booted from the LayerOSX USB/ISO, then reboot and try again." \
        2>/dev/null || true
    exit 1
fi
echo "Found kernel at: $KERNEL_SRC"
cp -v "$KERNEL_SRC" /mnt/boot/vmlinuz-linux

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
progress 74 "Writing the filesystem table…"

echo "Generating a fresh machine-id..."
rm -f /mnt/etc/machine-id
arch-chroot /mnt systemd-machine-id-setup
progress 76 "Setting machine ID…"

echo "Running postinstall (locale, keyboard, user, NVIDIA/KVM, GRUB, kiosk autologin)..."
progress 78 "Finishing setup…"
# postinstall/run.sh (inside the chroot) runs 4 known numbered steps.
# Tail its own log from out here and bump the bar/label each time one
# of them starts, so the single bar keeps moving and naming what it's
# actually doing instead of sitting still (or looking stuck) for the
# minute or two this takes.
POSTINSTALL_LOG=/mnt/var/log/layerosx-postinstall.log
: > "$POSTINSTALL_LOG" 2>/dev/null || true
(
    tail -F -n0 "$POSTINSTALL_LOG" 2>/dev/null | \
    while IFS= read -r line; do
        case "$line" in
            *"running: "*01-*.sh*) progress 80 "Setting locale, user, hostname…" ;;
            *"running: "*10-*.sh*) progress 86 "Detecting CPU/GPU hardware…" ;;
            *"running: "*40-*.sh*) progress 91 "Configuring kiosk autologin…" ;;
            *"running: "*50-*.sh*) progress 95 "Installing the bootloader…" ;;
        esac
    done
) &
TAIL_PID=$!

arch-chroot /mnt /root/postinstall/run.sh

# $TAIL_PID is the subshell wrapping `tail -F | while read...` above --
# killing just that PID does NOT reliably kill tail itself (a separate
# child process holding the pipe's write end), so tail can linger with
# an open file handle on $POSTINSTALL_LOG, which lives under /mnt. A
# leaked tail here is exactly what made `umount -R /mnt` below fail
# with "target is busy" on a real install -- and rebooting with the
# EFI System Partition (FAT32, holding the kernel/initramfs/grub.cfg
# we just wrote) still mounted risks losing/corrupting exactly those
# files before they're flushed to disk, which then shows up as a
# separate, confusing failure on the very next boot. Kill the subshell
# AND its direct children (found via /proc, no extra package needed)
# so nothing is left with a handle into /mnt.
kill "$TAIL_PID" 2>/dev/null || true
# shellcheck disable=SC2046
kill $(cat "/proc/$TAIL_PID/task/$TAIL_PID/children" 2>/dev/null) 2>/dev/null || true
wait "$TAIL_PID" 2>/dev/null || true

progress 98 "Cleaning up…"
# While /mnt is still mounted (so the postinstall log on the target
# gets picked up too, not just this script's own live-side log) --
# same save-logs-to-usb.sh as the ERR trap, so a *successful* install
# also leaves a copy behind, not just a failed one.
bash /opt/layerosx/kiosk/lib/save-logs-to-usb.sh 2>/dev/null || true

# Belt-and-suspenders on top of the tail fix above: retry a few times
# in case anything else is still settling (udev, a lingering loop
# device, ...), and if it's STILL busy after that, lazy-unmount rather
# than letting the whole install die right here at the last step and
# strand the user at a bare root shell instead of the "Done, reboot"
# dialog below (which is exactly what happened before this fix — the
# ERR trap fired, but silently, since zenity has no X to talk to by
# the time the script actually exits from under its own X session).
UMOUNT_OK=0
for _ in 1 2 3 4 5; do
    if umount -R /mnt 2>/dev/null; then
        UMOUNT_OK=1
        break
    fi
    sleep 1
done
if [ "$UMOUNT_OK" -ne 1 ] && mountpoint -q /mnt 2>/dev/null; then
    echo "WARNING: /mnt still busy after retries -- lazy-unmounting (umount -R -l) so the install can still finish and reboot cleanly." >&2
    umount -R -l /mnt 2>/dev/null || true
fi
progress 100 "Done."
exec 3>&-
wait "$ZENITY_PID" 2>/dev/null || true

zenity --info --width=480 --title="LayerOSX — Install" \
    --text="Done. Remove the installation media, then reboot." \
    --ok-label="Reboot now"
systemctl reboot
