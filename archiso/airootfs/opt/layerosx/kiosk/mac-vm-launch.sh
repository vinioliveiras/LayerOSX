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
sudo mkdir -p "$STATE_DIR"
sudo chown "$(id -u):$(id -g)" "$STATE_DIR"

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
    "$QEMU_BIN" \
        -name "macOS" \
        -enable-kvm -m 8192 -smp cores=6,threads=1 -cpu host \
        -machine q35 \
        -no-reboot \
        -qmp "unix:${QMP_SOCK},server,nowait" \
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -drive if=virtio,file="$VM_DISK",format=qcow2 \
        -device reims-vgpu-pci,romfile=reims-vgpu-gop.rom \
        -display sdl,gl=on,full-screen=on \
        -usb -device usb-kbd -device usb-tablet \
        -netdev user,id=net0 -device virtio-net,netdev=net0 &
    QEMU_PID=$!

    for _ in $(seq 1 50); do [ -S "$QMP_SOCK" ] && break; sleep 0.2; done

    ACTION=$(python3 "$KIOSK_DIR/qmp-watch.py" "$QMP_SOCK")
    wait "$QEMU_PID" 2>/dev/null

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
