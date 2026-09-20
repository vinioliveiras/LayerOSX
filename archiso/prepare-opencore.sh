#!/usr/bin/env bash
# Stages a pre-built OpenCore boot disk (OpenCore.qcow2) into the archiso
# profile, so mac-vm-launch.sh can attach it ahead of the real macOS disk.
#
# Why this exists at all: confirmed by reading QEMU's own source and
# multiple real-world QEMU-macOS projects (dockur/macos, kholia/OSX-KVM) --
# plain OVMF + a stock "-cpu host -enable-kvm" QEMU command line is NOT
# enough to make the XNU kernel boot. macOS's kernel and several of its
# drivers probe for genuine Apple hardware during boot: an Apple SMC
# (System Management Controller) device, "Apple"-branded SMBIOS tables
# (board-id/model/serial/etc, which is what macOS actually keys its
# hardware-support decisions on, not just -cpu), and a small set of ACPI
# quirks/kernel patches most bare-metal Hackintosh and QEMU setups apply
# through the OpenCore bootloader before macOS's own kernel takes over.
# Without a real Mac's EFI firmware underneath, something has to supply
# all of that -- that's OpenCore's job here. (Two related things that
# LayerOSX does NOT need despite living in the same "hacks for macOS on
# non-Apple hardware" space: VMware's "unlocker" is irrelevant since this
# project uses QEMU, not VMware, which never blocks macOS guests in the
# first place; and reims-vgpu.com confirms the Reims-vGPU device itself
# needs no guest kext at all -- stock macOS's own AppleParavirtGPU.kext
# binds to it directly.)
#
# Rather than hand-assembling our own OpenCore EFI folder + kexts (high
# risk of a subtly wrong config.plist silently failing to boot, with no
# way for us to test-boot it ourselves before real hardware does), this
# reuses kholia/OSX-KVM's pre-built, widely-used OpenCore.qcow2 -- a
# small (~19MB) raw QEMU disk image containing OpenCore.efi, BOOTx64.efi,
# config.plist, and the handful of kexts (Lilu and friends) that config
# depends on. It is NOT encrypted despite `file`'s qcow2-v3-header-based
# guess of "AES-encrypted" -- confirmed directly with `qemu-img info`,
# and OSX-KVM's own OpenCore-Boot.sh attaches it with no secret/passphrase
# at all.
#
# Known limitation, intentionally not solved here: this ships the SAME
# default machine identity (serial/MLB/UUID/ROM baked into that qcow2's
# config.plist) to every LayerOSX install, same as anyone else who uses
# this file as-is. That's fine for installing and running macOS itself,
# but multiple machines sharing one Apple-assigned-looking serial number
# is exactly the kind of thing that can eventually cause iMessage/App
# Store/FaceTime activation to misbehave if several LayerOSX machines try
# to use those services at once. Regenerating a unique identity per
# install (dockur/macos does this in its boot.sh, using a proper Apple
# serial-format generator) is real future work -- see docs/CHECKLIST.md.
#
# Pinned to a specific commit (not "master") and checksum-verified,
# unlike prepare-qemu-macos.sh's looser master-tracking of qemus/qemu-macos
# -- that one gets re-verified by the Dockerfile's own build+verify stage
# every single run, this is a static binary blob with no such check of
# our own, so pinning + a known-good sha256 is the safety net here
# instead. Re-run this deliberately (bump the pin below) to pick up any
# future OSX-KVM update; it will never happen silently.
set -euo pipefail
cd "$(dirname "$0")"

OSX_KVM_COMMIT="4c378a4b5e0b219783683012bec680325eb40719"
OSX_KVM_URL="https://raw.githubusercontent.com/kholia/OSX-KVM/${OSX_KVM_COMMIT}/OpenCore/OpenCore.qcow2"
EXPECTED_SHA256="6ed36c0c2a4206ccc695f6b1a734a1cc6f94d288b0517c705d351c63cb92a6f3"

DEST_DIR="airootfs/opt/layerosx/opencore"
DEST="$DEST_DIR/OpenCore.qcow2"

echo "==> clearing any previous OpenCore boot image"
rm -f "$DEST"
mkdir -p "$DEST_DIR"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

echo "==> downloading OpenCore.qcow2 (kholia/OSX-KVM @ ${OSX_KVM_COMMIT:0:12})"
curl -fsSL "$OSX_KVM_URL" -o "$TMP"

ACTUAL_SHA256="$(sha256sum "$TMP" | cut -d' ' -f1)"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "FAIL: downloaded OpenCore.qcow2 does not match the pinned checksum." >&2
    echo "  expected: $EXPECTED_SHA256" >&2
    echo "  actual:   $ACTUAL_SHA256" >&2
    echo "  Either the pin in this script is stale, or the download was corrupted/tampered with -- not staging it." >&2
    exit 1
fi

# Cheap sanity check independent of qemu-img (which this build host may
# not have installed): every qcow2 file starts with the 4-byte magic
# "QFI\xfb" (0x51 0x46 0x49 0xfb). Catches a truncated/corrupted download
# or an unexpected file type even if the checksum pin above were ever
# updated to something bad by mistake. Uses python3 (not xxd) since
# that's not guaranteed present on the Arch build host itself -- python3
# already is, the rest of this profile depends on it throughout.
if ! python3 -c "
import sys
with open('$TMP', 'rb') as f:
    magic = f.read(4)
sys.exit(0 if magic == b'QFI\xfb' else 1)
"; then
    echo "FAIL: downloaded file does not start with the qcow2 magic bytes -- not a valid qcow2 image." >&2
    exit 1
fi

mv "$TMP" "$DEST"
trap - EXIT
chmod 644 "$DEST"

echo "==> done: OpenCore boot image staged at $DEST ($(du -h "$DEST" | cut -f1))"
