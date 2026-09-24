#!/usr/bin/env bash
# One-shot LayerOSX diagnostics collector. Writes a single human-readable
# diag.txt (host + guest + config, everything we've ever wanted mid-postmortem)
# into $1, plus copies of the raw logs, so one artifact carries the full
# picture. Best-effort: every probe is guarded; a missing tool/file just prints
# "(n/a)". Shared by `macdiag` (on demand) and save-logs-to-usb.sh (which runs
# automatically on every VM exit), so the same bundle lands on the USB after a
# black-screen/crash with no command typed.
set -uo pipefail
OUT="${1:-.}"
mkdir -p "$OUT" 2>/dev/null || true

HOMEDIR="${HOME:-/home/mac}"
STATE_DIR="/var/lib/layerosx"
# Resolve each log against the invoker's HOME first, then the kiosk user's home
# (this runs as root from save-logs-to-usb.sh, and as `mac` from macdiag).
_resolve() { local c; for c in "$HOMEDIR/$1" "/home/mac/$1" "/root/$1"; do [ -r "$c" ] && { printf '%s\n' "$c"; return; }; done; printf '%s\n' "$HOMEDIR/$1"; }
SERIAL_LOG="$(_resolve mac-vm-serial.log)"
LAUNCHLOG="$(_resolve mac-vm.log)"
QEMU_D_LOG="$(_resolve mac-vm-qemu.log)"
QEMU_BIN="/opt/layerosx/bin/qemu-system-x86_64"
OCDIR="/opt/layerosx/opencore"
DIAG="$OUT/diag.txt"

_sec() { printf '\n===== %s =====\n' "$1"; }

{
    printf 'LayerOSX diagnostics — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'build mode: %s\n' "$(cat /etc/layerosx/mode 2>/dev/null || echo '(unknown)')"
    printf 'host: %s\n' "$(uname -srm 2>/dev/null)"

    _sec "HOST CPU"
    grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //' || echo '(n/a)'
    printf 'vendor=%s  cores(nproc)=%s\n' \
        "$(grep -m1 '^vendor_id' /proc/cpuinfo 2>/dev/null | awk '{print $3}')" "$(nproc 2>/dev/null)"
    printf 'virt: '; grep -m1 -oE '\b(svm|vmx)\b' /proc/cpuinfo 2>/dev/null | head -1 || echo '(none)'
    printf 'flags of interest: '
    grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | grep -oE '\b(svm|vmx|nx|lm|sse4_1|sse4_2|avx|avx2|rdtscp|hypervisor)\b' | tr '\n' ' '
    echo

    _sec "KVM"
    [ -e /dev/kvm ] && echo '/dev/kvm: present' || echo '/dev/kvm: MISSING (no hardware virt!)'
    lsmod 2>/dev/null | grep -E '^(kvm|kvm_amd|kvm_intel)' || echo '(no kvm modules listed)'
    dmesg 2>/dev/null | grep -iE 'kvm|svm' | tail -8 || echo '(no dmesg access)'

    _sec "MEMORY"
    free -h 2>/dev/null || echo '(n/a)'
    echo "-- huge pages for the Mac's RAM (shmem THP; want [advise] and ShmemHugePages > 0 while the Mac runs) --"
    grep -H . /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/shmem_enabled \
        /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/shmem_enabled 2>/dev/null
    grep -E '^(AnonHugePages|ShmemHugePages|ShmemPmdMapped|Shmem):' /proc/meminfo 2>/dev/null

    _sec "QEMU"
    LD_LIBRARY_PATH="/opt/layerosx/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$QEMU_BIN" --version 2>/dev/null | head -2 || echo '(qemu not runnable here)'
    echo '-- last launch profile --'; grep -a 'Launch profile:' "$LAUNCHLOG" 2>/dev/null | tail -1 || echo '(none)'
    echo '-- OpenCore image chosen --'; grep -a 'OpenCore image:' "$LAUNCHLOG" 2>/dev/null | tail -1 || echo '(none)'
    echo '-- exact QEMU cmdline --'; grep -a 'QEMU cmdline:' "$LAUNCHLOG" 2>/dev/null | tail -1 || echo '(none — pre-argv-dump build?)'

    _sec "OPENCORE IMAGES (installed)"
    ls -la "$OCDIR"/*.qcow2 2>/dev/null || echo '(none found)'

    _sec "MACOS VERSION"
    printf 'selected shortname: %s\n' "$(cat "$STATE_DIR/macos-version" 2>/dev/null || echo '(none)')"
    printf 'downloaded version: %s\n' "$(cat "$STATE_DIR/downloaded-version" 2>/dev/null || echo '(none)')"

    _sec "TOGGLES (state files; empty = per-mode default)"
    for t in gfx verbose audio; do
        printf '%s=%s  ' "$t" "$(cat "$STATE_DIR/$t" 2>/dev/null || echo default)"
    done; echo

    _sec "SOUND"
    cat /proc/asound/cards 2>/dev/null || echo "(no /proc/asound/cards)"
    aplay -l 2>&1 | head -20
    echo "-- output the Mac uses (Settings > Sound > Output) --"
    python3 /opt/layerosx/panel/layerosx_backend.py audio-device 2>&1 || echo "(none)"
    grep -E '^[0-9:]+ Audio:|audio|ALSA|alsa' "$HOME/mac-vm.log" 2>/dev/null | tail -8
    _sec "USB (automatic: $(cat "$STATE_DIR/usb-auto" 2>/dev/null || echo on))"
    python3 /opt/layerosx/panel/layerosx_backend.py usb 2>&1 | head -60
    echo "-- kept on Linux --"; cat "$STATE_DIR/usb-keep-on-linux" 2>/dev/null || echo "(none)"
    tail -10 "$HOME/usb-auto.log" 2>/dev/null

    _sec "SERIAL LOG — last 40 lines (where it stopped)"
    [ -r "$SERIAL_LOG" ] && tail -40 "$SERIAL_LOG" || echo '(no serial log yet)'

    _sec "SERIAL LOG — errors / panics / 'no linesize'"
    if [ -r "$SERIAL_LOG" ]; then
        grep -inE 'halting|panic|fatal|no linesize|Unable|not a valid|Err\(0x[^E]' "$SERIAL_LOG" \
            | grep -viE 'wake-failure|root_hash|\.development' | tail -30 || echo '(none)'
    else echo '(no serial log yet)'; fi

    _sec "SERIAL LOG — OCAK kernel-patch results"
    [ -r "$SERIAL_LOG" ] && { grep -a 'OCAK' "$SERIAL_LOG" | tail -40 || echo '(none)'; } \
        || echo '(none — needs debug OpenCore / a debug build with verbose on)'

    _sec "POWER MODE (host CPU clock policy)"
    /opt/layerosx/kiosk/lib/power-mode.sh status 2>&1
    grep -H . /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null

    _sec "FRAME RATE (Reims window, last 10 s) + window effects"
    python3 /opt/layerosx/panel/layerosx_backend.py fps 2>&1
    echo "window effects (picom): $(cat "$STATE_DIR/compositor" 2>/dev/null || echo on), running: $(pgrep -x picom >/dev/null && echo yes || echo no)"
    xrandr --current 2>/dev/null | grep -E '\*' | head -4

    _sec "REIMS — /tmp/reims-vgpu-fail.log (always-on failure log): translation refusals"
    if [ -r /tmp/reims-vgpu-fail.log ]; then
        grep -aE 'refused_by=|_translate |cannot_run|device_lost|engine present' /tmp/reims-vgpu-fail.log \
            | cut -c1-300 | head -20 || echo '(no refusals)'
    else
        echo '(no Reims failure log -- Reims not used this boot)'
    fi

    _sec "QEMU -d guest_errors/unimp (debug builds)"
    [ -r "$QEMU_D_LOG" ] && tail -40 "$QEMU_D_LOG" || echo '(none — release build, or no guest errors)'
} > "$DIAG" 2>&1

# Raw logs alongside the summary, so nothing is lost to truncation.
for f in "$SERIAL_LOG" "$LAUNCHLOG" "$QEMU_D_LOG" /tmp/reims-vgpu-fail.log; do
    [ -r "$f" ] && cp -f "$f" "$OUT/" 2>/dev/null || true
done

printf '%s\n' "$DIAG"
