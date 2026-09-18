#!/usr/bin/env bash
# Corre DENTRO do chroot do sistema já copiado pelo unpackfs (via
# shellprocess do Calamares). Um log único, falha de um script não trava
# os outros — melhor teres um sistema quase-todo pronto do que nenhum.
set -uo pipefail
LOG=/var/log/layerosx-postinstall.log
exec > >(tee -a "$LOG") 2>&1

echo "===== LayerOSX postinstall: $(date -Is) ====="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for step in "$SCRIPT_DIR"/[0-9][0-9]-*.sh; do
    echo "--- a correr: $step ---"
    if ! bash "$step"; then
        echo "!!! $step falhou (ver acima) — a continuar na mesma para não travar a instalação por completo."
    fi
done

echo "===== postinstall concluído: $(date -Is) ====="
echo "Log completo em /var/log/layerosx-postinstall.log"
