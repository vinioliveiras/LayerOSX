#!/usr/bin/env bash
# Gera a ISO final. Precisa de correr numa máquina Linux Arch-based
# (CachyOS serve) com o pacote `archiso` instalado — não corre dentro
# desta sandbox, é para correres na tua própria máquina.
set -euo pipefail
cd "$(dirname "$0")"
WORKDIR="${1:-./work}"
OUTDIR="${2:-./out}"

command -v mkarchiso >/dev/null 2>&1 || {
    echo "mkarchiso não encontrado — instala o pacote 'archiso' primeiro (sudo pacman -S archiso)." >&2
    exit 1
}

sudo mkarchiso -v -w "$WORKDIR" -o "$OUTDIR" .
echo "ISO pronta em $OUTDIR/ — arrasta para a pen com o Ventoy."
