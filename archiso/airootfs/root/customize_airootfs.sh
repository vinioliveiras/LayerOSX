#!/usr/bin/env bash
# Corre DENTRO do chroot do airootfs durante o `mkarchiso` (build-time,
# na tua máquina de build), NUNCA no hardware final. O mkarchiso apaga
# este ficheiro do ISO final sozinho, no fim do build.
#
# Compila aqui o que não existe em pacote oficial do Arch: o QEMU do
# projeto qemus/qemu-macos (já com o Reims-vGPU integrado) e o dmg2img
# (usado pelo wizard de "instalar a partir de um .dmg"). Assim o
# postinstall só copia binários já prontos, não precisa de rede nem de
# compilar nada na máquina final.
#
# ATENÇÃO — isto ainda não foi validado: os passos de build exatos do
# qemus/qemu-macos precisam de ser confirmados contra o README do
# projeto no momento em que fores gerar a ISO (a máquina de build tem
# rede; este script corre lá, não aqui). Ver docs/CHECKLIST.md.

set -uo pipefail
echo "==> customize_airootfs: a compilar qemus/qemu-macos e dmg2img"

BUILD_DIR="/tmp/build-layerosx"
mkdir -p "$BUILD_DIR"

# --- dmg2img (extração de instaladores .dmg) -------------------------------
if git clone --depth 1 https://github.com/Lekensteyn/dmg2img "$BUILD_DIR/dmg2img"; then
    make -C "$BUILD_DIR/dmg2img"
    install -Dm755 "$BUILD_DIR/dmg2img/dmg2img" /usr/local/bin/dmg2img
    [ -f "$BUILD_DIR/dmg2img/vfdecrypt" ] && install -Dm755 "$BUILD_DIR/dmg2img/vfdecrypt" /usr/local/bin/vfdecrypt
else
    echo "AVISO: falhei a clonar/compilar dmg2img — o caminho de instalação por .dmg não vai funcionar." >&2
fi

# --- qemus/qemu-macos (QEMU + Reims-vGPU) -----------------------------------
if git clone --depth 1 https://github.com/qemus/qemu-macos "$BUILD_DIR/qemu-macos"; then
    cd "$BUILD_DIR/qemu-macos"
    # TODO(verificar): confirma o comando de build exato no README do
    # projeto antes do build final — tenta os caminhos mais comuns, mas
    # sem garantia nenhuma de que batem certo com a versão atual do repo.
    if [ -f build.sh ]; then
        bash build.sh || echo "AVISO: build.sh do qemu-macos falhou — ver docs/CHECKLIST.md" >&2
    elif [ -f meson.build ]; then
        meson setup build --prefix=/usr/local && ninja -C build && ninja -C build install
    else
        echo "AVISO: não reconheci o método de build do qemu-macos (nem build.sh nem meson.build) — instala manualmente antes do build final." >&2
    fi
else
    echo "AVISO: falhei a clonar qemus/qemu-macos — sem isto não há aceleração nenhuma, a VM não vai funcionar como esperado." >&2
fi

rm -rf "$BUILD_DIR"
echo "==> customize_airootfs: concluído"
