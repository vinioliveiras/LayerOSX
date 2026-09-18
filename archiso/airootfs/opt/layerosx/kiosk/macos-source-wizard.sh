#!/usr/bin/env bash
# Assistente de primeira execução: corre uma única vez, antes de
# existir qualquer VM. Pergunta de onde vem o macOS e prepara $1
# (disco da VM) + $2 (NVRAM/OVMF_VARS) para o mac-vm-launch.sh arrancar.
set -uo pipefail

VM_DISK="$1"
OVMF_VARS="$2"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
VM_SIZE_GB="${MAC_VM_SIZE_GB:-128}"

CHOICE=$(zenity --list --radiolist --width=560 --height=280 \
    --title="LayerOSX — primeira execução" \
    --text="De onde vem o macOS? (isto só é perguntado uma vez)" \
    --column="" --column="Opção" \
    TRUE  "Descarregar a imagem de recuperação diretamente da Apple (recomendado)" \
    FALSE "Já tenho uma VM/disco de macOS (.qcow2 / .img) — escolher no disco" \
    FALSE "Já tenho um instalador .dmg (App Store / outro Mac) — escolher no disco")

[ -n "$CHOICE" ] || exit 1

case "$CHOICE" in
    *recomendado*)
        qemu-img create -f qcow2 "$VM_DISK" "${VM_SIZE_GB}G"
        cp /usr/share/edk2-ovmf/x64/OVMF_VARS.fd "$OVMF_VARS"
        bash "$LIB_DIR/fetch-recovery.sh" "$VM_DISK"
        ;;
    *"Já tenho uma VM"*)
        SRC=$(zenity --file-selection --title="Escolhe o disco da VM" \
            --file-filter="Discos de VM | *.qcow2 *.img *.raw")
        [ -n "$SRC" ] || exit 1
        cp "$SRC" "$VM_DISK"
        cp /usr/share/edk2-ovmf/x64/OVMF_VARS.fd "$OVMF_VARS"
        ;;
    *".dmg"*)
        SRC=$(zenity --file-selection --title="Escolhe o instalador .dmg" \
            --file-filter="Instaladores macOS | *.dmg *.app")
        [ -n "$SRC" ] || exit 1
        qemu-img create -f qcow2 "$VM_DISK" "${VM_SIZE_GB}G"
        cp /usr/share/edk2-ovmf/x64/OVMF_VARS.fd "$OVMF_VARS"
        if ! bash "$LIB_DIR/extract-dmg-installer.sh" "$SRC" "$VM_DISK"; then
            zenity --error --text="Não consegui preparar o instalador a partir deste .dmg (é a parte mais experimental do projeto — ver docs/CHECKLIST.md). Tenta a opção de descarregar direto da Apple."
            exit 1
        fi
        ;;
    *)
        exit 1
        ;;
esac
