#!/usr/bin/env bash
# First-run wizard: runs a single time, before any VM exists. Asks
# where macOS should come from and prepares $1 (VM disk) + $2
# (NVRAM/OVMF_VARS) for mac-vm-launch.sh to boot.
set -uo pipefail

VM_DISK="$1"
OVMF_VARS="$2"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
VM_SIZE_GB="${MAC_VM_SIZE_GB:-128}"

# A failed attempt here used to leave the user permanently stuck on a
# black screen: qemu-img create below makes $VM_DISK before the step
# that can actually fail (download/conversion), and mac-vm-launch.sh
# only shows this wizard again when $VM_DISK doesn't exist yet -- so
# an empty/partial $VM_DISK left behind by a failed attempt silently
# hid the "pick where macOS comes from" screen forever, even across a
# full reboot, with no obvious way back in. This cleans up any
# partial output whenever the wizard exits non-zero (any zenity
# --error + exit 1 path below, or an unhandled crash) so the next
# boot shows the options again instead of a black screen.
cleanup_failed_attempt() {
    local ec=$?
    if [ "$ec" -ne 0 ]; then
        echo "Wizard failed (exit $ec) -- removing any partial VM disk so the options are shown again on the next boot instead of a stuck black screen." >&2
        rm -f "$VM_DISK" "${VM_DISK%.qcow2}-recovery.qcow2" "${VM_DISK%.qcow2}-installer.qcow2" "$OVMF_VARS" 2>/dev/null || true
    fi
}
trap cleanup_failed_attempt EXIT

# has_internet / ensure_internet (zenity network picker, nmtui kept
# as an "Advanced" fallback) live in here now -- shared with anything
# else that ever needs a connectivity check/Wi-Fi picker.
source "$LIB_DIR/wifi-setup.sh"

# Everything this script (and whatever it calls) prints to
# stdout/stderr is already flowing into ~/mac-vm.log -- mac-vm-launch.sh
# (the parent process) redirects its own output there before running
# this script as a regular subprocess, and a plain subprocess
# inherits its parent's already-redirected file descriptors. So
# there's no separate log file to manage here: F2 (see
# lib/install-f2-keybind.sh, wired up from .xinitrc) already tails
# that exact file, and it already has everything.
#
# Runs a command with a zenity progress dialog instead of a visible
# terminal -- a download or a disk-image conversion can take a
# while, and used to just open an xterm running the command directly
# (correct, but exactly the kind of raw-terminal-by-default the
# install experience is trying to get away from -- see README.md).
# Real percentage isn't available for every command here
# (fetch-macOS-v2.py's download and dmg2img's extraction don't print
# anything reliably parseable), so this pulsates rather than guessing
# -- still far better than a black screen, and F2 opens a terminal
# tailing the exact same output live for anyone who wants to see it.
run_with_progress() {
    local title="$1" text="$2"
    shift 2

    echo "----- $text -----"

    local fifo
    fifo=$(mktemp -u /tmp/layerosx-wizard-progress.XXXXXX)
    mkfifo "$fifo"
    zenity --progress --pulsate --no-cancel --auto-close \
        --title="$title" --text="$text" --width=520 \
        < "$fifo" 2>/dev/null &
    local zpid=$!
    exec 4>"$fifo"
    rm -f "$fifo"

    "$@"
    local rc=$?

    printf '100\n' >&4
    exec 4>&-
    wait "$zpid" 2>/dev/null || true
    return "$rc"
}

# Same idea, but for the one case where a real percentage IS easy to
# get: `qemu-img convert -p` prints its own progress, and this is a
# conversion we invoke directly (not buried inside another script),
# so it's simple to parse live -- same FIFO pattern install-wizard.sh
# uses for rsync's progress.
run_convert_with_progress() {
    local title="$1" text="$2" src="$3" dst="$4"

    echo "----- $text -----"

    local fifo
    fifo=$(mktemp -u /tmp/layerosx-wizard-progress.XXXXXX)
    mkfifo "$fifo"
    zenity --progress --no-cancel --auto-close \
        --title="$title" --text="$text" --width=520 \
        < "$fifo" 2>/dev/null &
    local zpid=$!
    exec 4>"$fifo"
    rm -f "$fifo"

    qemu-img convert -p -f raw -O qcow2 "$src" "$dst" 2>&1 | \
        stdbuf -oL tr '\r' '\n' | stdbuf -oL grep --line-buffered -oE '[0-9]{1,3}(\.[0-9]+)?%' | \
        while IFS= read -r raw; do
            raw="${raw%\%}"; raw="${raw%.*}"
            printf '%s\n' "$raw" >&4
            printf '#%s (%s%%)\n' "$text" "$raw" >&4
        done
    local rc=${PIPESTATUS[0]}

    printf '100\n' >&4
    exec 4>&-
    wait "$zpid" 2>/dev/null || true
    return "$rc"
}

# Confirmed on real hardware: this used to point at
# /usr/share/edk2-ovmf/x64/OVMF_VARS.fd, which doesn't exist --
# Arch's edk2-ovmf package actually installs to /usr/share/edk2/x64/
# (not .../edk2-ovmf/x64/), and the files themselves are named
# OVMF_CODE.4m.fd / OVMF_VARS.4m.fd (the "4m" 4MiB-flash variant), not
# the plain names assumed here. This `cp` failing was silent (no
# `set -e` in this script) -- it printed an error and just kept going
# straight into an 800MB+ download that was doomed from the start,
# since mac-vm-launch.sh's own OVMF_CODE.fd reference was equally
# wrong (fixed there too, see README.md). Centralized into one
# function that actually fails loudly instead, so a future path
# change like this doesn't waste a download again before anyone
# notices.
copy_ovmf_vars() {
    if ! cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$OVMF_VARS"; then
        zenity --error --width=520 --title="LayerOSX — first run" \
            --text="Couldn't find the OVMF firmware (edk2-ovmf package) at the expected path -- this is a LayerOSX bug, not something wrong with your setup. Please report it." \
            2>/dev/null || true
        exit 1
    fi
}

# No udisks2/gvfs automount daemon on this minimal kiosk, so a USB
# drive plugged in with the file on it is otherwise completely
# invisible to zenity's file-selection dialog -- mount whatever's
# there first so it's actually browsable.
bash "$LIB_DIR/mount-removable-media.sh" 2>/dev/null || true

CHOICE=$(zenity --list --radiolist --width=620 --height=280 \
    --title="LayerOSX — first run" \
    --text="Where should macOS come from? (only asked once)" \
    --column="" --column="Option" \
    TRUE  "Download the recovery image directly from Apple (recommended)" \
    FALSE "I already have macOS (VM disk, installer .dmg, or recovery/installer .iso) — pick a file")

[ -n "$CHOICE" ] || exit 1

case "$CHOICE" in
    *recommended*)
        ensure_internet || exit 1
        qemu-img create -f qcow2 "$VM_DISK" "${VM_SIZE_GB}G"
        copy_ovmf_vars
        if ! run_with_progress "LayerOSX — first run" "Downloading macOS recovery image… (press F2 for details)" \
            bash "$LIB_DIR/fetch-recovery.sh" "$VM_DISK"; then
            zenity --error --width=520 --title="LayerOSX — first run" \
                --text="Couldn't download the macOS recovery image. Press F2 to see the details, check your internet connection, and try again."
            exit 1
        fi
        ;;
    *"pick a file"*)
        # Tkinter/Tk, not zenity (GTK) -- see lib/pick-source-file.py's
        # own header comment for why: zenity's GTK dependency is what
        # already crashed it once on this project.
        SRC=$(python3 "$LIB_DIR/pick-source-file.py")
        [ -n "$SRC" ] || exit 1

        copy_ovmf_vars

        case "$SRC" in
            *.qcow2|*.img|*.raw|*.IMG|*.RAW)
                # A complete, already-installed macOS disk -- boots
                # directly, no installer step needed.
                echo "Copying $SRC as the VM disk (already a complete system, not installer media)..."
                cp -v "$SRC" "$VM_DISK"
                ;;
            *.iso|*.ISO)
                # Recovery/installer media (not a complete system) --
                # goes on the SEPARATE disk mac-vm-launch.sh attaches
                # alongside a blank $VM_DISK, same as the .dmg path
                # below. ISO files are raw ISO9660 data, not a qcow2
                # container, hence -f raw on the way in.
                qemu-img create -f qcow2 "$VM_DISK" "${VM_SIZE_GB}G"
                INSTALLER_DISK="${VM_DISK%.qcow2}-installer.qcow2"
                if ! run_convert_with_progress "LayerOSX — first run" "Preparing installer from .iso… (press F2 for details)" \
                    "$SRC" "$INSTALLER_DISK"; then
                    zenity --error --text="Couldn't convert this .iso into a VM disk. Press F2 to see the details, or try the 'download directly from Apple' option instead."
                    exit 1
                fi
                ;;
            *.dmg|*.DMG|*.app|*.APP)
                qemu-img create -f qcow2 "$VM_DISK" "${VM_SIZE_GB}G"
                if ! run_with_progress "LayerOSX — first run" "Preparing installer from .dmg… (press F2 for details)" \
                    bash "$LIB_DIR/extract-dmg-installer.sh" "$SRC" "$VM_DISK"; then
                    zenity --error --text="Couldn't prepare an installer from this .dmg (this is the most experimental part of the project — see docs/CHECKLIST.md). Press F2 to see the details, or try the 'download directly from Apple' option instead."
                    exit 1
                fi
                ;;
            *)
                zenity --error --text="Unrecognized file type: $SRC\n\nExpected a .qcow2/.img/.raw (complete VM disk), .iso (recovery/installer media), or .dmg/.app (macOS installer)."
                exit 1
                ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
