#!/usr/bin/env bash
# Lançador principal do kiosk (corre em vez de desktop, autologin do
# utilizador "mac" na tty1 — ver postinstall/40-kiosk-autologin.sh).
#
# 1. Se ainda não existe nenhuma VM, mostra o wizard de primeira
#    execução (macos-source-wizard.sh) — só acontece uma vez.
# 2. Lança o QEMU (build do qemus/qemu-macos, com Reims-vGPU) em
#    fullscreen.
# 3. Fica à espera de um evento QMP para saber SE e COMO o macOS pediu
#    para desligar, e traduz isso numa ação a sério na máquina física:
#      Shut Down (dentro do macOS) -> systemctl poweroff (a sério)
#      Restart   (dentro do macOS) -> systemctl reboot   (a sério)
#    (decidido assim de propósito: um Restart também reinicia o Arch
#    por baixo, para o caso de o próprio Arch estar com problemas.)
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
    echo "Nenhuma VM encontrada — a abrir o assistente de primeira execução."
    if ! "$KIOSK_DIR/macos-source-wizard.sh" "$VM_DISK" "$OVMF_VARS"; then
        echo "O assistente falhou ou foi cancelado. A tentar de novo em 10s (Alt+F2/tty2 pra saíres se precisares)."
        sleep 10
        exec "$0"
    fi
fi

RETRIES=0
while true; do
    rm -f "$QMP_SOCK"

    # TODO(verificar): a flag exata de vídeo acelerado do Reims-vGPU
    # (device/driver expostos pelo build do qemus/qemu-macos) precisa
    # de ser confirmada no README desse projeto antes do primeiro teste
    # a sério — o `-display sdl,gl=on` abaixo é o mínimo pra teres ecrã,
    # mas a aceleração real do Reims pode exigir um dispositivo de vídeo
    # próprio na linha de comando. Ver docs/CHECKLIST.md.
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
            echo "macOS pediu Shut Down — a desligar a máquina física."
            sudo systemctl poweroff
            exit 0
            ;;
        host-reboot)
            echo "macOS pediu Restart — a reiniciar a máquina física."
            sudo systemctl reboot
            exit 0
            ;;
        vm-only|*)
            echo "QEMU saiu sem pedido claro do guest (ação: ${ACTION}) — a relançar só a VM."
            RETRIES=$((RETRIES + 1))
            if [ "$RETRIES" -ge 5 ]; then
                echo "Demasiadas falhas seguidas — a reiniciar a máquina física como último recurso."
                sudo systemctl reboot
                exit 1
            fi
            sleep 3
            ;;
    esac
done
