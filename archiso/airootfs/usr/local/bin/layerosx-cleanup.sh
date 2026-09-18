#!/usr/bin/env bash
# Este Arch não tem "uso normal" (sem navegação, sem updates manuais,
# ninguém vai olhar pra ele) — por isso o lixo que normalmente se
# acumula com o tempo (cache de pacotes, journal, tmp, core dumps)
# é limpo sozinho, periodicamente (ver o .timer ao lado).
set -uo pipefail

echo "[cleanup] $(date -Is)"

# mantém só a versão mais recente de cada pacote em cache
command -v paccache >/dev/null 2>&1 && paccache -rk1 --noprogressbar

journalctl --vacuum-time=1week --vacuum-size=200M 2>/dev/null

find /tmp -mindepth 1 -mtime +2 -exec rm -rf {} + 2>/dev/null

rm -rf /var/cache/coredump/* 2>/dev/null

# só relata pacotes órfãos, não remove nada sozinho — evita apanhar
# dependências do qemu-macos compilado à mão que o pacman não conhece
orphans=$(pacman -Qtdq 2>/dev/null || true)
[ -n "$orphans" ] && echo "[cleanup] pacotes órfãos (não removidos automaticamente): $orphans"

echo "[cleanup] concluído"
