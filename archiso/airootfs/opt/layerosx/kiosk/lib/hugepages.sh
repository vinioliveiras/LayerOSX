#!/usr/bin/env bash
# Reserve 2 MB huge pages for the Mac's RAM (root; mac-vm-launch.sh runs it
# through sudo before each start).
#
#   hugepages.sh reserve <MB>   make the pool hold <MB> of 2 MB pages; exit 0 only
#                               when all of it could be had (else the pool is
#                               left as it was and it exits 1 -- the Mac then
#                               starts on normal pages)
#   hugepages.sh release        give the pool back to Linux
#   hugepages.sh status         "<total pages> <free pages>"
#
# Why: the guest RAM is a shared memfd (Reims needs it). Linux backs that
# with 4 KB pages and shmem THP didn't take in practice (ShmemHugePages stayed
# 0), so a 40 GB Mac is ~10 million page-table entries: TLB misses on every
# big guest access and page faults the first time each page is touched --
# the "engasgos". A hugetlb memfd (-object memory-backend-memfd,hugetlb=on)
# gets 2 MB pages that are reserved up front and never swapped or split.
# Adapts to the machine: the pool is sized from the Mac's RAM, and only taken
# when MemAvailable leaves Linux at least 2 GB afterwards.
set -uo pipefail
HP="${LAYEROSX_HUGEPAGES_SYSFS:-/sys/kernel/mm/hugepages/hugepages-2048kB}"
VM="${LAYEROSX_PROC_VM:-/proc/sys/vm}"
MEMINFO="${LAYEROSX_MEMINFO:-/proc/meminfo}"
KEEP_MB=2048

[ -d "$HP" ] || { echo "no 2 MB huge page support"; exit 2; }
nr() { cat "$HP/nr_hugepages"; }
free_pages() { cat "$HP/free_hugepages"; }
set_nr() { echo "$1" > "$HP/nr_hugepages" 2>/dev/null; }

case "${1:-}" in
    reserve)
        mb="${2:-}"
        case "$mb" in ''|*[!0-9]*) echo "usage: hugepages.sh reserve <MB>"; exit 2 ;; esac
        want=$(( (mb + 1) / 2 ))
        have="$(nr)"; used=$(( have - $(free_pages) ))
        # Already enough free pages in the pool (a Mac restart): nothing to do.
        if [ "$(free_pages)" -ge "$want" ]; then
            [ "$have" -gt $(( want + used )) ] && set_nr $(( want + used ))
            echo "$want"; exit 0
        fi
        avail_mb=$(( $(awk '/^MemAvailable:/{print $2}' "$MEMINFO") / 1024 + (have - used) * 2 ))
        if [ $(( avail_mb - mb )) -lt "$KEEP_MB" ]; then
            echo "only ${avail_mb} MB available"; exit 1
        fi
        sync
        echo 3 > "$VM/drop_caches" 2>/dev/null
        echo 1 > "$VM/compact_memory" 2>/dev/null
        set_nr $(( want + used ))
        got="$(free_pages)"
        if [ "$got" -lt "$want" ]; then
            set_nr "$have"
            echo "got $got of $want pages (memory too fragmented)"; exit 1
        fi
        echo "$want"; exit 0 ;;
    release)
        set_nr 0; echo "$(nr)" ;;
    status)
        echo "$(nr) $(free_pages)" ;;
    *) echo "usage: hugepages.sh reserve <MB>|release|status"; exit 2 ;;
esac
