#!/usr/bin/env bash
# Keep Linux's own work off the Mac's dedicated cores (root; lib/cpu-pin.py
# runs it through sudo once it has pinned the vCPUs).
#
#   host-cpus.sh apply <cpu-list>   e.g. 8-15 or 0,5-7,8,13-15
#   host-cpus.sh reset              everything back on every CPU
#
# Moves: hardware interrupts (/proc/irq/*/smp_affinity_list -- the ones the
# kernel won't let move, e.g. per-CPU or managed NVMe queues, are skipped),
# unbound kernel workqueues, and the system services (system.slice,
# init.scope; runtime only, gone at reboot). The kiosk session's own
# processes are moved by cpu-pin.py itself (same user, no root needed).
set -uo pipefail
PROC="${LAYEROSX_PROC:-/proc}"
WQ="${LAYEROSX_WQ_CPUMASK:-/sys/devices/virtual/workqueue/cpumask}"
SYSTEMCTL="${LAYEROSX_SYSTEMCTL:-systemctl}"

list="${2:-}"
case "${1:-}" in
    apply) case "$list" in ''|*[!0-9,-]*) echo "bad cpu list: $list" >&2; exit 2 ;; esac ;;
    reset) list="0-$(( $(nproc --all) - 1 ))" ;;
    *) echo "usage: host-cpus.sh apply <cpu-list>|reset" >&2; exit 2 ;;
esac

# cpu list -> hex mask (workqueue wants a mask)
mask="$(python3 - "$list" <<'PY'
import sys
m = 0
for part in sys.argv[1].split(","):
    a, _, b = part.partition("-")
    for c in range(int(a), int(b or a) + 1):
        m |= 1 << c
print(format(m, "x"))
PY
)"

moved=0
for f in "$PROC"/irq/*/smp_affinity_list; do
    [ -e "$f" ] || continue
    echo "$list" > "$f" 2>/dev/null && moved=$((moved + 1))
done
[ -w "$WQ" ] && echo "$mask" > "$WQ" 2>/dev/null
if command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    "$SYSTEMCTL" set-property --runtime system.slice AllowedCPUs="$list" 2>/dev/null
    "$SYSTEMCTL" set-property --runtime init.scope AllowedCPUs="$list" 2>/dev/null
fi
echo "host work on cpus $list ($moved IRQs moved)"
