#!/usr/bin/env bash
# Main kiosk launcher (runs instead of a desktop, autologin of the
# "mac" user on tty1 — see postinstall/40-kiosk-autologin.sh).
#
# 1. If no VM exists yet, shows the first-run wizard
#    (macos-source-wizard.sh) — only happens once.
# 2. Launches QEMU (the qemus/qemu-macos build, with Reims-vGPU) in
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
LOG="$HOME/mac-vm.log"

exec > >(tee -a "$LOG") 2>&1
sudo mkdir -p "$STATE_DIR"
sudo chown "$(id -u):$(id -g)" "$STATE_DIR"

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

    # TODO(verify): the exact accelerated-video flag for Reims-vGPU
    # (device/driver exposed by the qemus/qemu-macos build) needs to
    # be confirmed against that project's README before the first
    # real test — the `-display sdl,gl=on` below is the bare minimum
    # to get a screen, but Reims's real acceleration may require its
    # own video device on the command line. See docs/CHECKLIST.md.
    qemu-system-x86_64 \
        -name "macOS" \
        -enable-kvm -m 8192 -smp cores=6,threads=1 -cpu host \
        -machine q35 \
        -no-reboot \
        -qmp "unix:${QMP_SOCK},server,nowait" \
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -drive if=virtio,file="$VM_DISK",format=qcow2 \
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
