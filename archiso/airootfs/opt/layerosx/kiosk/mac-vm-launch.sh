#!/usr/bin/env bash
# Main kiosk launcher (runs instead of a desktop, autologin of the
# "mac" user on tty1 — see postinstall/40-kiosk-autologin.sh).
#
# 1. If no VM exists yet, shows the first-run wizard
#    (macos-source-wizard.sh) — only happens once.
# 2. Launches our custom-built qemu-system-x86_64 (Reims-vGPU baked
#    in, staged by ../../../prepare-qemu-macos.sh at build time) in
#    fullscreen.
# 3. Waits for a QMP event to find out IF and HOW macOS asked to power
#    off, and translates that into a real action on the physical
#    machine:
#      Shut Down (inside macOS) -> systemctl poweroff (for real)
#      Restart   (inside macOS) -> systemctl reboot   (for real)
#    (decided this way on purpose: a Restart also reboots the Arch
#    underneath, in case Arch itself is having problems.)
set -uo pipefail

STATE_DIR="/var/lib/layerosx"
VM_DISK="$STATE_DIR/macos.qcow2"
OVMF_VARS="$STATE_DIR/OVMF_VARS.fd"
QMP_SOCK="/tmp/macvm-qmp.sock"
KIOSK_DIR="/opt/layerosx/kiosk"
QEMU_BIN="/opt/layerosx/bin/qemu-system-x86_64"
LOG="$HOME/mac-vm.log"

exec > >(tee -a "$LOG") 2>&1

# The build container qemus/qemu-macos compiles this binary in
# (Debian-based, with --enable-vnc-jpeg among other features) links
# it against a couple of libraries whose SONAME doesn't match what
# Arch ships -- libjpeg is the confirmed one on real hardware
# ("error while loading shared libraries: libjpeg.so.62: cannot open
# shared object file"), which made QEMU fail to even start at all
# (immediately, every single launch) rather than a display/rendering
# problem -- see README.md. prepare-qemu-macos.sh now bundles an
# exact copy of every such library (extracted from the same verified
# build image the binary was tested in) alongside the binary; point
# the loader at it here so it's actually used.
if [ -d /opt/layerosx/lib ] && [ -n "$(ls -A /opt/layerosx/lib 2>/dev/null)" ]; then
    export LD_LIBRARY_PATH="/opt/layerosx/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
sudo mkdir -p "$STATE_DIR"
sudo chown "$(id -u):$(id -g)" "$STATE_DIR"

# Leave 2 cores for the host (Arch underneath still needs to breathe),
# minimum 1 for the VM. Was hardcoded to 6 — fine on the original dev
# machine, wrong on anything with fewer (or a lot more) cores.
TOTAL_CORES="$(nproc)"
if [ "$TOTAL_CORES" -gt 2 ]; then
    VM_CORES=$((TOTAL_CORES - 2))
else
    VM_CORES=1
fi

if [ ! -x "$QEMU_BIN" ]; then
    echo "FATAL: $QEMU_BIN is missing. The ISO was built without running prepare-qemu-macos.sh first — see docs/CHECKLIST.md." >&2
    exit 1
fi

if [ ! -f "$VM_DISK" ]; then
    echo "No VM found — opening the first-run wizard."
    if ! "$KIOSK_DIR/macos-source-wizard.sh" "$VM_DISK" "$OVMF_VARS"; then
        echo "The wizard failed or was cancelled. Retrying in 10s (switch to tty2 with Alt+F2 if you need to get out)."
        sleep 10
        exec "$0"
    fi
fi

# macos-source-wizard.sh's "download from Apple" and ".dmg" paths both
# prepare a SECOND disk image (the recovery BaseSystem, or an
# extracted installer) alongside $VM_DISK -- but until now nothing
# ever attached it here, so the VM only ever saw the empty target
# disk and had nothing to boot at all (black screen, no error either
# — QEMU/OVMF just sits there with no bootable device). Attach
# whichever one exists, every boot: harmless once macOS is actually
# installed onto $VM_DISK (OVMF's own boot manager picks the disk
# that's actually bootable), and it's what actually lets the first
# boot reach the recovery/installer environment at all.
RECOVERY_DISK=""
for _cand in "${VM_DISK%.qcow2}-recovery.qcow2" "${VM_DISK%.qcow2}-installer.qcow2"; do
    if [ -f "$_cand" ]; then
        RECOVERY_DISK="$_cand"
        break
    fi
done

RETRIES=0
while true; do
    rm -f "$QMP_SOCK"

    # reims-vgpu-pci is the real device name (confirmed by reading the
    # qemus/qemu-macos Dockerfile's own verification step, which
    # probes it with `-device reims-vgpu-pci,help`). The `romfile=`
    # property below is QEMU's normal convention for a PCI device's
    # option ROM, matching where prepare-qemu-macos.sh stages
    # reims-vgpu-gop.rom — but the exact property names on this device
    # still need confirming: run
    #   sudo /opt/layerosx/bin/qemu-system-x86_64 -device reims-vgpu-pci,help
    # after the ISO is built and fix the line below if it disagrees.
    # See docs/CHECKLIST.md.
    QEMU_ARGS=(
        -name "macOS"
        -enable-kvm -m 8192 -smp "cores=${VM_CORES},threads=1" -cpu host
        -machine q35
        -no-reboot
        -qmp "unix:${QMP_SOCK},server,nowait"
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2-ovmf/x64/OVMF_CODE.fd
        -drive if=pflash,format=raw,file="$OVMF_VARS"
        -drive if=virtio,file="$VM_DISK",format=qcow2
        -device reims-vgpu-pci,romfile=reims-vgpu-gop.rom
        -display sdl,gl=on,full-screen=on
        -usb -device usb-kbd -device usb-tablet
        -netdev user,id=net0 -device virtio-net,netdev=net0
    )
    if [ -n "$RECOVERY_DISK" ]; then
        echo "Attaching recovery/installer disk: $RECOVERY_DISK"
        # Same if=virtio interface as $VM_DISK, for consistency with
        # the rest of this invocation -- if macOS's own recovery/
        # installer environment turns out to need a real AHCI/SATA
        # disk instead (no virtio block driver that early), swap this
        # to `-device ahci,id=ahci -device ide-hd,bus=ahci.0,drive=rec
        # -drive if=none,id=rec,file=...,format=qcow2`. Untested on
        # real hardware yet — see docs/CHECKLIST.md.
        QEMU_ARGS+=(-drive if=virtio,file="$RECOVERY_DISK",format=qcow2)
    fi

    "$QEMU_BIN" "${QEMU_ARGS[@]}" &
    QEMU_PID=$!

    for _ in $(seq 1 50); do [ -S "$QMP_SOCK" ] && break; sleep 0.2; done

    ACTION=$(python3 "$KIOSK_DIR/qmp-watch.py" "$QMP_SOCK")
    wait "$QEMU_PID" 2>/dev/null

    # Every QEMU session's outcome, good or bad, gets a fresh copy of
    # this log (and a journal snapshot) onto the USB -- during testing
    # this matters most right after a crash/black-screen exit, which
    # is exactly when there's no other easy way to see what happened.
    bash "$KIOSK_DIR/lib/save-logs-to-usb.sh" 2>/dev/null || true

    case "$ACTION" in
        host-poweroff)
            echo "macOS asked to Shut Down — powering off the physical machine."
            sudo systemctl poweroff
            exit 0
            ;;
        host-reboot)
            echo "macOS asked to Restart — rebooting the physical machine."
            sudo systemctl reboot
            exit 0
            ;;
        vm-only|*)
            echo "QEMU exited without a clear guest request (action: ${ACTION}) — relaunching just the VM."
            RETRIES=$((RETRIES + 1))
            if [ "$RETRIES" -ge 5 ]; then
                echo "Too many failures in a row — rebooting the physical machine as a last resort."
                sudo systemctl reboot
                exit 1
            fi
            sleep 3
            ;;
    esac
done
