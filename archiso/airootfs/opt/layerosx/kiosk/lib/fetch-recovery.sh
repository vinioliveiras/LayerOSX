#!/usr/bin/env bash
# Descarrega a imagem de recuperação diretamente dos servidores da
# Apple (fetch-macOS.py, do projeto OSX-KVM) para o disco $1. Isto
# nunca redistribui nada da Apple — só automatiza o mesmo pedido que um
# Mac real faz ao arrancar em modo de recuperação pela rede, desta vez
# para o teu próprio disco.
set -euo pipefail
VM_DISK="$1"
WORK="/var/lib/layerosx/fetch-work"
mkdir -p "$WORK"
cd "$WORK"

if [ ! -f fetch-macOS.py ]; then
    curl -fsSLo fetch-macOS.py \
        https://raw.githubusercontent.com/kholia/OSX-KVM/master/fetch-macOS.py
fi
python3 fetch-macOS.py

if [ -f BaseSystem.dmg ] && command -v dmg2img >/dev/null 2>&1; then
    dmg2img BaseSystem.dmg BaseSystem.img
    qemu-img convert -O qcow2 BaseSystem.img "${VM_DISK%.qcow2}-recovery.qcow2"
    echo "Recuperação pronta em ${VM_DISK%.qcow2}-recovery.qcow2 — o mac-vm-launch.sh precisa de a ligar como segundo disco no primeiro arranque para instalares o macOS a sério."
else
    echo "AVISO: não encontrei BaseSystem.dmg ou dmg2img — a descarga pode ter falhado." >&2
    exit 1
fi
