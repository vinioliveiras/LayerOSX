#!/usr/bin/env bash
# First-run wizard: runs a single time, before any VM exists. Asks
# where macOS should come from and prepares $1 (VM disk) + $2
# (NVRAM/OVMF_VARS) for mac-vm-launch.sh to boot.
set -uo pipefail

VM_DISK="$1"
OVMF_VARS="$2"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
VM_SIZE_GB="${MAC_VM_SIZE_GB:-128}"

# Runs a command inside a visible xterm instead of silently in the
# background -- fetch-recovery.sh/extract-dmg-installer.sh can take a
# while (a multi-GB download, or converting a disk image) with zero
# zenity feedback of their own, which otherwise just looks like a
# frozen/black screen. The xterm closes itself a couple seconds after
# a successful run; on failure it waits for Enter so the error output
# stays readable before the caller's own zenity error dialog shows.
run_in_terminal() {
    local title="$1"
    shift
    xterm -fa Monospace -fs 12 -bg black -fg white -T "$title" -e bash -c \
        '"$@"; ec=$?; echo; if [ "$ec" -eq 0 ]; then echo "Done."; sleep 2; else echo "Failed (exit code $ec) -- press Enter to continue."; read -r _; fi; exit "$ec"' \
        _ "$@"
}

# Cheap connectivity probe against the exact host fetch-recovery.sh
# needs -- good enough to decide whether to bother the user with
# Wi-Fi setup before even trying the real download.
has_internet() {
    curl -fsS --max-time 5 -o /dev/null https://osrecovery.apple.com 2>/dev/null
}

# This is a minimal openbox kiosk, no network applet in a panel
# (there's no panel) -- NetworkManager is already enabled
# (postinstall/01-base-system.sh) but nothing ever exposed a way to
# actually pick a Wi-Fi network and type a password. `nmtui` (part of
# the already-installed networkmanager package) does exactly that,
# just needs a terminal to run in.
ensure_internet() {
    has_internet && return 0
    zenity --question --width=480 --title="LayerOSX — first run" \
        --text="No internet connection detected, and downloading macOS needs one.\n\nOpen Wi-Fi setup now?" \
        --ok-label="Open Wi-Fi setup" --cancel-label="Cancel" || return 1
    xterm -fa Monospace -fs 12 -bg black -fg white \
        -T "LayerOSX — Wi-Fi setup (Esc/Q in nmtui when connected)" \
        -e nmtui
    if ! has_internet; then
        zenity --error --width=480 --title="LayerOSX — first run" \
            --text="Still no internet connection. Pick this option again once you're connected, or use the 'pick a file' option instead if you already have macOS on a disk/USB drive."
        return 1
    fi
    return 0
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
        cp /usr/share/edk2-ovmf/x64/OVMF_VARS.fd "$OVMF_VARS"
        if ! run_in_terminal "LayerOSX — downloading macOS recovery…" \
            bash "$LIB_DIR/fetch-recovery.sh" "$VM_DISK"; then
            zenity --error --width=520 --title="LayerOSX — first run" \
                --text="Couldn't download the macOS recovery image (see the terminal output that just closed). Check your internet connection and try again."
            exit 1
        fi
        ;;
    *"pick a file"*)
        SRC=$(zenity --file-selection --title="Pick a macOS VM disk, .dmg, or .iso" \
            --filename="/mnt/media/" \
            --file-filter="macOS sources | *.qcow2 *.img *.raw *.iso *.dmg *.app" \
            --file-filter="All files | *")
        [ -n "$SRC" ] || exit 1

        cp /usr/share/edk2-ovmf/x64/OVMF_VARS.fd "$OVMF_VARS"

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
                if ! run_in_terminal "LayerOSX — preparing installer from .iso…" \
                    qemu-img convert -f raw -O qcow2 "$SRC" "$INSTALLER_DISK"; then
                    zenity --error --text="Couldn't convert this .iso into a VM disk. Try the 'download directly from Apple' option instead."
                    exit 1
                fi
                ;;
            *.dmg|*.DMG|*.app|*.APP)
                qemu-img create -f qcow2 "$VM_DISK" "${VM_SIZE_GB}G"
                if ! run_in_terminal "LayerOSX — preparing installer from .dmg…" \
                    bash "$LIB_DIR/extract-dmg-installer.sh" "$SRC" "$VM_DISK"; then
                    zenity --error --text="Couldn't prepare an installer from this .dmg (this is the most experimental part of the project — see docs/CHECKLIST.md). Try the 'download directly from Apple' option instead."
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
