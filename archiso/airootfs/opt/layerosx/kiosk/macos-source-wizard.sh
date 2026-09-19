#!/usr/bin/env bash
# First-run wizard: runs a single time, before any VM exists. Asks
# where macOS should come from and prepares $1 (VM disk) + $2
# (NVRAM/OVMF_VARS) for mac-vm-launch.sh to boot.
set -uo pipefail

VM_DISK="$1"
OVMF_VARS="$2"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
VM_SIZE_GB="${MAC_VM_SIZE_GB:-128}"

CHOICE=$(zenity --list --radiolist --width=560 --height=280 \
    --title="LayerOSX — first run" \
    --text="Where should macOS come from? (only asked once)" \
    --column="" --column="Option" \
    TRUE  "Download the recovery image directly from Apple (recommended)" \
    FALSE "I already have a macOS VM/disk (.qcow2 / .img) — pick it from disk" \
    FALSE "I already have an installer .dmg (App Store / another Mac) — pick it from disk")

[ -n "$CHOICE" ] || exit 1

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

case "$CHOICE" in
    *recommended*)
        qemu-img create -f qcow2 "$VM_DISK" "${VM_SIZE_GB}G"
        cp /usr/share/edk2-ovmf/x64/OVMF_VARS.fd "$OVMF_VARS"
        if ! run_in_terminal "LayerOSX — downloading macOS recovery…" \
            bash "$LIB_DIR/fetch-recovery.sh" "$VM_DISK"; then
            zenity --error --width=520 --title="LayerOSX — first run" \
                --text="Couldn't download the macOS recovery image (see the terminal output that just closed). Check your internet connection and try again."
            exit 1
        fi
        ;;
    *"I already have a macOS VM"*)
        SRC=$(zenity --file-selection --title="Pick the VM disk" \
            --file-filter="VM disks | *.qcow2 *.img *.raw")
        [ -n "$SRC" ] || exit 1
        cp "$SRC" "$VM_DISK"
        cp /usr/share/edk2-ovmf/x64/OVMF_VARS.fd "$OVMF_VARS"
        ;;
    *".dmg"*)
        SRC=$(zenity --file-selection --title="Pick the installer .dmg" \
            --file-filter="macOS installers | *.dmg *.app")
        [ -n "$SRC" ] || exit 1
        qemu-img create -f qcow2 "$VM_DISK" "${VM_SIZE_GB}G"
        cp /usr/share/edk2-ovmf/x64/OVMF_VARS.fd "$OVMF_VARS"
        if ! run_in_terminal "LayerOSX — preparing installer from .dmg…" \
            bash "$LIB_DIR/extract-dmg-installer.sh" "$SRC" "$VM_DISK"; then
            zenity --error --text="Couldn't prepare an installer from this .dmg (this is the most experimental part of the project — see docs/CHECKLIST.md). Try the 'download directly from Apple' option instead."
            exit 1
        fi
        ;;
    *)
        exit 1
        ;;
esac
