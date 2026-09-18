#!/usr/bin/env bash
# This Arch install has no "normal usage" (no browsing, no manual
# updates, nobody's going to be looking at it) — so the junk that
# normally builds up over time (package cache, journal, tmp, core
# dumps) is cleaned up on its own, periodically (see the .timer next
# to this).
set -uo pipefail

echo "[cleanup] $(date -Is)"

# keep only the most recent version of each package in cache
command -v paccache >/dev/null 2>&1 && paccache -rk1 --noprogressbar

journalctl --vacuum-time=1week --vacuum-size=200M 2>/dev/null

find /tmp -mindepth 1 -mtime +2 -exec rm -rf {} + 2>/dev/null

rm -rf /var/cache/coredump/* 2>/dev/null

# only reports orphan packages, doesn't remove anything on its own —
# avoids catching dependencies of the hand-built qemu-macos that
# pacman doesn't know about
orphans=$(pacman -Qtdq 2>/dev/null || true)
[ -n "$orphans" ] && echo "[cleanup] orphan packages (not removed automatically): $orphans"

echo "[cleanup] done"
