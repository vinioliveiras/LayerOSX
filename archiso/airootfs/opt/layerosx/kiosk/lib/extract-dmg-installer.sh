#!/usr/bin/env bash
# Melhor esforço: tenta extrair um instalador arrancável a partir de um
# .dmg (ou .app com um .dmg lá dentro) que já tens — por exemplo,
# descarregado pela App Store noutro Mac, o que te dá sempre a versão
# mais recente. É a parte mais experimental do projeto: as imagens de
# instalador reais da Apple costumam ser APFS, e o suporte a APFS em
# Linux ainda é limitado. Ver docs/CHECKLIST.md.
set -euo pipefail
SRC="$1"
VM_DISK="$2"

command -v dmg2img >/dev/null 2>&1 || { echo "dmg2img não encontrado" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'umount "$WORK/mnt" 2>/dev/null; rm -rf "$WORK"' EXIT

DMG="$SRC"
if [ -d "$SRC" ]; then
    DMG=$(find "$SRC" -iname '*.dmg' | head -n1)
    [ -n "$DMG" ] || { echo "não encontrei .dmg dentro de $SRC" >&2; exit 1; }
fi

dmg2img "$DMG" "$WORK/installer.img"

MNT="$WORK/mnt"
mkdir -p "$MNT"
if mount -o loop,ro "$WORK/installer.img" "$MNT" 2>/dev/null; then
    echo "montado com sucesso (HFS+)"
elif command -v apfs-fuse >/dev/null 2>&1 && apfs-fuse "$WORK/installer.img" "$MNT" 2>/dev/null; then
    echo "montado com sucesso (APFS via apfs-fuse)"
else
    echo "não consegui montar a imagem extraída (nem HFS+ nem APFS) — este caminho precisa de mais trabalho, ver docs/CHECKLIST.md." >&2
    exit 1
fi

qemu-img convert -O qcow2 "$WORK/installer.img" "${VM_DISK%.qcow2}-installer.qcow2"
echo "Instalador pronto em ${VM_DISK%.qcow2}-installer.qcow2 — liga-o como segundo disco no primeiro arranque."
