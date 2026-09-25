#!/usr/bin/env bash
# Live-ISO install flow. Replaces Calamares: Calamares has never been
# in Arch's official repos (only the AUR), and we decided against both
# pulling in a third-party binary repo (Chaotic-AUR doesn't carry it
# anyway) and compiling its Qt/KDE dependency chain from the AUR at
# build time (see DEVLOG.md for the full reasoning).
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
# Which build this ISO is (build.sh: etc/layerosx/version) -- in every
# dialog title, so it's obvious whether the USB has the newest build.
BUILD_LABEL="$(sed -n 's/^build=//p' /etc/layerosx/version 2>/dev/null)"
BUILD_WHEN="$(sed -n 's/^built=//p' /etc/layerosx/version 2>/dev/null)"
if [ -n "$BUILD_LABEL" ]; then BUILD_LABEL="build $BUILD_LABEL${BUILD_WHEN:+ · $BUILD_WHEN}"
elif [ -n "$BUILD_WHEN" ]; then BUILD_LABEL="built $BUILD_WHEN"; fi
echo "===== LayerOSX install: $(date -Is) -- ${BUILD_LABEL:-development build} ====="

# Dialogs use the same look as the installed system (default Adwaita,
# rounded by picom -- started in the live .xinitrc), not the old forced
# black-and-white GTK theme. Clear what older live sessions wrote.
rm -f ~/.config/gtk-3.0/gtk.css ~/.config/gtk-3.0/settings.ini 2>/dev/null || true

# Without this, a failure partway through (mount, rsync, genfstab,
# arch-chroot, ...) would just get logged and the script would keep
# going — silently reaching the "Done, reboot" dialog and rebooting
# into a broken/incomplete install. set -e stops on the first
# unexpected failure, and this trap actually tells you so instead of
# leaving you looking at a dead black screen with no explanation.
trap 'exec 3>&- 2>/dev/null || true
    bash /opt/layerosx/kiosk/lib/save-logs-to-usb.sh 2>/dev/null || true
    zenity --error --width=560 --title="LayerOSX — Install${BUILD_LABEL:+ ($BUILD_LABEL)}" \
    --text="Something went wrong during install and it stopped (see the log for details).\n\nLog: $LOG\n\nA copy was also just saved to the USB drive itself (layerosx-logs/ folder) if one was reachable — readable from any machine, no need to type anything here.\n\nOpen a terminal (Ctrl+Alt+F2, login: root / layerosx) to look, then reboot and try again — nothing was rebooted, so you are not stuck with a broken install." \
    2>/dev/null || true' ERR

zenity --info --width=560 --title="LayerOSX — Install${BUILD_LABEL:+ ($BUILD_LABEL)}" \
    --text="LayerOSX ${BUILD_LABEL:-development build}\n\nNext: GParted opens so you can partition the disk.\n\nCreate at least:\n  • an EFI System Partition (fat32, ~512MB, flag 'esp'/'boot')\n  • a root partition (ext4, using the rest of the disk)\n\nFormat both from inside GParted itself -- EXCEPT when reinstalling over LayerOSX and you want to keep your Mac: then leave that partition as it is (the installer will offer to keep it). When you're done, apply the changes and close GParted to continue.\n\nTip: once the install itself is running, press Ctrl+Alt+T any time to open a terminal showing exactly what's happening (safe to close again, doesn't pause anything)." \
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
    --title="LayerOSX — Install${BUILD_LABEL:+ ($BUILD_LABEL)}" \
    --text="Which partition is the ROOT filesystem (/)? Its entire content will be replaced." \
    --column="Partition" --column="Size" --column="Filesystem" "${ROWS[@]}")
[ -n "$ROOT_PART" ] || exit 1

ESP_PART=$(zenity --list --width=600 --height=320 \
    --title="LayerOSX — Install${BUILD_LABEL:+ ($BUILD_LABEL)}" \
    --text="Which partition is the EFI System Partition (fat32, ~512MB)?" \
    --column="Partition" --column="Size" --column="Filesystem" "${ROWS[@]}")
[ -n "$ESP_PART" ] || exit 1

zenity --question --width=480 --title="LayerOSX — Install${BUILD_LABEL:+ ($BUILD_LABEL)}" \
    --text="This will ERASE the content of $ROOT_PART and install LayerOSX there, using $ESP_PART as the EFI partition.\n\nThis cannot be undone. Continue?" \
    || exit 1

# Maintenance password = the kiosk user's ("mac") password. It unlocks the Ctrl+Alt+T
# maintenance terminal in builds that ship it password-protected (the release
# default, see build.sh LAYEROSX_TERMINAL / lib/maint-terminal.sh). Asked here,
# before the long copy, and applied after postinstall created the user. Skipping
# keeps postinstall's default ("mac") -- fine for testing, not for a machine
# other people can reach.
MAINT_PW=""
while true; do
    _p1=$(zenity --password --title="LayerOSX — Password for the \"mac\" user" \
        --text="Choose a password for the Linux user \"mac\" (text-console login and sudo).\nThe optional Maintenance password is set later in Settings > Maintenance.\nCancel = keep the default password \"mac\"." 2>/dev/null) || { _p1=""; break; }
    [ -n "$_p1" ] || continue
    _p2=$(zenity --password --title="LayerOSX — Password for the \"mac\" user" \
        --text="Type it again to confirm." 2>/dev/null) || { _p1=""; break; }
    if [ "$_p1" = "$_p2" ]; then MAINT_PW="$_p1"; break; fi
    zenity --error --width=320 --title="LayerOSX — Password for the \"mac\" user" --text="The passwords don't match." 2>/dev/null
done
unset _p1 _p2

echo "Mounting $ROOT_PART at /mnt, $ESP_PART at /mnt/boot..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$ESP_PART" /mnt/boot

# Reinstalling over an existing LayerOSX? Its Mac lives in /var/lib/layerosx
# (macos.qcow2 = the macOS disk, OVMF_VARS.fd = its NVRAM, the recovery image
# and the Settings choices). Offer to keep it: it's moved aside on the same
# filesystem (a rename -- instant, no space needed), everything else on the
# partition is removed, the new system is copied, and the Mac is put back.
KEEP_MAC=0
if [ -e /mnt/var/lib/layerosx/macos.qcow2 ]; then
    if zenity --question --width=520 --title="LayerOSX — Install${BUILD_LABEL:+ ($BUILD_LABEL)}" \
        --ok-label="Keep my Mac" --cancel-label="Erase it" \
        --text="$ROOT_PART already has a LayerOSX Mac (macOS, your files in it, and its settings).\n\nKeep my Mac: LayerOSX is reinstalled around it; macOS, your files and settings stay.\nErase it: start from scratch (macOS will be installed again)." 2>/dev/null; then
        KEEP_MAC=1
        echo "Keeping the existing Mac: moving /var/lib/layerosx aside..."
        rm -rf /mnt/.layerosx-keep
        mv /mnt/var/lib/layerosx /mnt/.layerosx-keep
    fi
fi
# The partition may not have been formatted in GParted (reinstall): clear it
# so no file of the old system is left behind -- but never the kept Mac, the
# mounted ESP or ext4's lost+found.
if [ "$KEEP_MAC" = 1 ]; then echo "Clearing $ROOT_PART (keeping the Mac)..."; else echo "Clearing $ROOT_PART..."; fi
find /mnt -mindepth 1 -maxdepth 1 ! -name boot ! -name .layerosx-keep ! -name lost+found -exec rm -rf {} +

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
    --title="LayerOSX — Install${BUILD_LABEL:+ ($BUILD_LABEL)}" --text="Starting…" --width=560 \
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
if [ "$KEEP_MAC" = 1 ]; then
    echo "Putting the kept Mac back in /var/lib/layerosx..."
    mkdir -p /mnt/var/lib
    rm -rf /mnt/var/lib/layerosx
    mv /mnt/.layerosx-keep /mnt/var/lib/layerosx
fi
echo "Recreating dev/proc/sys/run/tmp/mnt/media mount points (rsync skips these on purpose)..."
mkdir -p /mnt/dev /mnt/proc /mnt/sys /mnt/run /mnt/tmp /mnt/mnt /mnt/media
chmod 1777 /mnt/tmp
progress 72 "Preparing the new system…"

# archiso never ships the kernel (vmlinuz-linux) inside the live
# squashfs -- it only lives on the ISO's own boot media, loaded
# directly by the bootloader before the squashfs is even mounted (see
# the long comment in postinstall/01-base-system.sh for the full
# story, including why a pacman-based fix doesn't work offline).
# rsync can't restore what was never part of "/" in the first place.
#
# customize_airootfs.sh (build time) stashes a copy at
# /opt/layerosx/vmlinuz-linux.stashed specifically so this step never
# has to depend on the live boot medium still being mounted/reachable
# here -- an earlier version of this fix searched for it at runtime
# instead (matching mkarchiso's own
# "<install_dir>/boot/<arch>/vmlinuz-linux" layout on the medium
# itself) and that turned out to be unreliable on real hardware via
# Ventoy (confirmed failing on an actual install; never pinned down
# exactly why -- possibly the medium gets unmounted once the squashfs
# is copied to RAM, possibly Ventoy's mount layout just doesn't match
# plain archiso's). Kept below as a fallback in case an older ISO was
# built before the stash existed.
echo "Copying the real kernel into /mnt/boot..."
INSTALL_DIR="layerosx"   # must match profiledef.sh's install_dir
ARCH="x86_64"            # must match profiledef.sh's arch
KERNEL_SRC=""

if [ -f /opt/layerosx/vmlinuz-linux.stashed ]; then
    KERNEL_SRC="/opt/layerosx/vmlinuz-linux.stashed"
else
    echo "WARNING: no build-time kernel stash found (older ISO build?) -- falling back to searching the live boot medium at runtime." >&2
    if [ -f "/run/archiso/bootmnt/$INSTALL_DIR/boot/$ARCH/vmlinuz-linux" ]; then
        KERNEL_SRC="/run/archiso/bootmnt/$INSTALL_DIR/boot/$ARCH/vmlinuz-linux"
    else
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
        KERNEL_SRC=$(find /run -maxdepth 6 -type f -name 'vmlinuz-linux' 2>/dev/null | head -n1)
    fi
fi

if [ -z "$KERNEL_SRC" ]; then
    # Shouldn't happen with the build-time stash in place, but if it
    # ever does again: dump real diagnostics into $LOG (this script's
    # own stdout/stderr already tee to it) instead of guessing blind
    # again, and push a copy to the USB right here -- this specific
    # failure exits before reaching the ERR trap below (an explicit
    # `exit` doesn't trigger it), so without this call nothing would
    # get saved at all.
    echo "=== kernel search failed -- diagnostics ===" >&2
    echo "--- findmnt ---" >&2
    findmnt >&2 2>&1
    echo "--- /opt/layerosx (should contain vmlinuz-linux.stashed) ---" >&2
    ls -la /opt/layerosx >&2 2>&1
    echo "--- /run/archiso ---" >&2
    find /run/archiso -maxdepth 4 >&2 2>&1
    echo "=== end diagnostics ===" >&2
    bash /opt/layerosx/kiosk/lib/save-logs-to-usb.sh 2>/dev/null || true
    zenity --error --width=560 --title="LayerOSX — Install${BUILD_LABEL:+ ($BUILD_LABEL)}" \
        --text="Could not find the kernel anywhere (looked for the build-time stash and the boot medium). A diagnostic dump was saved to the USB drive's layerosx-logs/ folder if one was reachable.\n\nMake sure you're still booted from the LayerOSX USB/ISO, then reboot and try again." \
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

if [ "$KEEP_MAC" = 1 ]; then
    # The new "mac" user may not have the old one's uid: hand the Mac to it.
    arch-chroot /mnt chown -R mac:mac /var/lib/layerosx \
        && echo "Kept Mac handed to the new 'mac' user." \
        || echo "WARNING: couldn't chown /var/lib/layerosx to mac." >&2
fi

if [ -n "$MAINT_PW" ]; then
    # chpasswd reads "user:password" on stdin -- never on the command line, so
    # it doesn't show up in ps or the install log.
    printf 'mac:%s\n' "$MAINT_PW" | arch-chroot /mnt chpasswd \
        && echo "Maintenance password set." \
        || echo "WARNING: couldn't set the maintenance password -- the default 'mac' is still in place." >&2
else
    echo "No maintenance password chosen -- the kiosk user keeps the default password 'mac'."
fi
unset MAINT_PW

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

zenity --info --width=480 --title="LayerOSX — Install${BUILD_LABEL:+ ($BUILD_LABEL)}" \
    --text="Done. Remove the installation media, then reboot." \
    --ok-label="Reboot now"
systemctl reboot
