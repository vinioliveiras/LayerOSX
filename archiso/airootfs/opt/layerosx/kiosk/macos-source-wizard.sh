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

case "$CHOICE" in
    *recommended*)
        qemu-img create -f qcow2 "$VM_DISK" "${VM_SIZE_GB}G"
        cp /usr/share/edk2-ovmf/x64/OVMF_VARS.fd "$OVMF_VARS"
        bash "$LIB_DIR/fetch-recovery.sh" "$VM_DISK"
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
        if ! bash "$LIB_DIR/extract-dmg-installer.sh" "$SRC" "$VM_DISK"; then
            zenity --error --text="Couldn't prepare an installer from this .dmg (this is the most experimental part of the project — see docs/CHECKLIST.md). Try the 'download directly from Apple' option instead."
            exit 1
        fi
        ;;
    *)
        exit 1
        ;;
esac
